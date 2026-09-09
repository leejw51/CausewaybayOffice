//! VT100/xterm emulation via the `vt100` crate and snapshotting into the
//! `CboCell` grid consumed by the Lua renderer. Kitty graphics sequences are
//! split out of the stream and kept in `graphics::Graphics`.

use crate::graphics::{CboImageInfo, CboPlacement, Cursor, Graphics, Seg};

pub const ATTR_BOLD: u8 = 1;
pub const ATTR_ITALIC: u8 = 2;
pub const ATTR_UNDERLINE: u8 = 4;
pub const ATTR_INVERSE: u8 = 8;
pub const ATTR_BLINK: u8 = 16;
pub const ATTR_DIM: u8 = 32;

/// Default scrollback depth kept per session.
pub const SCROLLBACK_LINES: usize = 5000;

/// Mirror of `CboCell` in cbo.h. Layout is frozen: 16 bytes, 4-byte aligned.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct CboCell {
    pub cp: u32,
    pub fg: u32,
    pub bg: u32,
    pub attr: u8,
    pub width: u8,
    pub _pad: [u8; 2],
}

/// Default foreground: warm phosphor white.
pub const DEFAULT_FG: u32 = 0xE8E8D0;
/// Default background: deep Causeway Bay night blue.
pub const DEFAULT_BG: u32 = 0x0A0A1E;

/// Retro 16-colour ANSI palette (0-7 normal, 8-15 bright).
pub const PALETTE16: [u32; 16] = [
    0x1A1A2E, // 0 black
    0xE0433E, // 1 red
    0x4FC26B, // 2 green
    0xE8C547, // 3 yellow
    0x4C8BE0, // 4 blue
    0xC76BC7, // 5 magenta
    0x3FC1C9, // 6 cyan
    0xC8C8B4, // 7 white
    0x606078, // 8 bright black
    0xFF6E5E, // 9 bright red
    0x7CF29A, // 10 bright green
    0xFFE873, // 11 bright yellow
    0x74AFFF, // 12 bright blue
    0xF39CF3, // 13 bright magenta
    0x7BEFF5, // 14 bright cyan
    0xFFFFF0, // 15 bright white
];

/// Resolve an xterm 256-colour index to 0xRRGGBB.
pub fn resolve_index(idx: u8) -> u32 {
    match idx {
        0..=15 => PALETTE16[idx as usize],
        16..=231 => {
            let i = idx as u32 - 16;
            let (r, g, b) = (i / 36, (i / 6) % 6, i % 6);
            let step = |v: u32| if v == 0 { 0 } else { 55 + v * 40 };
            (step(r) << 16) | (step(g) << 8) | step(b)
        }
        232..=255 => {
            let v = 8 + (idx as u32 - 232) * 10;
            (v << 16) | (v << 8) | v
        }
    }
}

fn resolve_color(c: vt100::Color, default: u32, bold: bool) -> u32 {
    match c {
        vt100::Color::Default => default,
        // Classic terminals render bold + basic colour as the bright variant.
        vt100::Color::Idx(i) if bold && i < 8 => PALETTE16[i as usize + 8],
        vt100::Color::Idx(i) => resolve_index(i),
        vt100::Color::Rgb(r, g, b) => ((r as u32) << 16) | ((g as u32) << 8) | b as u32,
    }
}

pub struct Term {
    parser: vt100::Parser,
    generation: u64,
    bells: u32,
    gfx: Graphics,
    /// Lines that scrolled off the top of scrollback (vt100 caps it), so
    /// `abs_top()` keeps growing and image anchors stay put.
    scroll_base: i64,
    /// Set when the client asked for window/cell pixel sizes (CSI 14/16 t)
    /// or the cell size changed; the SSH worker re-sends the pty size.
    pixel_size_changed: bool,
    /// Remote working directory reported by OSC 7 (`file://host/path`);
    /// empty until the shell reports one.
    osc7_cwd: String,
    /// OSC 7 scanner state, so a report may straddle reads.
    osc7: Osc7,
}

#[derive(Default)]
enum Osc7 {
    #[default]
    Ground,
    Esc,
    Bracket,
    Seven,
    Body(Vec<u8>),
    BodyEsc(Vec<u8>),
}

const MAX_OSC7: usize = 4096;

