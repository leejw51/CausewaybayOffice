//! Kitty graphics protocol: `ESC _ G <k=v,...>[;<base64>] ESC \`.
//!
//! The byte stream from the remote side is split into text runs (fed to the
//! VT parser) and APC bodies (handled here) so image payloads never reach
//! vt100. Images are kept as the client sent them (PNG or raw RGB/RGBA,
//! optionally zlib-compressed); decoding is the renderer's job. Placements
//! on the main screen are anchored to an absolute line number so they scroll
//! with the text; alternate-screen placements are anchored to screen rows
//! and dropped when the alternate screen is left.
//!
//! Supported: a=q/t/T/p/d, f=24/32/100, t=d, o=z, chunked transfers (m=1),
//! i/I/p ids, s/v/x/y/w/h/c/r/z/C/q. Unsupported media (file, temp, shm)
//! answer with an error so clients such as `kitten icat` fall back to
//! streaming.

use std::collections::VecDeque;

/// Largest APC body accepted (control data + one base64 chunk).
const MAX_APC: usize = 16 * 1024 * 1024;
/// Largest single image accepted, as stored (bytes).
const MAX_IMAGE: usize = 64 * 1024 * 1024;
/// Total bytes of image data kept per terminal before old images are evicted.
const MAX_STORE: usize = 128 * 1024 * 1024;
/// Placements this far above the top of scrollback are forgotten.
const FORGET_LINES: i64 = crate::term::SCROLLBACK_LINES as i64;

pub const FMT_RGB: u32 = 24;
pub const FMT_RGBA: u32 = 32;
pub const FMT_PNG: u32 = 100;

/// Mirror of `CboPlacement` in cbo.h. Layout is frozen: 48 bytes, 8-aligned.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct CboPlacement {
    pub image_key: u64,
    pub image_id: u32,
    pub placement_id: u32,
    pub col: i32,
    pub row: i32,
    pub cols: u16,
    pub rows: u16,
    pub z: i32,
    pub src_x: u32,
    pub src_y: u32,
    pub src_w: u32,
    pub src_h: u32,
}

/// Mirror of `CboImageInfo` in cbo.h. Layout is frozen: 32 bytes, 8-aligned.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct CboImageInfo {
    pub key: u64,
    pub width: u32,
    pub height: u32,
    pub bytes: u32,
    pub format: u32,
    pub compressed: u32,
    pub _pad: u32,
}

#[derive(Debug)]
pub struct Image {
    pub key: u64,
    pub id: u32,
    pub number: u32,
    pub format: u32,
    pub width: u32,
    pub height: u32,
    pub compressed: bool,
    pub data: Vec<u8>,
}

#[derive(Clone, Debug)]
pub struct Placement {
    pub image_key: u64,
    pub image_id: u32,
    pub placement_id: u32,
    /// Absolute line (main screen) or screen row (alternate screen).
    pub line: i64,
    pub col: i32,
    pub cols: u16,
    pub rows: u16,
    pub z: i32,
    pub src: (u32, u32, u32, u32),
    pub alt: bool,
}

/// One split segment of the input stream, in order.
pub enum Seg {
    Text(Vec<u8>),
    Apc(Vec<u8>),
}

#[derive(Default)]
enum Split {
    #[default]
    Ground,
    Esc,
    Apc(Vec<u8>),
    ApcEsc(Vec<u8>),
}

/// Parsed control data of one command (defaults per the protocol).
#[derive(Clone, Debug)]
struct Ctrl {
    action: u8,
    quiet: u32,
    format: u32,
    medium: u8,
    width: u32,
    height: u32,
    id: u32,
    number: u32,
    placement: u32,
    compression: u8,
    more: bool,
    src_x: u32,
    src_y: u32,
    src_w: u32,
    src_h: u32,
    cols: u32,
    rows: u32,
    z: i32,
    cursor_stay: bool,
    virtual_: bool,
    delete: u8,
    x: u32,
    y: u32,
}

impl Default for Ctrl {
    fn default() -> Self {
        Ctrl {
            action: b't',
            quiet: 0,
            format: FMT_RGBA,
            medium: b'd',
            width: 0,
            height: 0,
            id: 0,
            number: 0,
            placement: 0,
            compression: 0,
            more: false,
            src_x: 0,
            src_y: 0,
            src_w: 0,
            src_h: 0,
            cols: 0,
            rows: 0,
            z: 0,
            cursor_stay: false,
            virtual_: false,
            delete: b'a',
            x: 0,
            y: 0,
        }
    }
}

