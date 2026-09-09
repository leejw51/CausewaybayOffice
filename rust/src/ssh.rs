//! SSH transport: one std thread per session driving libssh2 (via `ssh2`).
//! Connect -> handshake -> host key (TOFU) -> auth -> pty + shell -> pump loop.

use std::io::{ErrorKind, Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::os::fd::{AsRawFd, RawFd};
use std::path::PathBuf;
use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::{Duration, Instant};

use ssh2::{CheckResult, KnownHostFileKind};

use crate::session::{lock, now_ms, Session, ST_CLOSED, ST_CONNECTED};

const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const HANDSHAKE_TIMEOUT_MS: u32 = 20_000;
/// Longest we sit in poll() while idle: bounds the latency of queued
/// keystrokes, resizes and close requests.
const IDLE_POLL: Duration = Duration::from_millis(5);
const READ_CHUNK: usize = 32 * 1024;
/// Upper bound on bytes fed to the terminal parser per pump iteration.
const MAX_BATCH: usize = 256 * 1024;
const LIBSSH2_ERROR_EAGAIN: i32 = -37;

pub fn spawn(sess: Arc<Session>, epoch: u32) {
    let name = format!("cbo-ssh-{}", sess.id);
    let builder = std::thread::Builder::new().name(name);
    let worker = Arc::clone(&sess);
    let spawned = builder.spawn(move || {
        let sess = worker;
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| run(&sess, epoch)));
        // A stale worker (reconnect / free happened meanwhile) must not touch state.
        if sess.epoch.load(Ordering::SeqCst) != epoch {
            return;
        }
        match result {
            Ok(Ok(())) => sess.set_state(ST_CLOSED),
            Ok(Err(msg)) => sess.set_error(msg),
            Err(_) => sess.set_error("internal error: ssh worker panicked"),
        }
    });
    if let Err(e) = spawned {
        sess.set_error(format!("cannot spawn ssh thread: {}", e));
    }
}

fn stale(sess: &Session, epoch: u32) -> bool {
    sess.epoch.load(Ordering::SeqCst) != epoch
}

/// Trusted host keys live in the data dir; the pre-0.2 location under
/// ~/.config/cbo is still read (not written) for one release.
fn known_hosts_path() -> PathBuf {
    crate::db::data_dir().join("known_hosts")
}

fn legacy_known_hosts_path() -> PathBuf {
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."));
    home.join(".config").join("cbo").join("known_hosts")
}