/// Decode `%XX` escapes; a malformed escape is kept as typed.
fn percent_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            let hex = std::str::from_utf8(&b[i + 1..i + 3]).ok();
            if let Some(v) = hex.and_then(|h| u8::from_str_radix(h, 16).ok()) {
                out.push(v);
                i += 3;
                continue;
            }
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// The path in an OSC 7 body: `file://host/path`, `kitty-shell-cwd://host/path`
/// or a bare absolute path. None when there is no usable path.
fn osc7_path(body: &[u8]) -> Option<String> {
    let body = std::str::from_utf8(body).ok()?;
    let path = match body.find("://") {
        Some(i) => {
            let rest = &body[i + 3..];
            let slash = rest.find('/')?;
            &rest[slash..]
        }
        None => body,
    };
    if !path.starts_with('/') {
        return None;
    }
    Some(percent_decode(path))
}

/// A directory shown in a window title, the `user@host: ~/dir` form that
/// Debian and Ubuntu bash use by default. None when the title has no path.
fn title_path(title: &str) -> Option<String> {
    let t = title.trim();
    let tail = match t.find(": ") {
        Some(i) if t[..i].contains('@') => t[i + 2..].trim(),
        _ => t,
    };
    if tail.is_empty() || tail.contains(' ') && !tail.starts_with('/') && !tail.starts_with('~') {
        return None;
    }
    (tail.starts_with('/') || tail == "~" || tail.starts_with("~/")).then(|| tail.to_string())
}

impl Term {
    pub fn new(cols: u16, rows: u16) -> Self {
        Term {
            parser: vt100::Parser::new(rows.max(1), cols.max(1), SCROLLBACK_LINES),
            generation: 0,
            bells: 0,
            gfx: Graphics::default(),
            scroll_base: 0,
            pixel_size_changed: false,
            osc7_cwd: String::new(),
            osc7: Osc7::Ground,
        }
    }

    /// Feed raw bytes from the remote side. Kitty graphics sequences are
    /// split out and handled here; the rest goes to the VT parser in order.
    /// Bumps the generation counter and counts BEL bytes.
    pub fn process(&mut self, bytes: &[u8]) {
        if bytes.is_empty() {
            return;
        }
        for seg in self.gfx.split(bytes) {
            match seg {
                Seg::Text(t) => self.feed_text(&t),
                Seg::Apc(body) => self.apc(&body),
            }
        }
        let top = self.abs_top();
        self.gfx.prune(top);
        self.gfx.changed = false;
        self.generation += 1;
    }

    fn feed_text(&mut self, t: &[u8]) {
        self.bells += t.iter().filter(|&&b| b == 0x07).count() as u32;
        let before_len = self.scrollback_len() as i64;
        let (rows, _) = self.parser.screen().size();
        let (row_before, _) = self.parser.screen().cursor_position();
        let alt_before = self.parser.screen().alternate_screen();
        self.parser.process(t);
        let after_len = self.scrollback_len() as i64;
        if after_len < before_len {
            // scrollback was cleared: keep absolute lines monotonic
            self.scroll_base += before_len - after_len;
        } else if before_len >= SCROLLBACK_LINES as i64 && !alt_before {
            // Scrollback is full, so its length no longer measures scrolling;
            // estimate from line feeds past the bottom row.
            let lf = t.iter().filter(|&&b| b == b'\n').count() as i64;
            let over = row_before as i64 + lf - (rows as i64 - 1);
            if over > 0 {
                self.scroll_base += over;
            }
        }
        if alt_before && !self.parser.screen().alternate_screen() {
            self.gfx.clear_alt();
        }
        self.scan_csi(t);
        self.scan_osc7(t);
    }