fn parse_ctrl(s: &[u8]) -> Ctrl {
    let mut c = Ctrl::default();
    for kv in s.split(|&b| b == b',') {
        let mut it = kv.splitn(2, |&b| b == b'=');
        let (Some(k), Some(v)) = (it.next(), it.next()) else {
            continue;
        };
        if k.len() != 1 {
            continue;
        }
        let vs = std::str::from_utf8(v).unwrap_or("");
        let u = vs.parse::<u32>().unwrap_or(0);
        match k[0] {
            b'a' => c.action = v.first().copied().unwrap_or(b't'),
            b'q' => c.quiet = u,
            b'f' => c.format = u,
            b't' => c.medium = v.first().copied().unwrap_or(b'd'),
            b's' => c.width = u,
            b'v' => c.height = u,
            b'i' => c.id = u,
            b'I' => c.number = u,
            b'p' => c.placement = u,
            b'o' => c.compression = v.first().copied().unwrap_or(0),
            b'm' => c.more = u != 0,
            b'x' => c.src_x = u,
            b'y' => c.src_y = u,
            b'w' => c.src_w = u,
            b'h' => c.src_h = u,
            b'c' => c.cols = u,
            b'r' => c.rows = u,
            b'z' => c.z = vs.parse::<i32>().unwrap_or(0),
            b'C' => c.cursor_stay = u != 0,
            b'U' => c.virtual_ = u != 0,
            b'd' => c.delete = v.first().copied().unwrap_or(b'a'),
            b'X' => c.x = u,
            b'Y' => c.y = u,
            _ => {}
        }
    }
    c
}

/// Standard base64 (RFC 4648), padding optional, whitespace ignored.
/// `None` on a byte outside the alphabet.
pub fn base64_decode(input: &[u8]) -> Option<Vec<u8>> {
    /// `Some(None)` skips the byte, `None` rejects the input.
    fn val(b: u8) -> Option<Option<u8>> {
        Some(Some(match b {
            b'A'..=b'Z' => b - b'A',
            b'a'..=b'z' => b - b'a' + 26,
            b'0'..=b'9' => b - b'0' + 52,
            b'+' | b'-' => 62,
            b'/' | b'_' => 63,
            b'=' | b'\n' | b'\r' | b' ' | b'\t' => return Some(None),
            _ => return None,
        }))
    }
    let mut out = Vec::with_capacity(input.len() / 4 * 3 + 3);
    let (mut acc, mut bits) = (0u32, 0u32);
    for &b in input {
        if let Some(v) = val(b)? {
            acc = (acc << 6) | v as u32;
            bits += 6;
            if bits >= 8 {
                bits -= 8;
                out.push((acc >> bits) as u8);
                acc &= (1 << bits) - 1;
            }
        }
    }
    Some(out)
}

/// (width, height) from a PNG IHDR chunk.
pub fn png_size(data: &[u8]) -> Option<(u32, u32)> {
    const SIG: [u8; 8] = [0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A];
    if data.len() < 24 || data[..8] != SIG || &data[12..16] != b"IHDR" {
        return None;
    }
    let be = |i: usize| u32::from_be_bytes([data[i], data[i + 1], data[i + 2], data[i + 3]]);
    let (w, h) = (be(16), be(20));
    (w > 0 && h > 0).then_some((w, h))
}

/// A display request produced by a command; the terminal applies it at the
/// current cursor position.
pub struct Display {
    pub image_key: u64,
    pub image_id: u32,
    pub placement_id: u32,
    pub cols: u16,
    pub rows: u16,
    pub z: i32,
    pub src: (u32, u32, u32, u32),
    pub move_cursor: bool,
}

/// Everything the terminal needs to know about the screen when a command is
/// applied.
#[derive(Clone, Copy)]
pub struct Cursor {
    pub col: u16,
    pub row: u16,
    pub screen_cols: u16,
    pub screen_rows: u16,
    pub abs_top: i64,
    pub alt: bool,
}

pub struct Graphics {
    split: Split,
    pending: Option<(Ctrl, Vec<u8>)>,
    images: VecDeque<Image>,
    placements: Vec<Placement>,
    responses: Vec<u8>,
    next_key: u64,
    next_auto_id: u32,
    stored: usize,
    pub cell_w: u16,
    pub cell_h: u16,
    pub changed: bool,
}

impl Default for Graphics {
    fn default() -> Self {
        Graphics {
            split: Split::Ground,
            pending: None,
            images: VecDeque::new(),
            placements: Vec::new(),
            responses: Vec::new(),
            next_key: 1,
            next_auto_id: 0x8000_0000,
            stored: 0,
            cell_w: 8,
            cell_h: 16,
            changed: false,
        }
    }
}

