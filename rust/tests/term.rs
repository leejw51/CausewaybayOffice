//! Terminal emulation through the public Rust API. Pure in-process.

mod common;

use cbo_core::term::*;
use common::{expected_cells, CZECH, MATRIX};

fn snap(t: &Term, n: usize) -> Vec<CboCell> {
    let mut cells = vec![CboCell::default(); n];
    assert_eq!(t.snapshot(&mut cells), n.min(cell_count(t)));
    cells
}

fn cell_count(t: &Term) -> usize {
    let (c, r) = t.size();
    c as usize * r as usize
}

fn row_text(cells: &[CboCell], cols: usize, row: usize) -> String {
    cells[row * cols..(row + 1) * cols]
        .iter()
        .filter(|c| c.width != 0)
        .map(|c| {
            if c.cp == 0 {
                ' '
            } else {
                char::from_u32(c.cp).unwrap_or('?')
            }
        })
        .collect::<String>()
        .trim_end()
        .to_string()
}

#[test]
fn unicode_matrix_cells_widths_columns_and_cursor() {
    for case in MATRIX {
        let width = unicode_width::UnicodeWidthStr::width(case.text) as u16;
        assert_eq!(width, case.cols, "[{}] total columns", case.label);
        let mut t = Term::new(60, 2);
        t.process(case.text.as_bytes());
        let cells = snap(&t, 120);
        let expected = expected_cells(case.text);
        assert_eq!(
            expected.len(),
            case.cols as usize,
            "[{}] cell count",
            case.label
        );
        for (i, (cp, w)) in expected.iter().enumerate() {
            assert_eq!(cells[i].cp, *cp, "[{}] cell {} cp", case.label, i);
            assert_eq!(cells[i].width, *w, "[{}] cell {} width", case.label, i);
        }
        assert_eq!(
            cells[expected.len()].cp,
            0,
            "[{}] blank after text",
            case.label
        );
        assert_eq!(cells[expected.len()].width, 1);
        assert_eq!(t.cursor(), (case.cols, 0, true), "[{}] cursor", case.label);
    }
}

#[test]
fn czech_diacritics_are_single_column() {
    let mut t = Term::new(80, 1);
    t.process(CZECH.as_bytes());
    let cells = snap(&t, 80);
    for (i, ch) in CZECH.chars().enumerate() {
        assert_eq!(cells[i].cp, ch as u32);
        assert_eq!(cells[i].width, 1, "{} at {}", ch, i);
    }
    assert_eq!(t.cursor().0, 38);
}

#[test]
fn wide_char_wraps_at_row_end() {
    let mut t = Term::new(80, 3);
    t.process(format!("{}你", "a".repeat(79)).as_bytes());
    let cells = snap(&t, 240);
    assert_eq!(cells[78].cp, 'a' as u32);
    assert_eq!(
        (cells[79].cp, cells[79].width),
        (0, 1),
        "col 79 stays blank"
    );
    assert_eq!((cells[80].cp, cells[80].width), ('你' as u32, 2));
    assert_eq!(cells[81].width, 0);
    assert_eq!(t.cursor(), (2, 1, true));
}

#[test]
fn sgr_colours_and_attributes() {
    let mut t = Term::new(40, 1);
    t.process(b"\x1b[31mR\x1b[1;32mG\x1b[0m\x1b[7mI\x1b[0m\x1b[38;5;208mX\x1b[0m\x1b[38;2;255;0;128mT\x1b[0m\x1b[3;4mU\x1b[0m\x1b[48;5;21mB\x1b[0mN");
    let c = snap(&t, 40);
    assert_eq!(c[0].fg, PALETTE16[1]);
    assert_eq!(c[0].attr, 0);
    assert_eq!(c[1].fg, PALETTE16[10], "bold + green -> bright green");
    assert_ne!(c[1].attr & ATTR_BOLD, 0);
    assert_eq!(
        (c[2].fg, c[2].bg),
        (DEFAULT_BG, DEFAULT_FG),
        "inverse pre-swapped"
    );
    assert_ne!(c[2].attr & ATTR_INVERSE, 0);
    assert_eq!(c[3].fg, 0xFF8700, "256-colour cube index 208");
    assert_eq!(c[3].fg, resolve_index(208));
    assert_eq!(c[4].fg, 0xFF0080, "truecolor");
    assert_ne!(c[5].attr & ATTR_ITALIC, 0);
    assert_ne!(c[5].attr & ATTR_UNDERLINE, 0);
    assert_eq!(c[6].bg, resolve_index(21));
    assert_eq!(c[6].fg, DEFAULT_FG);
    assert_eq!(
        (c[7].fg, c[7].bg, c[7].attr),
        (DEFAULT_FG, DEFAULT_BG, 0),
        "reset"
    );
    assert_eq!(resolve_index(16), 0x000000);
    assert_eq!(resolve_index(231), 0xFFFFFF);
    assert_eq!(resolve_index(244), 0x808080);
}