    /// Track `ESC ] 7 ; file://host/path (BEL | ESC \)`, the shell's report of
    /// its working directory. vt100 ignores OSC 7, so it is picked up here.
    fn scan_osc7(&mut self, t: &[u8]) {
        for &b in t {
            self.osc7 = match std::mem::take(&mut self.osc7) {
                Osc7::Ground => {
                    if b == 0x1b {
                        Osc7::Esc
                    } else {
                        Osc7::Ground
                    }
                }
                Osc7::Esc => match b {
                    b']' => Osc7::Bracket,
                    0x1b => Osc7::Esc,
                    _ => Osc7::Ground,
                },
                Osc7::Bracket => match b {
                    b'7' => Osc7::Seven,
                    0x1b => Osc7::Esc,
                    _ => Osc7::Ground,
                },
                Osc7::Seven => match b {
                    b';' => Osc7::Body(Vec::new()),
                    0x1b => Osc7::Esc,
                    _ => Osc7::Ground,
                },
                Osc7::Body(mut body) => match b {
                    0x07 => {
                        self.set_osc7(&body);
                        Osc7::Ground
                    }
                    0x1b => Osc7::BodyEsc(body),
                    _ => {
                        if body.len() < MAX_OSC7 {
                            body.push(b);
                        }
                        Osc7::Body(body)
                    }
                },
                Osc7::BodyEsc(body) => {
                    if b == b'\\' {
                        self.set_osc7(&body);
                    }
                    Osc7::Ground
                }
            };
        }
    }

    fn set_osc7(&mut self, body: &[u8]) {
        if let Some(p) = osc7_path(body) {
            self.osc7_cwd = p;
        }
    }

    /// The remote working directory as far as the terminal can tell: the last
    /// OSC 7 report, else a path in the window title. "" when unknown.
    pub fn cwd(&self) -> String {
        if !self.osc7_cwd.is_empty() {
            return self.osc7_cwd.clone();
        }
        title_path(self.title()).unwrap_or_default()
    }

    /// The few CSI sequences the graphics layer cares about: screen erase
    /// (drops the images on it) and the pixel size reports clients use to
    /// size images.
    fn scan_csi(&mut self, t: &[u8]) {
        let mut i = 0;
        while i + 2 < t.len() {
            if t[i] == 0x1b && t[i + 1] == b'[' {
                let rest = &t[i + 2..];
                if rest.starts_with(b"2J") || rest.starts_with(b"3J") {
                    let cur = self.cursor_info();
                    self.gfx.clear_screen(cur);
                } else if rest.starts_with(b"14t") || rest.starts_with(b"16t") {
                    let (cols, rows) = self.size();
                    let (cw, ch) = (self.gfx.cell_w as u32, self.gfx.cell_h as u32);
                    let reply = if rest[1] == b'4' {
                        format!("\x1b[4;{};{}t", rows as u32 * ch, cols as u32 * cw)
                    } else {
                        format!("\x1b[6;{};{}t", ch, cw)
                    };
                    self.gfx.push_response(reply.as_bytes());
                }
            }
            i += 1;
        }
    }

    fn apc(&mut self, body: &[u8]) {
        let cur = self.cursor_info();
        if let Some(d) = self.gfx.command(body, cur) {
            if d.move_cursor {
                // Cursor goes to the cell after the image's bottom-right,
                // scrolling if the image runs past the bottom of the screen.
                let mut seq = "\n".repeat(d.rows.saturating_sub(1) as usize);
                let col = (cur.col as u32 + d.cols as u32).min(cur.screen_cols as u32 - 1);
                seq.push_str(&format!("\x1b[{}G", col + 1));
                self.feed_text(seq.as_bytes());
            }
        }
    }

    fn cursor_info(&mut self) -> Cursor {
        let abs_top = self.abs_top();
        let screen = self.parser.screen();
        let (rows, cols) = screen.size();
        let (row, col) = screen.cursor_position();
        Cursor {
            col,
            row,
            screen_cols: cols,
            screen_rows: rows,
            abs_top,
            alt: screen.alternate_screen(),
        }
    }

    /// Absolute line number of the top row of the live screen.
    fn abs_top(&mut self) -> i64 {
        self.scroll_base + self.scrollback_len() as i64
    }

    /// Cell size in pixels, as reported to the remote side (pty winsize and
    /// CSI 14/16 t) and used to size images without explicit c/r.
    pub fn set_cell_px(&mut self, w: u16, h: u16) {
        let (w, h) = (w.max(1), h.max(1));
        if (self.gfx.cell_w, self.gfx.cell_h) != (w, h) {
            self.gfx.cell_w = w;
            self.gfx.cell_h = h;
            self.pixel_size_changed = true;
        }
    }

    pub fn cell_px(&self) -> (u16, u16) {
        (self.gfx.cell_w, self.gfx.cell_h)
    }