impl Graphics {
    /// Split `bytes` into text runs and APC bodies, carrying state across
    /// calls so a sequence may straddle chunk boundaries. An ESC that ends a
    /// chunk is held back until the next byte says what it starts.
    pub fn split(&mut self, bytes: &[u8]) -> Vec<Seg> {
        let mut segs = Vec::new();
        let mut text: Vec<u8> = Vec::with_capacity(bytes.len());
        for &b in bytes {
            match std::mem::take(&mut self.split) {
                Split::Ground => {
                    if b == 0x1b {
                        self.split = Split::Esc;
                    } else {
                        text.push(b);
                    }
                }
                Split::Esc => {
                    if b == b'_' {
                        if !text.is_empty() {
                            segs.push(Seg::Text(std::mem::take(&mut text)));
                        }
                        self.split = Split::Apc(Vec::new());
                    } else if b == 0x1b {
                        text.push(0x1b);
                        self.split = Split::Esc;
                    } else {
                        text.push(0x1b);
                        text.push(b);
                    }
                }
                Split::Apc(mut body) => {
                    if b == 0x1b {
                        self.split = Split::ApcEsc(body);
                    } else {
                        if body.len() < MAX_APC {
                            body.push(b);
                        }
                        self.split = Split::Apc(body);
                    }
                }
                Split::ApcEsc(mut body) => {
                    if b == b'\\' {
                        segs.push(Seg::Apc(body));
                    } else {
                        if body.len() < MAX_APC {
                            body.push(0x1b);
                            body.push(b);
                        }
                        self.split = Split::Apc(body);
                    }
                }
            }
        }
        if !text.is_empty() {
            segs.push(Seg::Text(text));
        }
        segs
    }

    /// Bytes to send back to the client (protocol responses), drained.
    pub fn take_responses(&mut self) -> Vec<u8> {
        std::mem::take(&mut self.responses)
    }

    pub fn push_response(&mut self, bytes: &[u8]) {
        self.responses.extend_from_slice(bytes);
    }

    fn respond(&mut self, c: &Ctrl, id: u32, msg: &str) {
        if c.quiet >= 2 || (c.quiet == 1 && msg == "OK") {
            return;
        }
        if id == 0 && c.number == 0 && c.action != b'q' {
            return;
        }
        let mut s = format!("\x1b_Gi={}", id);
        if c.number != 0 {
            s.push_str(&format!(",I={}", c.number));
        }
        if c.placement != 0 {
            s.push_str(&format!(",p={}", c.placement));
        }
        s.push(';');
        s.push_str(msg);
        s.push_str("\x1b\\");
        self.responses.extend_from_slice(s.as_bytes());
    }

    /// Handle one APC body (everything between `ESC _` and `ESC \`).
    /// Returns a display request when the command shows an image.
    pub fn command(&mut self, body: &[u8], cur: Cursor) -> Option<Display> {
        if body.first() != Some(&b'G') {
            return None;
        }
        let body = &body[1..];
        let (ctrl, payload) = match body.iter().position(|&b| b == b';') {
            Some(p) => (&body[..p], &body[p + 1..]),
            None => (body, body),
        };
        let chunk = parse_ctrl(ctrl);

        // Continuation of a chunked transfer: only m (and q) matter.
        if let Some((mut c, mut data)) = self.pending.take() {
            match base64_decode(payload) {
                Some(bytes) => data.extend_from_slice(&bytes),
                None => {
                    self.respond(&c, c.id, "EINVAL:bad base64");
                    return None;
                }
            }
            if data.len() > MAX_IMAGE {
                self.respond(&c, c.id, "ENOSPC:image too large");
                return None;
            }
            if chunk.more {
                self.pending = Some((c, data));
                return None;
            }
            c.quiet = c.quiet.max(chunk.quiet);
            return self.finish(c, data, cur);
        }

        match chunk.action {
            b'q' | b't' | b'T' => {
                if let Err(msg) = self.validate(&chunk) {
                    self.respond(&chunk, chunk.id, msg);
                    return None;
                }
                let data = match base64_decode(payload) {
                    Some(d) => d,
                    None => {
                        self.respond(&chunk, chunk.id, "EINVAL:bad base64");
                        return None;
                    }
                };
                if chunk.action == b'q' {
                    self.respond(&chunk, chunk.id, "OK");
                    return None;
                }
                if chunk.more {
                    self.pending = Some((chunk, data));
                    return None;
                }
                self.finish(chunk, data, cur)
            }
            b'p' => {
                let found = if chunk.id != 0 {
                    self.images.iter().rev().find(|im| im.id == chunk.id)
                } else if chunk.number != 0 {
                    self.images
                        .iter()
                        .rev()
                        .find(|im| im.number == chunk.number)
                } else {
                    None
                };
                let Some(im) = found else {
                    self.respond(&chunk, chunk.id, "ENOENT:no such image");
                    return None;
                };
                let (key, id, w, h) = (im.key, im.id, im.width, im.height);
                let d = self.place(&chunk, key, id, w, h, cur);
                self.respond(&chunk, id, "OK");
                d
            }
            b'd' => {
                self.delete(&chunk, cur);
                None
            }
            // frames, animation, composition: not supported, silently ignored
            _ => None,
        }
    }