fn check_host_key(session: &ssh2::Session, host: &str, port: u16) -> Result<(), String> {
    let (key, key_type) = session.host_key().ok_or("server sent no host key")?;
    let path = known_hosts_path();
    // Serialize read/check/write across threads AND app processes. A lost
    // update could otherwise forget a trusted key and accept a changed one.
    let dir = path.parent().ok_or("known_hosts has no parent")?;
    std::fs::create_dir_all(dir).map_err(|e| format!("known_hosts directory: {}", e))?;
    let mut options = std::fs::OpenOptions::new();
    options.read(true).write(true).create(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let host_lock = options
        .open(dir.join("known_hosts.lock"))
        .map_err(|e| format!("known_hosts lock: {}", e))?;
    host_lock
        .lock()
        .map_err(|e| format!("known_hosts lock: {}", e))?;
    let mut kh = session
        .known_hosts()
        .map_err(|e| format!("known_hosts init: {}", e))?;
    if path.exists() {
        kh.read_file(&path, KnownHostFileKind::OpenSSH)
            .map_err(|e| format!("cannot read {}: {}", path.display(), e))?;
    }
    let legacy = legacy_known_hosts_path();
    if legacy.exists() {
        // Best effort: a malformed legacy file must not block connecting.
        let _ = kh.read_file(&legacy, KnownHostFileKind::OpenSSH);
    }
    match kh.check_port(host, port, key) {
        CheckResult::Match => Ok(()),
        CheckResult::NotFound => {
            // Trust on first use.
            let entry = if port == 22 { host.to_string() } else { format!("[{}]:{}", host, port) };
            kh.add(&entry, key, "added by cbo", key_type.into())
                .map_err(|e| format!("known_hosts add: {}", e))?;
            if let Some(dir) = path.parent() {
                let _ = std::fs::create_dir_all(dir);
            }
            let temp = path.with_extension("tmp");
            kh.write_file(&temp, KnownHostFileKind::OpenSSH)
                .map_err(|e| format!("cannot write {}: {}", temp.display(), e))?;
            std::fs::rename(&temp, &path)
                .map_err(|e| format!("save known_hosts: {}", e))?;
            Ok(())
        }
        CheckResult::Mismatch => Err(format!(
            "HOST KEY MISMATCH for {}:{} — the server's key changed. If you trust it, remove the entry from {}",
            host,
            port,
            path.display()
        )),
        CheckResult::Failure => Err("host key check failed".into()),
    }
}

fn authenticate(session: &ssh2::Session, sess: &Session) -> Result<(), String> {
    let p = &sess.params;
    let mut tried: Vec<String> = Vec::new();

    if let Some(kp) = &p.keypath {
        let key = PathBuf::from(expand_tilde(kp));
        let pubkey = key.with_extension(match key.extension() {
            Some(ext) => format!("{}.pub", ext.to_string_lossy()),
            None => "pub".to_string(),
        });
        let pubkey = pubkey.exists().then_some(pubkey);
        match session.userauth_pubkey_file(&p.user, pubkey.as_deref(), &key, p.password.as_deref())
        {
            Ok(()) => return Ok(()),
            Err(e) => tried.push(format!("key {}: {}", key.display(), e.message())),
        }
    } else {
        match session.userauth_agent(&p.user) {
            Ok(()) => return Ok(()),
            Err(e) => tried.push(format!("agent: {}", e.message())),
        }
        let home = std::env::var_os("HOME")
            .map(PathBuf::from)
            .unwrap_or_default();
        for name in ["id_ed25519", "id_rsa", "id_ecdsa"] {
            let key = home.join(".ssh").join(name);
            if !key.exists() {
                continue;
            }
            let pubkey = home.join(".ssh").join(format!("{}.pub", name));
            let pubkey = pubkey.exists().then_some(pubkey);
            match session.userauth_pubkey_file(&p.user, pubkey.as_deref(), &key, None) {
                Ok(()) => return Ok(()),
                Err(e) => tried.push(format!("{}: {}", name, e.message())),
            }
            if session.authenticated() {
                return Ok(());
            }
        }
    }

    if let Some(pw) = &p.password {
        match session.userauth_password(&p.user, pw) {
            Ok(()) => return Ok(()),
            Err(e) => tried.push(format!("password: {}", e.message())),
        }
    }

    if session.authenticated() {
        return Ok(());
    }
    Err(format!(
        "authentication failed for {} ({})",
        p.user,
        tried.join("; ")
    ))
}

fn expand_tilde(p: &str) -> String {
    if let Some(rest) = p.strip_prefix("~/") {
        if let Some(home) = std::env::var_os("HOME") {
            return format!("{}/{}", home.to_string_lossy(), rest);
        }
    }
    p.to_string()
}

fn tcp_connect(host: &str, port: u16) -> Result<TcpStream, String> {
    let addrs: Vec<_> = (host, port)
        .to_socket_addrs()
        .map_err(|e| format!("cannot resolve {}: {}", host, e))?
        .collect();
    if addrs.is_empty() {
        return Err(format!("cannot resolve {}", host));
    }
    let mut last = String::new();
    for addr in addrs {
        match TcpStream::connect_timeout(&addr, CONNECT_TIMEOUT) {
            Ok(s) => {
                let _ = s.set_nodelay(true);
                return Ok(s);
            }
            Err(e) => last = format!("{}: {}", addr, e),
        }
    }
    Err(format!("connect to {}:{} failed ({})", host, port, last))
}

fn run(sess: &Arc<Session>, epoch: u32) -> Result<(), String> {
    let p = sess.params.clone();

    let tcp = tcp_connect(&p.host, p.port)?;
    if stale(sess, epoch) {
        return Ok(());
    }

    let fd = tcp.as_raw_fd();
    let mut session = ssh2::Session::new().map_err(|e| format!("libssh2 init: {}", e))?;
    session.set_tcp_stream(tcp);
    session.set_timeout(HANDSHAKE_TIMEOUT_MS);
    session.set_compress(false);
    session
        .handshake()
        .map_err(|e| format!("ssh handshake: {}", e.message()))?;

    if stale(sess, epoch) {
        return Ok(());
    }
    check_host_key(&session, &p.host, p.port)?;
    if stale(sess, epoch) {
        return Ok(());
    }
    authenticate(&session, sess)?;
    if stale(sess, epoch) {
        return Ok(());
    }

    let mut channel = session
        .channel_session()
        .map_err(|e| format!("channel: {}", e.message()))?;
    // Servers commonly refuse env vars other than LANG/LC_*; ignore failures.
    let _ = channel.setenv("TERM", "xterm-256color");
    if let Ok(lang) = std::env::var("LANG") {
        let _ = channel.setenv("LANG", &lang);
    }
    let (cols, rows) = (
        sess.cols.load(Ordering::Relaxed),
        sess.rows.load(Ordering::Relaxed),
    );
    // Pixel dimensions let image clients (kitten icat, chafa, timg) size
    // pictures to the cell grid through TIOCGWINSZ.
    let (cw, ch) = sess.term().cell_px();
    channel
        .request_pty(
            "xterm-256color",
            None,
            Some((
                cols as u32,
                rows as u32,
                cols as u32 * cw as u32,
                rows as u32 * ch as u32,
            )),
        )
        .map_err(|e| format!("request pty: {}", e.message()))?;
    channel
        .shell()
        .map_err(|e| format!("shell: {}", e.message()))?;

    if stale(sess, epoch) || sess.close_requested.load(Ordering::SeqCst) {
        return Ok(());
    }
    sess.set_state(ST_CONNECTED);
    sess.touch();

    session.set_blocking(false);
    session.set_timeout(0);

    let mut keepalive_secs = sess.keepalive_secs.load(Ordering::Relaxed);
    session.set_keepalive(true, keepalive_secs);
    let mut next_keepalive = Instant::now() + Duration::from_secs(keepalive_secs.max(1) as u64);

    let mut buf = vec![0u8; READ_CHUNK];
    let mut inbuf: Vec<u8> = Vec::with_capacity(MAX_BATCH);
    let mut pending_out: Vec<u8> = Vec::new();
    let mut stderr = channel.stderr();

    loop {
        if stale(sess, epoch) {
            return Ok(());
        }
        if sess.close_requested.load(Ordering::SeqCst) {
            graceful_close(&session, &mut channel);
            return Ok(());
        }

        // --- inbound: drain up to MAX_BATCH, then feed the parser once so
        // the term lock is held briefly and nothing is ever dropped. ---
        inbuf.clear();
        let mut remote_closed = false;
        while inbuf.len() < MAX_BATCH {
            match channel.read(&mut buf) {
                Ok(0) => {
                    remote_closed = channel.eof();
                    break;
                }
                Ok(n) => inbuf.extend_from_slice(&buf[..n]),
                Err(e) if is_eagain(&e) => break,
                Err(e) => {
                    if channel.eof() || sess.close_requested.load(Ordering::SeqCst) {
                        remote_closed = true;
                        break;
                    }
                    let detail = ssh2::Error::last_session_error(&session)
                        .map(|l| format!(" ({:?})", l.code()))
                        .unwrap_or_default();
                    return Err(format!("connection lost: {}{}", e, detail));
                }
            }
        }
        if inbuf.len() < MAX_BATCH {
            // A pty merges stderr into stdout; this only catches the rare
            // extended-data packet so it cannot pile up unread.
            if let Ok(n) = stderr.read(&mut buf) {
                if n > 0 {
                    inbuf.extend_from_slice(&buf[..n]);
                }
            }
        }
        let busy = !inbuf.is_empty();
        if busy {
            let replies = {
                let mut term = sess.term();
                term.process(&inbuf);
                term.take_responses()
            };
            sess.touch();
            crate::record::on_output(sess, &inbuf);
            // Graphics protocol / size query answers go straight back, not
            // through `Session::write` (they are not the user's input).
            if !replies.is_empty() {
                lock(&sess.outgoing).extend_from_slice(&replies);
            }
        }
        if remote_closed || channel.eof() {
            graceful_close(&session, &mut channel);
            return Ok(());
        }

        // --- resize (also re-sent when the cell pixel size changes) ---
        let resize = lock(&sess.resize_request).take();
        let cell_changed = sess.term().take_pixel_size_changed();
        if resize.is_some() || cell_changed {
            let (c, r) = resize.unwrap_or((
                sess.cols.load(Ordering::Relaxed),
                sess.rows.load(Ordering::Relaxed),
            ));
            let (cw, ch) = sess.term().cell_px();
            let _ = channel.request_pty_size(
                c as u32,
                r as u32,
                Some(c as u32 * cw as u32),
                Some(r as u32 * ch as u32),
            );
        }

        // --- outbound (libssh2 sends unbuffered; never "flush" a channel:
        // libssh2_channel_flush discards unread *incoming* data). ---
        {
            let mut q = lock(&sess.outgoing);
            if !q.is_empty() {
                pending_out.append(&mut q);
            }
        }
        let mut wrote = false;
        while !pending_out.is_empty() {
            match channel.write(&pending_out) {
                Ok(0) => break,
                Ok(n) => {
                    pending_out.drain(..n);
                    wrote = true;
                }
                Err(e) if is_eagain(&e) => break,
                Err(e) => {
                    if sess.close_requested.load(Ordering::SeqCst) {
                        break;
                    }
                    return Err(format!("write failed: {}", e));
                }
            }
        }

        // --- keepalive ---
        let wanted = sess.keepalive_secs.load(Ordering::Relaxed);
        if wanted != keepalive_secs {
            keepalive_secs = wanted;
            session.set_keepalive(true, keepalive_secs);
            next_keepalive = Instant::now() + Duration::from_secs(keepalive_secs.max(1) as u64);
        }
        if keepalive_secs > 0 && Instant::now() >= next_keepalive {
            match session.keepalive_send() {
                Ok(secs) => {
                    sess.last_ping_ms.store(now_ms(), Ordering::Relaxed);
                    let secs = if secs == 0 {
                        keepalive_secs
                    } else {
                        secs.min(keepalive_secs)
                    };
                    next_keepalive = Instant::now() + Duration::from_secs(secs.max(1) as u64);
                }
                Err(e) if e.code() == ssh2::ErrorCode::Session(LIBSSH2_ERROR_EAGAIN) => {
                    // Mid-burst: the socket is busy, retry shortly.
                    next_keepalive = Instant::now() + Duration::from_millis(200);
                }
                Err(e) => return Err(format!("keepalive failed: {}", e.message())),
            }
        }

        if !busy && !wrote {
            wait_socket(fd, &session, !pending_out.is_empty());
        }
    }
}

/// libssh2 signals "try again" as LIBSSH2_ERROR_EAGAIN; ssh2 maps that to
/// `WouldBlock` (and EINTR is folded into it by libssh2 itself).
fn is_eagain(e: &std::io::Error) -> bool {
    matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::Interrupted)
}