    /// True once after the cell size changed (the pty size must be re-sent).
    pub fn take_pixel_size_changed(&mut self) -> bool {
        std::mem::take(&mut self.pixel_size_changed)
    }

    /// Protocol responses queued for the remote side, drained.
    pub fn take_responses(&mut self) -> Vec<u8> {
        self.gfx.take_responses()
    }

    /// Image placements intersecting the visible screen (scrollback aware),
    /// ordered by z.
    pub fn placements(&mut self) -> Vec<CboPlacement> {
        let scroll = self.scroll_offset();
        let cur = self.cursor_info();
        self.gfx.visible(cur, scroll)
    }

    pub fn image(&self, key: u64) -> Option<&crate::graphics::Image> {
        self.gfx.image(key)
    }

    pub fn image_info(&self, key: u64) -> Option<CboImageInfo> {
        self.gfx.image(key).map(|im| CboImageInfo {
            key: im.key,
            width: im.width,
            height: im.height,
            bytes: im.data.len() as u32,
            format: im.format,
            compressed: im.compressed as u32,
            _pad: 0,
        })
    }

    pub fn prompt_line(&self) -> Option<String> {
        let screen = self.parser.screen();
        if screen.alternate_screen() || screen.scrollback() != 0 {
            return None;
        }
        let (row, col) = screen.cursor_position();
        let mut text = String::new();
        for x in 0..col {
            if let Some(cell) = screen.cell(row, x) {
                if !cell.is_wide_continuation() {
                    let content = cell.contents();
                    if content.is_empty() {
                        text.push(' ');
                    } else {
                        text.push_str(&content);
                    }
                }
            }
        }
        Some(text)
    }

    pub fn bracketed_paste(&self) -> bool {
        self.parser.screen().bracketed_paste()
    }

    pub fn generation(&self) -> u64 {
        self.generation
    }

    /// (cols, rows)
    pub fn size(&self) -> (u16, u16) {
        let (rows, cols) = self.parser.screen().size();
        (cols, rows)
    }

    pub fn resize(&mut self, cols: u16, rows: u16) {
        self.parser.set_size(rows.max(1), cols.max(1));
        self.generation += 1;
    }

    pub fn take_bell(&mut self) -> u32 {
        std::mem::take(&mut self.bells)
    }

    pub fn title(&self) -> &str {
        self.parser.screen().title()
    }

    /// (x, y, visible)
    pub fn cursor(&self) -> (u16, u16, bool) {
        let screen = self.parser.screen();
        let (row, col) = screen.cursor_position();
        (col, row, !screen.hide_cursor())
    }

    pub fn scroll_offset(&self) -> i32 {
        self.parser.screen().scrollback() as i32
    }

    /// Total number of lines available in scrollback. vt100 does not expose
    /// this directly, so probe it by clamping and restoring the offset.
    pub fn scrollback_len(&mut self) -> i32 {
        let cur = self.parser.screen().scrollback();
        self.parser.set_scrollback(usize::MAX);
        let len = self.parser.screen().scrollback();
        self.parser.set_scrollback(cur);
        len as i32
    }

    pub fn set_scroll(&mut self, offset: i32) {
        let before = self.parser.screen().scrollback();
        self.parser.set_scrollback(offset.max(0) as usize);
        if self.parser.screen().scrollback() != before {
            self.generation += 1;
        }
    }

    /// Write up to `out.len()` cells (row-major) and return the count written.
    pub fn snapshot(&self, out: &mut [CboCell]) -> usize {
        let screen = self.parser.screen();
        let (rows, cols) = screen.size();
        let mut n = 0usize;
        'outer: for r in 0..rows {
            for c in 0..cols {
                if n >= out.len() {
                    break 'outer;
                }
                out[n] = match screen.cell(r, c) {
                    Some(cell) => convert_cell(cell),
                    None => blank_cell(),
                };
                n += 1;
            }
        }
        n
    }

    /// Plain-text contents of the visible screen (rows joined by '\n').
    pub fn contents(&self) -> String {
        self.parser.screen().contents()
    }
}

fn blank_cell() -> CboCell {
    CboCell {
        cp: 0,
        fg: DEFAULT_FG,
        bg: DEFAULT_BG,
        attr: 0,
        width: 1,
        _pad: [0; 2],
    }
}