    fn validate(&self, c: &Ctrl) -> Result<(), &'static str> {
        if c.medium != b'd' {
            return Err("EBADF:only direct transmission is supported");
        }
        if !matches!(c.format, FMT_RGB | FMT_RGBA | FMT_PNG) {
            return Err("EINVAL:unknown format");
        }
        if c.compression != 0 && c.compression != b'z' {
            return Err("EINVAL:unknown compression");
        }
        if c.format != FMT_PNG && (c.width == 0 || c.height == 0) {
            return Err("EINVAL:raw data needs s and v");
        }
        Ok(())
    }

    /// Store a fully received image and, for a=T, display it.
    fn finish(&mut self, c: Ctrl, data: Vec<u8>, cur: Cursor) -> Option<Display> {
        let compressed = c.compression == b'z';
        let (w, h) = if c.format == FMT_PNG {
            if compressed {
                (c.width, c.height)
            } else {
                match png_size(&data) {
                    Some(wh) => wh,
                    None => {
                        self.respond(&c, c.id, "EBADPNG:invalid png");
                        return None;
                    }
                }
            }
        } else {
            let bpp = if c.format == FMT_RGB { 3 } else { 4 };
            let want = c.width as usize * c.height as usize * bpp;
            if !compressed && data.len() != want {
                self.respond(&c, c.id, "EINVAL:data size does not match s*v");
                return None;
            }
            (c.width, c.height)
        };
        if data.len() > MAX_IMAGE {
            self.respond(&c, c.id, "ENOSPC:image too large");
            return None;
        }
        // Reusing an id: the old image loses its id but whatever is already
        // on screen stays there (placements refer to the key, not the id), and
        // it is freed once nothing shows it any more. Kitty deletes the old
        // placements instead; keeping them is friendlier for tools that use a
        // fixed id on every run.
        if c.id != 0 {
            let used: Vec<u64> = self.placements.iter().map(|p| p.image_key).collect();
            let mut orphaned: Vec<u64> = Vec::new();
            for im in self.images.iter_mut().filter(|im| im.id == c.id) {
                im.id = 0;
                im.number = 0;
                orphaned.push(im.key);
            }
            for p in self.placements.iter_mut() {
                if orphaned.contains(&p.image_key) {
                    p.image_id = 0;
                }
            }
            self.remove_images(|im| im.id == 0 && im.number == 0 && !used.contains(&im.key));
        }
        let id = if c.id != 0 {
            c.id
        } else if c.number != 0 {
            self.next_auto_id += 1;
            self.next_auto_id
        } else {
            0
        };
        let key = self.next_key;
        self.next_key += 1;
        self.stored += data.len();
        self.images.push_back(Image {
            key,
            id,
            number: c.number,
            format: c.format,
            width: w,
            height: h,
            compressed,
            data,
        });
        self.changed = true;
        self.evict();
        let display = if c.action == b'T' && !c.virtual_ {
            self.place(&c, key, id, w, h, cur)
        } else {
            None
        };
        self.respond(&c, id, "OK");
        display
    }

    fn place(
        &mut self,
        c: &Ctrl,
        key: u64,
        id: u32,
        w: u32,
        h: u32,
        cur: Cursor,
    ) -> Option<Display> {
        if c.virtual_ {
            return None;
        }
        let sx = c.src_x.min(w);
        let sy = c.src_y.min(h);
        let sw = if c.src_w == 0 {
            w - sx
        } else {
            c.src_w.min(w - sx)
        };
        let sh = if c.src_h == 0 {
            h - sy
        } else {
            c.src_h.min(h - sy)
        };
        let (cw, ch) = (self.cell_w.max(1) as u32, self.cell_h.max(1) as u32);
        let cols = if c.cols > 0 {
            c.cols
        } else {
            sw.div_ceil(cw).max(1)
        };
        let rows = if c.rows > 0 {
            c.rows
        } else {
            sh.div_ceil(ch).max(1)
        };
        let cols = cols.min(u16::MAX as u32) as u16;
        let rows = rows.min(u16::MAX as u32) as u16;
        // A placement id replaces an existing placement of the same image.
        if c.placement != 0 {
            self.placements
                .retain(|p| !(p.image_key == key && p.placement_id == c.placement));
        }
        self.placements.push(Placement {
            image_key: key,
            image_id: id,
            placement_id: c.placement,
            line: if cur.alt {
                cur.row as i64
            } else {
                cur.abs_top + cur.row as i64
            },
            col: cur.col as i32,
            cols,
            rows,
            z: c.z,
            src: (sx, sy, sw, sh),
            alt: cur.alt,
        });
        self.changed = true;
        Some(Display {
            image_key: key,
            image_id: id,
            placement_id: c.placement,
            cols,
            rows,
            z: c.z,
            src: (sx, sy, sw, sh),
            move_cursor: !c.cursor_stay,
        })
    }

    fn delete(&mut self, c: &Ctrl, cur: Cursor) {
        let free = c.delete.is_ascii_uppercase();
        let kind = c.delete.to_ascii_lowercase();
        let before = self.placements.len();
        match kind {
            b'a' => {
                let vis: Vec<u64> = self.visible(cur, 0).iter().map(|p| p.image_key).collect();
                let alt = cur.alt;
                self.placements
                    .retain(|p| p.alt != alt || !is_visible(p, cur, 0));
                if free {
                    self.remove_images(|im| vis.contains(&im.key));
                }
            }
            b'i' => {
                let keys: Vec<u64> = self
                    .images
                    .iter()
                    .filter(|im| im.id == c.id)
                    .map(|im| im.key)
                    .collect();
                self.placements.retain(|p| {
                    !(keys.contains(&p.image_key)
                        && (c.placement == 0 || p.placement_id == c.placement))
                });
                if free && c.placement == 0 {
                    self.remove_images(|im| keys.contains(&im.key));
                }
            }
            b'n' => {
                let keys: Vec<u64> = self
                    .images
                    .iter()
                    .filter(|im| im.number == c.number && c.number != 0)
                    .map(|im| im.key)
                    .collect();
                self.placements.retain(|p| !keys.contains(&p.image_key));
                if free {
                    self.remove_images(|im| keys.contains(&im.key));
                }
            }
            b'c' | b'p' => {
                // cell (1-based x,y for 'p'; cursor for 'c')
                let (x, y) = if kind == b'c' {
                    (cur.col as i64, cur.row as i64)
                } else {
                    (c.x as i64 - 1, c.y as i64 - 1)
                };
                let line = if cur.alt { y } else { cur.abs_top + y };
                let alt = cur.alt;
                self.placements.retain(|p| {
                    let hit = p.alt == alt
                        && x >= p.col as i64
                        && x < p.col as i64 + p.cols as i64
                        && line >= p.line
                        && line < p.line + p.rows as i64;
                    !hit
                });
            }
            b'z' => {
                self.placements.retain(|p| p.z != c.z);
            }
            _ => {}
        }
        if self.placements.len() != before {
            self.changed = true;
        }
        self.gc_anonymous();
    }

    /// Drop the alternate-screen placements (when the alt screen is left).
    pub fn clear_alt(&mut self) {
        let before = self.placements.len();
        self.placements.retain(|p| !p.alt);
        if self.placements.len() != before {
            self.changed = true;
        }
        self.gc_anonymous();
    }

    /// `ESC[2J` / `ESC[3J`: images on the screen go away with the text.
    pub fn clear_screen(&mut self, cur: Cursor) {
        let before = self.placements.len();
        self.placements
            .retain(|p| p.alt != cur.alt || !is_visible(p, cur, 0));
        if self.placements.len() != before {
            self.changed = true;
        }
        self.gc_anonymous();
    }

    /// Placements intersecting the screen, in stable order, with `scroll`
    /// lines of scrollback shown above the live screen.
    pub fn visible(&self, cur: Cursor, scroll: i32) -> Vec<CboPlacement> {
        let mut out: Vec<CboPlacement> = self
            .placements
            .iter()
            .filter(|p| p.alt == cur.alt && is_visible(p, cur, scroll))
            .map(|p| CboPlacement {
                image_key: p.image_key,
                image_id: p.image_id,
                placement_id: p.placement_id,
                col: p.col,
                row: screen_row(p, cur, scroll) as i32,
                cols: p.cols,
                rows: p.rows,
                z: p.z,
                src_x: p.src.0,
                src_y: p.src.1,
                src_w: p.src.2,
                src_h: p.src.3,
            })
            .collect();
        out.sort_by_key(|p| p.z);
        out
    }

    /// Forget placements that scrolled out of scrollback; free images that
    /// nothing refers to any more.
    pub fn prune(&mut self, abs_top: i64) {
        let before = self.placements.len();
        self.placements
            .retain(|p| p.alt || p.line + p.rows as i64 > abs_top - FORGET_LINES);
        if self.placements.len() != before {
            self.changed = true;
            self.gc_anonymous();
        }
    }

    fn gc_anonymous(&mut self) {
        let used: Vec<u64> = self.placements.iter().map(|p| p.image_key).collect();
        self.remove_images(|im| im.id == 0 && im.number == 0 && !used.contains(&im.key));
    }

    fn remove_images(&mut self, pred: impl Fn(&Image) -> bool) {
        let mut removed: Vec<u64> = Vec::new();
        self.images.retain(|im| {
            if pred(im) {
                removed.push(im.key);
                false
            } else {
                true
            }
        });
        if !removed.is_empty() {
            self.stored = self.images.iter().map(|im| im.data.len()).sum();
            self.placements.retain(|p| !removed.contains(&p.image_key));
            self.changed = true;
        }
    }

    /// Keep the store under budget: oldest images first, but never one that
    /// still has a placement (those are what the user is looking at).
    fn evict(&mut self) {
        while self.stored > MAX_STORE {
            let used: Vec<u64> = self.placements.iter().map(|p| p.image_key).collect();
            let Some(pos) = self.images.iter().position(|im| !used.contains(&im.key)) else {
                // everything is placed: drop the oldest anyway
                if let Some(im) = self.images.pop_front() {
                    self.stored -= im.data.len();
                    self.placements.retain(|p| p.image_key != im.key);
                    self.changed = true;
                    continue;
                }
                break;
            };
            let im = self.images.remove(pos).expect("position is in range");
            self.stored -= im.data.len();
            self.changed = true;
        }
    }

    pub fn image(&self, key: u64) -> Option<&Image> {
        self.images.iter().find(|im| im.key == key)
    }

    pub fn image_count(&self) -> usize {
        self.images.len()
    }

    pub fn placement_count(&self) -> usize {
        self.placements.len()
    }

    pub fn stored_bytes(&self) -> usize {
        self.stored
    }
}