#[test]
fn alternate_screen_enter_and_exit_restores() {
    let mut t = Term::new(20, 3);
    t.process(b"main line\r\nsecond");
    let before = snap(&t, 60);
    t.process(b"\x1b[?1049h\x1b[2J\x1b[HALT SCREEN");
    let alt = snap(&t, 60);
    assert_eq!(row_text(&alt, 20, 0), "ALT SCREEN");
    assert_eq!(row_text(&alt, 20, 1), "");
    t.process(b"\x1b[?1049l");
    let after = snap(&t, 60);
    assert_eq!(row_text(&after, 20, 0), "main line");
    assert_eq!(row_text(&after, 20, 1), "second");
    assert_eq!(after, before, "screen restored exactly");
}

#[test]
fn scrollback_offset_and_len() {
    let mut t = Term::new(20, 3);
    for i in 0..10 {
        t.process(format!("line{}\r\n", i).as_bytes());
    }
    assert_eq!(t.scroll_offset(), 0);
    let len = t.scrollback_len();
    assert!(len >= 7, "scrollback len {}", len);
    let live = snap(&t, 60);
    assert_eq!(row_text(&live, 20, 0), "line8");
    t.set_scroll(2);
    assert_eq!(t.scroll_offset(), 2);
    let back = snap(&t, 60);
    assert_eq!(row_text(&back, 20, 0), "line6");
    t.set_scroll(10_000);
    assert_eq!(t.scroll_offset(), len, "clamped to the scrollback length");
    t.set_scroll(-5);
    assert_eq!(t.scroll_offset(), 0);
    assert_eq!(snap(&t, 60), live);
}

#[test]
fn resize_changes_size_and_keeps_contents() {
    let mut t = Term::new(80, 24);
    t.process(b"hello");
    t.resize(120, 40);
    assert_eq!(t.size(), (120, 40));
    let cells = snap(&t, 120 * 40);
    assert_eq!(row_text(&cells, 120, 0), "hello");
    t.resize(0, 0);
    assert_eq!(t.size(), (1, 1), "never zero-sized");
    let mut one = [CboCell::default(); 4];
    assert_eq!(t.snapshot(&mut one), 1);
}

#[test]
fn snapshot_respects_capacity() {
    let mut t = Term::new(10, 2);
    t.process(b"abc");
    let mut small = [CboCell::default(); 5];
    assert_eq!(t.snapshot(&mut small), 5);
    assert_eq!(small[0].cp, 'a' as u32);
}

#[test]
fn bell_counted_and_drained() {
    let mut t = Term::new(10, 1);
    t.process(b"\x07x\x07\x07");
    assert_eq!(t.take_bell(), 3);
    assert_eq!(t.take_bell(), 0);
    t.process(b"\x07");
    assert_eq!(t.take_bell(), 1);
}

#[test]
fn osc_title() {
    let mut t = Term::new(10, 1);
    assert_eq!(t.title(), "");
    t.process(b"\x1b]0;hello \xe4\xbd\xa0\x07");
    assert_eq!(t.title(), "hello 你");
    t.process(b"\x1b]2;vim\x1b\\");
    assert_eq!(t.title(), "vim");
}

#[test]
fn generation_bumps_on_every_change() {
    let mut t = Term::new(10, 2);
    assert_eq!(t.generation(), 0);
    t.process(b"a");
    assert_eq!(t.generation(), 1);
    t.process(b"");
    assert_eq!(t.generation(), 1, "empty batch does not bump");
    t.process(b"b\r\nc\r\nd");
    assert_eq!(t.generation(), 2);
    t.resize(20, 4);
    assert_eq!(t.generation(), 3);
    t.set_scroll(1);
    assert_eq!(t.generation(), 4);
    t.set_scroll(1);
    assert_eq!(t.generation(), 4, "no-op scroll does not bump");
    let _ = t.take_bell();
    let _ = t.scrollback_len();
    assert_eq!(t.generation(), 4, "reads do not bump");
}

#[test]
fn cursor_visibility_and_position() {
    let mut t = Term::new(20, 5);
    t.process(b"ab\r\ncd");
    assert_eq!(t.cursor(), (2, 1, true));
    t.process(b"\x1b[?25l");
    assert!(!t.cursor().2, "cursor hidden after ?25l");
    t.process(b"\x1b[?25h\x1b[3;5H");
    assert_eq!(t.cursor(), (4, 2, true));
}