fn convert_cell(cell: &vt100::Cell) -> CboCell {
    let bold = cell.bold();
    let mut attr = 0u8;
    if bold {
        attr |= ATTR_BOLD;
    }
    if cell.italic() {
        attr |= ATTR_ITALIC;
    }
    if cell.underline() {
        attr |= ATTR_UNDERLINE;
    }
    if cell.inverse() {
        attr |= ATTR_INVERSE;
    }

    let mut fg = resolve_color(cell.fgcolor(), DEFAULT_FG, bold);
    let mut bg = resolve_color(cell.bgcolor(), DEFAULT_BG, false);
    // Colours are delivered fully resolved: inverse is already applied here,
    // the attr bit is informational only.
    if cell.inverse() {
        std::mem::swap(&mut fg, &mut bg);
    }

    let width = if cell.is_wide_continuation() {
        0
    } else if cell.is_wide() {
        2
    } else {
        1
    };
    let cp = if width == 0 {
        0
    } else {
        // Combining marks are folded into the base character.
        cell.contents()
            .chars()
            .next()
            .map(|ch| ch as u32)
            .unwrap_or(0)
    };

    CboCell {
        cp,
        fg,
        bg,
        attr,
        width,
        _pad: [0; 2],
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cell_layout_is_16_bytes() {
        assert_eq!(std::mem::size_of::<CboCell>(), 16);
        assert_eq!(std::mem::align_of::<CboCell>(), 4);
    }

    #[test]
    fn snapshot_widths_and_colours() {
        let mut t = Term::new(20, 2);
        t.process("\x1b[31mhi\x1b[0m 你好".as_bytes());
        let mut cells = vec![CboCell::default(); 40];
        let n = t.snapshot(&mut cells);
        assert_eq!(n, 40);

        assert_eq!(cells[0].cp, 'h' as u32);
        assert_eq!(cells[0].fg, PALETTE16[1]);
        assert_eq!(cells[0].bg, DEFAULT_BG);
        assert_eq!(cells[0].width, 1);
        assert_eq!(cells[1].cp, 'i' as u32);
        assert_eq!(cells[1].fg, PALETTE16[1]);

        assert_eq!(cells[2].cp, ' ' as u32);
        assert_eq!(cells[2].fg, DEFAULT_FG);

        assert_eq!(cells[3].cp, '你' as u32);
        assert_eq!(cells[3].width, 2);
        assert_eq!(cells[4].cp, 0);
        assert_eq!(cells[4].width, 0);
        assert_eq!(cells[5].cp, '好' as u32);
        assert_eq!(cells[5].width, 2);
        assert_eq!(cells[6].width, 0);
        assert_eq!(cells[7].cp, 0);
        assert_eq!(cells[7].width, 1);
        assert_eq!(t.generation(), 1);
    }

    #[test]
    fn cwd_from_osc7_bel_st_and_split_reads() {
        let mut t = Term::new(40, 4);
        assert_eq!(t.cwd(), "");
        t.process(b"\x1b]7;file://box/home/alice\x07$ ");
        assert_eq!(t.cwd(), "/home/alice");
        t.process(b"\x1b]7;file://box/srv/my%20app\x1b\\");
        assert_eq!(t.cwd(), "/srv/my app");
        // split across three reads, kitty scheme, then a non-7 OSC keeps it
        t.process(b"\x1b]");
        t.process(b"7;kitty-shell-cwd://box/opt/");
        t.process(b"data\x07");
        assert_eq!(t.cwd(), "/opt/data");
        t.process(b"\x1b]0;some title\x07");
        assert_eq!(t.cwd(), "/opt/data");
        // a bare relative body is ignored
        t.process(b"\x1b]7;nothing\x07");
        assert_eq!(t.cwd(), "/opt/data");
    }

    #[test]
    fn cwd_falls_back_to_debian_style_title() {
        let mut t = Term::new(40, 4);
        t.process(b"\x1b]0;alice@box: ~/work/api\x07");
        assert_eq!(t.cwd(), "~/work/api");
        t.process(b"\x1b]0;alice@box: /var/log\x07");
        assert_eq!(t.cwd(), "/var/log");
        t.process(b"\x1b]0;vim README.md\x07");
        assert_eq!(t.cwd(), "");
        t.process(b"\x1b]0;~\x07");
        assert_eq!(t.cwd(), "~");
        // OSC 7 wins over the title once seen
        t.process(b"\x1b]7;file:///tmp\x07\x1b]0;alice@box: ~\x07");
        assert_eq!(t.cwd(), "/tmp");
    }

    #[test]
    fn bells_counted_and_drained() {
        let mut t = Term::new(10, 2);
        t.process(b"a\x07b\x07\x07");
        assert_eq!(t.take_bell(), 3);
        assert_eq!(t.take_bell(), 0);
    }

    #[test]
    fn bold_brightens_basic_colours_and_inverse_swaps() {
        let mut t = Term::new(10, 1);
        t.process(b"\x1b[1;32mX\x1b[0m\x1b[7mY\x1b[0m");
        let mut cells = vec![CboCell::default(); 10];
        t.snapshot(&mut cells);
        assert_eq!(cells[0].fg, PALETTE16[10]);
        assert!(cells[0].attr & ATTR_BOLD != 0);
        assert_eq!(cells[1].fg, DEFAULT_BG);
        assert_eq!(cells[1].bg, DEFAULT_FG);
        assert!(cells[1].attr & ATTR_INVERSE != 0);
    }

    #[test]
    fn colour_cube_and_grey_ramp() {
        assert_eq!(resolve_index(16), 0x000000);
        assert_eq!(resolve_index(231), 0xFFFFFF);
        assert_eq!(resolve_index(196), 0xFF0000);
        assert_eq!(resolve_index(232), 0x080808);
        assert_eq!(resolve_index(255), 0xEEEEEE);
    }

    #[test]
    fn scrollback_probe() {
        let mut t = Term::new(10, 2);
        for i in 0..10 {
            t.process(format!("line{}\r\n", i).as_bytes());
        }
        assert!(t.scrollback_len() >= 8);
        assert_eq!(t.scroll_offset(), 0);
        t.set_scroll(3);
        assert_eq!(t.scroll_offset(), 3);
        t.set_scroll(0);
        assert_eq!(t.scroll_offset(), 0);
    }

    /// One row of the unicode matrix: text, its total column width, and the
    /// expected (cp, width) cells (a combining mark folds into its base).
    struct Uni(&'static str, u16, &'static [(char, u8)]);

    const MATRIX: &[Uni] = &[
        Uni(
            "你好世界",
            8,
            &[
                ('你', 2),
                ('\0', 0),
                ('好', 2),
                ('\0', 0),
                ('世', 2),
                ('\0', 0),
                ('界', 2),
                ('\0', 0),
            ],
        ),
        Uni(
            "香港銅鑼灣",
            10,
            &[
                ('香', 2),
                ('\0', 0),
                ('港', 2),
                ('\0', 0),
                ('銅', 2),
                ('\0', 0),
                ('鑼', 2),
                ('\0', 0),
                ('灣', 2),
                ('\0', 0),
            ],
        ),
        Uni(
            "안녕하세요",
            10,
            &[
                ('안', 2),
                ('\0', 0),
                ('녕', 2),
                ('\0', 0),
                ('하', 2),
                ('\0', 0),
                ('세', 2),
                ('\0', 0),
                ('요', 2),
                ('\0', 0),
            ],
        ),
        Uni(
            "세션 이름",
            9,
            &[
                ('세', 2),
                ('\0', 0),
                ('션', 2),
                ('\0', 0),
                (' ', 1),
                ('이', 2),
                ('\0', 0),
                ('름', 2),
                ('\0', 0),
            ],
        ),
        Uni(
            "こんにちは",
            10,
            &[
                ('こ', 2),
                ('\0', 0),
                ('ん', 2),
                ('\0', 0),
                ('に', 2),
                ('\0', 0),
                ('ち', 2),
                ('\0', 0),
                ('は', 2),
                ('\0', 0),
            ],
        ),
        Uni(
            "東京タワー",
            10,
            &[
                ('東', 2),
                ('\0', 0),
                ('京', 2),
                ('\0', 0),
                ('タ', 2),
                ('\0', 0),
                ('ワ', 2),
                ('\0', 0),
                ('ー', 2),
                ('\0', 0),
            ],
        ),
        Uni("ｶﾀｶﾅ", 4, &[('ｶ', 1), ('ﾀ', 1), ('ｶ', 1), ('ﾅ', 1)]),
        Uni("u\u{30A}", 1, &[('u', 1)]),
    ];

    const CZECH: &str = "Příliš žluťoučký kůň úpěl ďábelské ódy";

    #[test]
    fn unicode_matrix_cells_widths_and_cursor() {
        for Uni(text, cols, cells_expected) in MATRIX {
            let width = unicode_width::UnicodeWidthStr::width(*text) as u16;
            assert_eq!(width, *cols, "utf8 width of {:?}", text);
            let mut t = Term::new(40, 2);
            t.process(text.as_bytes());
            let mut cells = vec![CboCell::default(); 80];
            t.snapshot(&mut cells);
            for (i, (cp, w)) in cells_expected.iter().enumerate() {
                assert_eq!(cells[i].cp, *cp as u32, "{:?} cell {} cp", text, i);
                assert_eq!(cells[i].width, *w, "{:?} cell {} width", text, i);
            }
            let after = cells_expected.len();
            assert_eq!(
                cells[after].cp, 0,
                "{:?} cell after text must be blank",
                text
            );
            assert_eq!(cells[after].width, 1);
            let (x, y, _) = t.cursor();
            assert_eq!((x, y), (*cols, 0), "{:?} cursor after echo", text);
        }
    }

    #[test]
    fn czech_pangram_every_char_is_one_column() {
        assert_eq!(unicode_width::UnicodeWidthStr::width(CZECH), 38);
        assert_eq!(CZECH.chars().count(), 38);
        let mut t = Term::new(80, 2);
        t.process(CZECH.as_bytes());
        let mut cells = vec![CboCell::default(); 160];
        t.snapshot(&mut cells);
        for (i, ch) in CZECH.chars().enumerate() {
            assert_eq!(cells[i].cp, ch as u32, "col {}", i);
            assert_eq!(cells[i].width, 1, "col {} ({})", i, ch);
        }
        assert_eq!(cells[38].cp, 0);
        assert_eq!(t.cursor(), (38, 0, true));
    }

    #[test]
    fn mixed_line_and_wrap_at_wide_boundary() {
        let mixed = "ls 你好 안녕 こんにちは Příliš";
        let w = unicode_width::UnicodeWidthStr::width(mixed);
        assert_eq!(w, 3 + 4 + 1 + 4 + 1 + 10 + 1 + 6);
        let mut t = Term::new(80, 3);
        t.process(mixed.as_bytes());
        assert_eq!(t.cursor(), (w as u16, 0, true));
        let mut cells = vec![CboCell::default(); 240];
        t.snapshot(&mut cells);
        assert_eq!(cells[3].cp, '你' as u32);
        assert_eq!(cells[4].width, 0);
        assert_eq!(cells[8].cp, '안' as u32);
        assert_eq!(cells[13].cp, 'こ' as u32);
        assert_eq!(cells[24].cp, 'P' as u32);
        assert_eq!(cells[29].cp, 'š' as u32);
        assert_eq!(cells[29].width, 1);

        // 79 ASCII + a wide char: it does not fit in col 79, so it wraps.
        let mut t = Term::new(80, 3);
        let line = format!("{}你", "a".repeat(79));
        t.process(line.as_bytes());
        let mut cells = vec![CboCell::default(); 240];
        t.snapshot(&mut cells);
        assert_eq!(cells[78].cp, 'a' as u32);
        assert_eq!(cells[79].cp, 0, "col 79 must be left blank");
        assert_eq!(cells[79].width, 1);
        assert_eq!(cells[80].cp, '你' as u32, "你 pushed to row 1 col 0");
        assert_eq!(cells[80].width, 2);
        assert_eq!(cells[81].width, 0);
        assert_eq!(t.cursor(), (2, 1, true));
    }

    fn b64(data: &[u8]) -> String {
        const T: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        let mut s = String::new();
        for chunk in data.chunks(3) {
            let n = chunk.len();
            let v = (chunk[0] as u32) << 16
                | (*chunk.get(1).unwrap_or(&0) as u32) << 8
                | *chunk.get(2).unwrap_or(&0) as u32;
            s.push(T[(v >> 18) as usize & 63] as char);
            s.push(T[(v >> 12) as usize & 63] as char);
            s.push(if n > 1 {
                T[(v >> 6) as usize & 63] as char
            } else {
                '='
            });
            s.push(if n > 2 {
                T[v as usize & 63] as char
            } else {
                '='
            });
        }
        s
    }

    #[test]
    fn kitty_image_is_stripped_placed_and_scrolls_with_text() {
        let mut t = Term::new(20, 5);
        let rgba = vec![0x80u8; 16 * 32 * 4]; // 2 cols x 2 rows at 8x16
        t.process(b"$ ");
        t.process(format!("\x1b_Ga=T,f=32,s=16,v=32,i=5;{}\x1b\\", b64(&rgba)).as_bytes());
        // the payload never reached the grid
        let mut cells = vec![CboCell::default(); 100];
        t.snapshot(&mut cells);
        assert_eq!(cells[0].cp, '$' as u32);
        assert_eq!(cells[2].cp, 0);
        assert_eq!(cells[20].cp, 0);
        // cursor moved past the image: row 1, col 4
        assert_eq!(t.cursor(), (4, 1, true));
        assert_eq!(t.take_responses(), b"\x1b_Gi=5;OK\x1b\\");
        let p = t.placements();
        assert_eq!(p.len(), 1);
        assert_eq!((p[0].col, p[0].row, p[0].cols, p[0].rows), (2, 0, 2, 2));
        let info = t.image_info(p[0].image_key).unwrap();
        assert_eq!(
            (info.width, info.height, info.format, info.bytes),
            (16, 32, 32, 2048)
        );
        assert_eq!(t.image(p[0].image_key).unwrap().data, rgba);
        // cursor on row 1 of 5: four line feeds scroll one line, the image
        // (2 rows tall) is half off the top; a fifth pushes it out.
        t.process(b"\n\n\n\n");
        assert_eq!(t.placements()[0].row, -1);
        t.process(b"\n");
        assert!(t.placements().is_empty());
        // scrolled back it is visible again
        t.set_scroll(2);
        assert_eq!(t.placements()[0].row, 0);
        t.set_scroll(0);
        // 2J on the screen it is not on keeps it; put it back and clear
        t.process(b"\x1b[2J");
        assert_eq!(t.gfx.placement_count(), 1);
        t.set_scroll(2);
        t.process(b"\x1b[2J");
        t.set_scroll(0);
        assert_eq!(
            t.gfx.placement_count(),
            1,
            "2J acts on the live screen only"
        );
    }

    #[test]
    fn kitty_alt_screen_placements_vanish_on_leave() {
        let mut t = Term::new(20, 5);
        t.process(b"\x1b[?1049h");
        let rgb = vec![0u8; 3];
        t.process(format!("\x1b_Ga=T,f=24,s=1,v=1,i=1,c=3,r=2;{}\x1b\\", b64(&rgb)).as_bytes());
        assert_eq!(t.placements().len(), 1);
        t.process(b"\x1b[?1049l");
        assert!(t.placements().is_empty());
        assert_eq!(t.gfx.placement_count(), 0);
    }

    #[test]
    fn kitty_sequence_split_across_reads_and_pixel_queries() {
        let mut t = Term::new(10, 3);
        let rgb = vec![0u8; 3];
        let seq = format!("A\x1b_Ga=T,f=24,s=1,v=1,i=1,c=1,r=1;{}\x1b\\B", b64(&rgb));
        let bytes = seq.as_bytes();
        for cut in 1..bytes.len() {
            let mut t = Term::new(10, 3);
            t.process(&bytes[..cut]);
            t.process(&bytes[cut..]);
            let mut cells = vec![CboCell::default(); 30];
            t.snapshot(&mut cells);
            assert_eq!(cells[0].cp, 'A' as u32, "cut {}", cut);
            assert_eq!(cells[2].cp, 'B' as u32, "cut {}", cut);
            assert_eq!(t.placements().len(), 1, "cut {}", cut);
        }
        t.set_cell_px(8, 16);
        assert!(!t.take_pixel_size_changed(), "same size is not a change");
        t.set_cell_px(10, 20);
        assert!(t.take_pixel_size_changed());
        t.process(b"\x1b[14t\x1b[16t");
        assert_eq!(t.take_responses(), b"\x1b[4;60;100t\x1b[6;20;10t");
    }
}
