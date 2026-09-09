//! Integration smoke test against the local sshd through the C ABI.
//! `cargo run --release --example smoke`

use std::ffi::{CStr, CString};
use std::time::{Duration, Instant};

use cbo_core::*;

fn c(s: &str) -> CString {
    CString::new(s).unwrap_or_default()
}

fn screen_text(id: i32, cols: usize, rows: usize) -> (String, Vec<CboCell>) {
    let mut cells = vec![CboCell::default(); cols * rows];
    let n = unsafe { cbo_term_snapshot(id, cells.as_mut_ptr(), cells.len() as i32) } as usize;
    assert_eq!(n, cols * rows, "snapshot returned {} cells", n);
    let mut text = String::new();
    for r in 0..rows {
        let mut line = String::new();
        for cl in &cells[r * cols..(r + 1) * cols] {
            match (cl.width, cl.cp) {
                (0, _) => {}
                (_, 0) => line.push(' '),
                (_, cp) => line.push(char::from_u32(cp).unwrap_or('?')),
            }
        }
        text.push_str(line.trim_end());
        text.push('\n');
    }
    (text, cells)
}

fn wait_state(id: i32, want: i32, timeout: Duration) -> bool {
    let start = Instant::now();
    while start.elapsed() < timeout {
        let st = cbo_session_state(id);
        if st == want {
            return true;
        }
        if st == 4 {
            let e = unsafe { CStr::from_ptr(cbo_session_error(id)) }.to_string_lossy();
            eprintln!("session error: {}", e);
            return false;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    false
}

fn main() {
    cbo_init();
    let version = unsafe { CStr::from_ptr(cbo_version()) }.to_string_lossy();
    println!("cbo_core {}", version);

    let user = std::env::var("USER").unwrap_or_else(|_| "root".into());
    let (cols, rows) = (80u16, 24u16);
    let host = c("localhost");
    let cuser = c(&user);
    let id = unsafe {
        cbo_session_open(
            host.as_ptr(),
            22,
            cuser.as_ptr(),
            std::ptr::null(),
            std::ptr::null(),
            cols,
            rows,
        )
    };
    assert!(id >= 0, "open failed: {}", unsafe {
        CStr::from_ptr(cbo_last_error()).to_string_lossy()
    });
    let name = unsafe { CStr::from_ptr(cbo_session_get_name(id)) }
        .to_string_lossy()
        .to_string();
    println!("session {} name={} user={}", id, name, user);

    assert!(
        wait_state(id, 2, Duration::from_secs(15)),
        "did not reach CONNECTED"
    );
    println!("CONNECTED");

    // Let the shell print its prompt, then send the command.
    std::thread::sleep(Duration::from_millis(400));
    let cmd = "echo CBO_OK 你好 안녕\n";
    unsafe { cbo_session_write(id, cmd.as_ptr(), cmd.len() as u32) };

    let start = Instant::now();
    let mut text = String::new();
    let mut cells = Vec::new();
    let mut gen_seen = 0u64;
    while start.elapsed() < Duration::from_secs(3) {
        let g = cbo_term_generation(id);
        if g != gen_seen {
            gen_seen = g;
            let (t, cl) = screen_text(id, cols as usize, rows as usize);
            text = t;
            cells = cl;
            // Prompt echo also contains the command; wait for the output line.
            if text.matches("CBO_OK").count() >= 2 {
                break;
            }
        }
        std::thread::sleep(Duration::from_millis(30));
    }

    println!(
        "---- screen ({}x{}, generation {}) ----",
        cols, rows, gen_seen
    );
    for line in text.lines().filter(|l| !l.is_empty()) {
        println!("| {}", line);
    }
    println!("----");

    assert!(text.contains("CBO_OK"), "CBO_OK not found on screen");
    assert!(text.contains("你好"), "CJK not found on screen");
    assert!(text.contains("안녕"), "Hangul not found on screen");

    // Verify widths on the output line: find a cell with 你 and check it is
    // wide with a zero-width continuation, then 好.
    let mut found = false;
    for (i, cl) in cells.iter().enumerate() {
        if cl.cp == '你' as u32 {
            assert_eq!(cl.width, 2, "你 should be width 2");
            assert_eq!(cells[i + 1].width, 0, "continuation should be width 0");
            assert_eq!(cells[i + 2].cp, '好' as u32);
            assert_eq!(cells[i + 2].width, 2);
            assert_eq!(cells[i + 3].width, 0);
            found = true;
            break;
        }
    }
    assert!(found, "wide-cell check did not find 你");
    println!("widths OK (你=2, continuation=0, 好=2)");

    let mut info = unsafe { std::mem::zeroed::<CboSessionInfo>() };
    assert_eq!(unsafe { cbo_session_info(id, &mut info) }, 0);
    let host_s = unsafe { CStr::from_ptr(info.host.as_ptr() as *const _) }.to_string_lossy();
    println!(
        "info: id={} state={} {}x{} port={} host={} gen={} last_activity={} last_ping={}",
        info.id,
        info.state,
        info.cols,
        info.rows,
        info.port,
        host_s,
        info.generation,
        info.last_activity_ms,
        info.last_ping_ms
    );

    let (mut cx, mut cy, mut vis) = (0u16, 0u16, 0u8);
    unsafe { cbo_term_cursor(id, &mut cx, &mut cy, &mut vis) };
    println!("cursor: x={} y={} visible={}", cx, cy, vis);
    println!(
        "utf8_width(\"你好 안녕 こんにちは Příliš\") = {}",
        unsafe { cbo_utf8_width(c("你好 안녕 こんにちは Příliš").as_ptr()) }
    );

    // Keepalive: drop the interval to 1s and confirm a ping gets recorded.
    cbo_session_set_keepalive(id, 1);
    let t0 = Instant::now();
    let mut pinged = false;
    while t0.elapsed() < Duration::from_secs(4) {
        assert_eq!(unsafe { cbo_session_info(id, &mut info) }, 0);
        if info.last_ping_ms > 0 {
            pinged = true;
            break;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    assert!(pinged, "keepalive never sent");
    println!(
        "keepalive OK (last_ping_ms={} after {:.1}s)",
        info.last_ping_ms,
        t0.elapsed().as_secs_f32()
    );

    let exit = "exit\n";
    unsafe { cbo_session_write(id, exit.as_ptr(), exit.len() as u32) };
    assert!(
        wait_state(id, 3, Duration::from_secs(10)),
        "did not reach CLOSED after exit"
    );
    println!("CLOSED");
    cbo_session_free(id);
    assert_eq!(cbo_session_count(), 0);
    println!("SMOKE PASS");
}