/// Sleep until the socket is readable/writable in the direction libssh2 is
/// blocked on (or a short timeout so queued writes / close requests are
/// picked up promptly). Falls back to a plain sleep if poll fails.
fn wait_socket(fd: RawFd, session: &ssh2::Session, want_write: bool) {
    let mut events = match session.block_directions() {
        ssh2::BlockDirections::None | ssh2::BlockDirections::Inbound => libc::POLLIN,
        ssh2::BlockDirections::Outbound => libc::POLLOUT,
        ssh2::BlockDirections::Both => libc::POLLIN | libc::POLLOUT,
    };
    if want_write {
        events |= libc::POLLOUT;
    }
    let mut pfd = libc::pollfd {
        fd,
        events,
        revents: 0,
    };
    // SAFETY: pfd is a valid, initialised pollfd for the session's socket,
    // which outlives this call.
    let rc = unsafe { libc::poll(&mut pfd, 1, IDLE_POLL.as_millis() as i32) };
    if rc < 0 {
        std::thread::sleep(IDLE_POLL);
    }
}

fn graceful_close(session: &ssh2::Session, channel: &mut ssh2::Channel) {
    session.set_blocking(true);
    session.set_timeout(2_000);
    let _ = channel.send_eof();
    let _ = channel.close();
    let _ = channel.wait_close();
    let _ = session.disconnect(None, "bye", None);
}