fn screen_row(p: &Placement, cur: Cursor, scroll: i32) -> i64 {
    if p.alt {
        p.line
    } else {
        p.line - (cur.abs_top - scroll as i64)
    }
}

fn is_visible(p: &Placement, cur: Cursor, scroll: i32) -> bool {
    let row = screen_row(p, cur, scroll);
    row + p.rows as i64 > 0
        && row < cur.screen_rows as i64
        && p.col < cur.screen_cols as i32
        && p.col + p.cols as i32 > 0
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cur() -> Cursor {
        Cursor {
            col: 3,
            row: 2,
            screen_cols: 80,
            screen_rows: 24,
            abs_top: 100,
            alt: false,
        }
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
    fn layouts_are_frozen() {
        assert_eq!(std::mem::size_of::<CboPlacement>(), 48);
        assert_eq!(std::mem::align_of::<CboPlacement>(), 8);
        assert_eq!(std::mem::size_of::<CboImageInfo>(), 32);
        assert_eq!(std::mem::align_of::<CboImageInfo>(), 8);
    }

    #[test]
    fn base64_roundtrip_and_errors() {
        assert_eq!(base64_decode(b"aGVsbG8=").unwrap(), b"hello");
        assert_eq!(base64_decode(b"aGVsbG8").unwrap(), b"hello");
        assert_eq!(base64_decode(b"").unwrap(), b"");
        assert_eq!(
            base64_decode(b64(b"\x00\xff\x10").as_bytes()).unwrap(),
            b"\x00\xff\x10"
        );
        assert!(base64_decode(b"a$b").is_none());
    }

    #[test]
    fn split_keeps_text_and_extracts_apc_across_chunks() {
        let mut g = Graphics::default();
        let s1 = b"hello \x1b_Gi=1,a=q;AAAA\x1b\\ world \x1b[31m";
        let segs = g.split(s1);
        let mut text = Vec::new();
        let mut apcs = Vec::new();
        for s in segs {
            match s {
                Seg::Text(t) => text.extend_from_slice(&t),
                Seg::Apc(a) => apcs.push(a),
            }
        }
        assert_eq!(text, b"hello  world \x1b[31m");
        assert_eq!(apcs, vec![b"Gi=1,a=q;AAAA".to_vec()]);

        // APC split at every possible byte boundary
        let whole = b"ab\x1b_Gi=2,a=q;AAAA\x1b\\cd";
        for cut in 0..=whole.len() {
            let mut g = Graphics::default();
            let mut text = Vec::new();
            let mut apcs = Vec::new();
            for part in [&whole[..cut], &whole[cut..]] {
                for s in g.split(part) {
                    match s {
                        Seg::Text(t) => text.extend_from_slice(&t),
                        Seg::Apc(a) => apcs.push(a),
                    }
                }
            }
            assert_eq!(text, b"abcd", "cut at {}", cut);
            assert_eq!(apcs, vec![b"Gi=2,a=q;AAAA".to_vec()], "cut at {}", cut);
        }

        // A trailing ESC that turns out to be a CSI is passed through intact.
        let mut g = Graphics::default();
        let mut text = Vec::new();
        for part in [&b"x\x1b"[..], &b"[1mY"[..]] {
            for s in g.split(part) {
                if let Seg::Text(t) = s {
                    text.extend_from_slice(&t);
                }
            }
        }
        assert_eq!(text, b"x\x1b[1mY");

        // Two ESCs back to back.
        let mut g = Graphics::default();
        let mut text = Vec::new();
        for s in g.split(b"\x1b\x1b[A") {
            if let Seg::Text(t) = s {
                text.extend_from_slice(&t);
            }
        }
        assert_eq!(text, b"\x1b\x1b[A");
    }

    #[test]
    fn query_answers_ok_and_rejects_files() {
        let mut g = Graphics::default();
        assert!(g
            .command(b"Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA", cur())
            .is_none());
        assert_eq!(g.take_responses(), b"\x1b_Gi=31;OK\x1b\\");
        g.command(b"Gi=32,s=1,v=1,a=q,t=f;L3RtcC94", cur());
        let r = String::from_utf8(g.take_responses()).unwrap();
        assert!(r.starts_with("\x1b_Gi=32;EBADF"), "{}", r);
        assert_eq!(g.image_count(), 0);
    }

    #[test]
    fn transmit_display_places_and_moves_cursor() {
        let mut g = Graphics::default();
        let rgb = [0u8; 2 * 2 * 3];
        let body = format!("Ga=T,f=24,s=2,v=2,i=7,c=4,r=3;{}", b64(&rgb));
        let d = g.command(body.as_bytes(), cur()).expect("display");
        assert_eq!((d.cols, d.rows), (4, 3));
        assert!(d.move_cursor);
        assert_eq!(g.take_responses(), b"\x1b_Gi=7;OK\x1b\\");
        let vis = g.visible(cur(), 0);
        assert_eq!(vis.len(), 1);
        assert_eq!((vis[0].col, vis[0].row), (3, 2));
        assert_eq!(vis[0].image_id, 7);
        // scrolled 4 lines: the image moved up 4 rows (one row still shows)
        let mut c2 = cur();
        c2.abs_top += 4;
        assert_eq!(g.visible(c2, 0)[0].row, -2);
        // and scrolling back down brings it back
        assert_eq!(g.visible(c2, 4)[0].row, 2);
        c2.abs_top += 100;
        assert!(g.visible(c2, 0).is_empty());
        // alt screen hides main-screen placements
        let mut c3 = cur();
        c3.alt = true;
        assert!(g.visible(c3, 0).is_empty());
    }

    #[test]
    fn size_from_pixels_and_cell_size() {
        let mut g = Graphics {
            cell_w: 8,
            cell_h: 16,
            ..Default::default()
        };
        let rgba = vec![0u8; 20 * 33 * 4];
        let body = format!("Ga=T,f=32,s=20,v=33,i=1;{}", b64(&rgba));
        let d = g.command(body.as_bytes(), cur()).unwrap();
        assert_eq!((d.cols, d.rows), (3, 3));
        assert_eq!(d.src, (0, 0, 20, 33));
    }

    #[test]
    fn chunked_transfer_then_put_by_id() {
        let mut g = Graphics::default();
        let rgb: Vec<u8> = (0..12u8).collect(); // 2x2 RGB
        let enc = b64(&rgb);
        let (a, b) = enc.split_at(8);
        assert!(g
            .command(format!("Ga=t,f=24,s=2,v=2,i=9,m=1;{}", a).as_bytes(), cur())
            .is_none());
        assert!(g.take_responses().is_empty());
        assert!(g.command(format!("Gm=0;{}", b).as_bytes(), cur()).is_none());
        assert_eq!(g.take_responses(), b"\x1b_Gi=9;OK\x1b\\");
        let im = g.image(1).unwrap();
        assert_eq!(im.data, rgb);
        assert_eq!((im.width, im.height, im.format), (2, 2, FMT_RGB));
        assert!(g.visible(cur(), 0).is_empty());
        let d = g.command(b"Ga=p,i=9,p=4,z=-1,C=1", cur()).unwrap();
        assert!(!d.move_cursor);
        assert_eq!(d.placement_id, 4);
        assert_eq!(g.take_responses(), b"\x1b_Gi=9,p=4;OK\x1b\\");
        assert_eq!(g.visible(cur(), 0)[0].z, -1);
        g.command(b"Ga=p,i=404", cur());
        assert!(String::from_utf8(g.take_responses())
            .unwrap()
            .contains("ENOENT"));
    }

    #[test]
    fn png_header_and_bad_png() {
        let mut png = vec![0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13];
        png.extend_from_slice(b"IHDR");
        png.extend_from_slice(&64u32.to_be_bytes());
        png.extend_from_slice(&48u32.to_be_bytes());
        png.extend_from_slice(&[8, 6, 0, 0, 0]);
        assert_eq!(png_size(&png), Some((64, 48)));
        let mut g = Graphics::default();
        let d = g
            .command(format!("Ga=T,f=100,i=3;{}", b64(&png)).as_bytes(), cur())
            .unwrap();
        assert_eq!((d.cols, d.rows), (8, 3));
        g.command(format!("Ga=T,f=100,i=4;{}", b64(b"nope")).as_bytes(), cur());
        let r = String::from_utf8(g.take_responses()).unwrap();
        assert!(r.contains("i=3;OK") && r.contains("i=4;EBADPNG"), "{}", r);
    }

    #[test]
    fn delete_variants() {
        let mut g = Graphics::default();
        let rgb = [0u8; 3];
        let one = b64(&rgb);
        g.command(
            format!("Ga=T,f=24,s=1,v=1,i=1,c=2,r=2;{}", one).as_bytes(),
            cur(),
        );
        g.command(
            format!("Ga=T,f=24,s=1,v=1,i=2,c=2,r=2,z=5;{}", one).as_bytes(),
            cur(),
        );
        assert_eq!(g.placement_count(), 2);
        g.command(b"Ga=d,d=i,i=1", cur());
        assert_eq!(g.placement_count(), 1);
        assert_eq!(g.image_count(), 2, "lowercase keeps the data");
        g.command(b"Ga=d,d=Z,z=5", cur());
        assert_eq!(g.placement_count(), 0);
        g.command(
            format!("Ga=T,f=24,s=1,v=1,c=2,r=2;{}", one).as_bytes(),
            cur(),
        );
        assert_eq!(g.image_count(), 3);
        g.command(b"Ga=d,d=A", cur());
        assert_eq!(g.placement_count(), 0);
        assert_eq!(
            g.image_count(),
            2,
            "anonymous image freed with its placement"
        );
        g.command(b"Ga=d,d=I,i=2", cur());
        assert_eq!(g.image_count(), 1);
        // reusing id 1 while nothing shows the old image drops the old data
        g.command(format!("Ga=T,f=24,s=1,v=1,i=1;{}", one).as_bytes(), cur());
        assert_eq!(g.image_count(), 1);
        // 2J clears what is on screen
        g.clear_screen(cur());
        assert_eq!(g.placement_count(), 0);
    }

    #[test]
    fn reused_id_keeps_the_old_picture_on_screen() {
        let mut g = Graphics::default();
        let one = b64(&[0u8; 3]);
        g.command(
            format!("Ga=T,f=24,s=1,v=1,i=1,c=2,r=2;{}", one).as_bytes(),
            cur(),
        );
        let mut c2 = cur();
        c2.row = 10;
        g.command(
            format!("Ga=T,f=24,s=1,v=1,i=1,c=2,r=2;{}", one).as_bytes(),
            c2,
        );
        assert_eq!(g.placement_count(), 2, "both runs stay visible");
        assert_eq!(g.image_count(), 2);
        let vis = g.visible(cur(), 0);
        assert_eq!(vis.len(), 2);
        assert_eq!(vis.iter().filter(|p| p.image_id == 1).count(), 1);
        // id 1 now means the new image only
        g.command(b"Ga=d,d=I,i=1", cur());
        assert_eq!(g.placement_count(), 1);
        assert_eq!(g.image_count(), 1);
        // the orphan goes once it scrolls out of reach
        g.prune(cur().abs_top + 100_000);
        assert_eq!(g.image_count(), 0);
    }

    #[test]
    fn quiet_suppresses_responses() {
        let mut g = Graphics::default();
        g.command(b"Ga=q,i=1,s=1,v=1,f=24,q=1;AAAA", cur());
        assert!(g.take_responses().is_empty());
        g.command(b"Ga=q,i=1,t=f,q=1;AAAA", cur());
        assert!(
            !g.take_responses().is_empty(),
            "errors still reported with q=1"
        );
        g.command(b"Ga=q,i=1,t=f,q=2;AAAA", cur());
        assert!(g.take_responses().is_empty());
        // no id and no number: silent
        g.command(b"Ga=T,f=24,s=1,v=1;AAAA", cur());
        assert!(g.take_responses().is_empty());
        assert_eq!(g.placement_count(), 1);
    }

    #[test]
    fn number_gets_an_assigned_id() {
        let mut g = Graphics::default();
        g.command(b"Ga=t,f=24,s=1,v=1,I=77;AAAA", cur());
        let r = String::from_utf8(g.take_responses()).unwrap();
        assert!(r.starts_with("\x1b_Gi=2147483649,I=77;OK"), "{}", r);
        assert!(g.command(b"Ga=p,I=77", cur()).is_some());
    }

    #[test]
    fn store_budget_evicts_old_unplaced_images() {
        let mut g = Graphics::default();
        // 3 images of 48 MB each exceed the 128 MB budget
        let big = vec![0u8; 48 * 1024 * 1024];
        let enc = b64(&big);
        for i in 1..=3 {
            let body = format!("Ga=t,f=24,s=4194304,v=4,i={},{};{}", i, "q=2", enc);
            g.command(body.as_bytes(), cur());
        }
        assert!(g.stored_bytes() <= MAX_STORE);
        assert_eq!(g.image_count(), 2);
        assert!(g.image(1).is_none(), "oldest evicted");
    }
}
