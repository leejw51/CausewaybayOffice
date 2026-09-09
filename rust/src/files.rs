//! Asynchronous file browsing and SFTP on a separate transport, so large
//! transfers never stall the interactive PTY. One bounded job per session.
use crate::session::{self, lock, Session, ST_CONNECTED};
use serde::Deserialize;
use serde_json::{json, Value};
use ssh2::{OpenFlags, OpenType};
use std::collections::HashMap;
use std::fs::{self, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Request {
    op: String,
    #[serde(default)]
    local: String,
    #[serde(default)]
    remote: String,
}
struct Job {
    owner: Arc<Session>,
    cancel: AtomicBool,
    state: Mutex<Value>,
}
static JOBS: OnceLock<Mutex<HashMap<i32, Arc<Job>>>> = OnceLock::new();
fn jobs() -> &'static Mutex<HashMap<i32, Arc<Job>>> {
    JOBS.get_or_init(Default::default)
}
pub fn start(id: i32, request: &str) -> Result<(), String> {
    let req: Request = serde_json::from_str(request).map_err(|e| e.to_string())?;
    if !["pick", "local", "list", "upload", "download"].contains(&req.op.as_str()) {
        return Err("Unknown file operation".into());
    }
    if req.local.contains('\0') || req.remote.contains('\0') {
        return Err("Invalid path".into());
    }
    let sess = session::get(id).ok_or("Session no longer exists")?;
    if !["local", "pick"].contains(&req.op.as_str()) && sess.state() != ST_CONNECTED {
        return Err("Connect the terminal first".into());
    }
    let mut all = lock(jobs());
    all.retain(|id, job| {
        let keep = session::get(*id).is_some_and(|s| Arc::ptr_eq(&s, &job.owner));
        if !keep {
            job.cancel.store(true, Ordering::Relaxed);
        }
        keep
    });
    if all
        .get(&id)
        .is_some_and(|j| lock(&j.state)["state"] == "running")
    {
        return Err("A file operation is already running".into());
    }
    let job = Arc::new(Job {
        owner: sess,
        cancel: AtomicBool::new(false),
        state: Mutex::new(json!({"state":"running", "op":req.op, "done":0, "total":0})),
    });
    all.insert(id, job.clone());
    let worker = job.clone();
    if let Err(e) = std::thread::Builder::new()
        .name(format!("cbo-files-{id}"))
        .spawn(move || {
            let result =
                std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| run(&worker, &req)));
            let result = result.unwrap_or_else(|_| Err("File worker failed".into()));
            let mut state = lock(&worker.state);
            match result {
                Ok(value) => {
                    state["state"] = json!("done");
                    state["result"] = value;
                }
                Err(err) => {
                    state["state"] = json!(if worker.cancel.load(Ordering::Relaxed) {
                        "cancelled"
                    } else {
                        "error"
                    });
                    state["error"] = json!(err);
                }
            }
        })
    {
        lock(&job.state)["state"] = json!("error");
        return Err(e.to_string());
    }
    Ok(())
}
pub fn status(id: i32) -> String {
    let all = lock(jobs());
    all.get(&id)
        .filter(|j| session::get(id).is_some_and(|s| Arc::ptr_eq(&s, &j.owner)))
        .map(|j| lock(&j.state).to_string())
        .unwrap_or_else(|| "{}".into())
}
pub fn cancel(id: i32) {
    if let Some(j) = lock(jobs()).get(&id) {
        j.cancel.store(true, Ordering::Relaxed);
    }
}
fn check(job: &Job) -> Result<(), String> {
    if job.cancel.load(Ordering::Relaxed) || job.owner.close_requested.load(Ordering::Relaxed) {
        Err("Cancelled".into())
    } else {
        Ok(())
    }
}
fn local_path(path: &str) -> PathBuf {
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."));
    if path.is_empty() || path == "~" {
        home
    } else if let Some(rest) = path.strip_prefix("~/") {
        home.join(rest)
    } else {
        PathBuf::from(path)
    }
}
fn sorted(mut rows: Vec<Value>) -> Value {
    rows.sort_by(|a, b| {
        b["dir"]
            .as_bool()
            .cmp(&a["dir"].as_bool())
            .then_with(|| a["name"].as_str().cmp(&b["name"].as_str()))
    });
    json!(rows)
}
fn remote_path(sftp: &ssh2::Sftp, path: &str) -> Result<PathBuf, String> {
    if path.is_empty() || path == "~" || path.starts_with("~/") {
        let home = sftp.realpath(Path::new(".")).map_err(|e| e.to_string())?;
        Ok(if let Some(rest) = path.strip_prefix("~/") {
            home.join(rest)
        } else {
            home
        })
    } else {
        Ok(PathBuf::from(path))
    }
}
fn run(job: &Job, req: &Request) -> Result<Value, String> {
    check(job)?;
    if req.op == "pick" {
        #[cfg(target_os = "macos")]
        {
            let out = std::process::Command::new("/usr/bin/osascript")
                .args([
                    "-e",
                    "POSIX path of (choose file with prompt \"Upload to terminal folder\")",
                ])
                .output()
                .map_err(|e| e.to_string())?;
            if !out.status.success() {
                return Err("File selection cancelled".into());
            }
            let path = String::from_utf8(out.stdout).map_err(|e| e.to_string())?;
            return Ok(json!({"path":path.strip_suffix('\n').unwrap_or(&path)}));
        }
        #[cfg(not(target_os = "macos"))]
        return Err("Drop a local file onto the terminal to upload".into());
    }
    if req.op == "local" {
        let path = fs::canonicalize(local_path(&req.local)).map_err(|e| e.to_string())?;
        let mut rows = Vec::new();
        for entry in fs::read_dir(&path).map_err(|e| e.to_string())? {
            check(job)?;
            let e = entry.map_err(|e| e.to_string())?;
            let m = e.metadata().map_err(|e| e.to_string())?;
            if let Some(name) = e.file_name().to_str() {
                rows.push(
                    json!({"name":name, "dir":m.is_dir(), "file":m.is_file(), "size":m.len()}),
                );
            }
            if rows.len() >= 10000 {
                return Err("Folder has more than 10,000 entries; open a smaller folder".into());
            }
        }
        return Ok(json!({"path":path, "entries":sorted(rows)}));
    }
    let p = &job.owner.params;
    let tcp = crate::ssh::tcp_connect(&p.host, p.port)?;
    check(job)?;
    let mut ssh = ssh2::Session::new().map_err(|e| e.to_string())?;
    ssh.set_tcp_stream(tcp);
    ssh.set_timeout(15000);
    ssh.handshake().map_err(|e| e.to_string())?;
    crate::ssh::check_host_key(&ssh, &p.host, p.port)?;
    crate::ssh::authenticate(&ssh, &job.owner)?;
    check(job)?;
    let sftp = ssh.sftp().map_err(|e| format!("SFTP unavailable: {e}"))?;
    let remote = remote_path(&sftp, &req.remote)?;
    if req.op == "list" {
        let path = sftp.realpath(&remote).map_err(|e| e.to_string())?;
        let mut rows = Vec::new();
        let mut dir = sftp.opendir(&path).map_err(|e| e.to_string())?;
        loop {
            check(job)?;
            let (name, m) = match dir.readdir() {
                Ok(row) => row,
                Err(e)
                    if matches!(
                        e.code(),
                        ssh2::ErrorCode::SFTP(1) | ssh2::ErrorCode::Session(-16)
                    ) =>
                {
                    break
                }
                Err(e) => return Err(e.to_string()),
            };
            if let Some(name) = name.file_name().and_then(|s| s.to_str()) {
                if name != "." && name != ".." {
                    let m = if m.file_type().is_symlink() {
                        sftp.stat(&path.join(name)).unwrap_or(m)
                    } else {
                        m
                    };
                    rows.push(json!({"name":name, "dir":m.is_dir(), "file":m.is_file(), "size":m.size.unwrap_or(0)}));
                }
            }
            if rows.len() >= 10000 {
                return Err("Folder has more than 10,000 entries; open a smaller folder".into());
            }
        }
        return Ok(json!({"path":path, "entries":sorted(rows)}));
    }
    let local = local_path(&req.local);
    check(job)?;
    // Exclusive creation never overwrites an existing file or symlink. Remove
    // our incomplete destination on failure/cancel; source is always read-only.
    if req.op == "upload" {
        let mut src = fs::File::open(&local).map_err(|e| e.to_string())?;
        let meta = src.metadata().map_err(|e| e.to_string())?;
        if !meta.is_file() {
            return Err("Select a regular file; folders are not transferred".into());
        }
        let mut dst = sftp
            .open_mode(
                &remote,
                OpenFlags::WRITE | OpenFlags::CREATE | OpenFlags::EXCLUSIVE,
                0o600,
                OpenType::File,
            )
            .map_err(|e| format!("Cannot create remote file (existing files are kept): {e}"))?;
        let result = copy(job, &mut src, &mut dst, meta.len())
            .and_then(|_| dst.close().map_err(|e| e.to_string()));
        drop(dst);
        if result.is_err() {
            let _ = sftp.unlink(&remote);
        }
        result?;
    } else {
        let mut src = sftp.open(&remote).map_err(|e| e.to_string())?;
        let meta = src.stat().map_err(|e| e.to_string())?;
        if !meta.is_file() {
            return Err("Select a regular file; folders are not transferred".into());
        }
        let mut opts = OpenOptions::new();
        opts.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            opts.mode(0o600);
        }
        let mut dst = opts
            .open(&local)
            .map_err(|e| format!("Cannot create local file (existing files are kept): {e}"))?;
        let result = copy(job, &mut src, &mut dst, meta.size.unwrap_or(0))
            .and_then(|_| dst.sync_all().map_err(|e| e.to_string()));
        drop(dst);
        if result.is_err() {
            let _ = fs::remove_file(&local);
        }
        result?;
    }
    Ok(json!({"local":local, "remote":remote}))
}
fn copy(job: &Job, src: &mut impl Read, dst: &mut impl Write, total: u64) -> Result<(), String> {
    lock(&job.state)["total"] = json!(total);
    let mut buf = [0; 65536];
    let mut done = 0u64;
    loop {
        check(job)?;
        let n = src.read(&mut buf).map_err(|e| e.to_string())?;
        if n == 0 {
            break;
        }
        dst.write_all(&buf[..n]).map_err(|e| e.to_string())?;
        done += n as u64;
        lock(&job.state)["done"] = json!(done);
    }
    check(job)?;
    dst.flush().map_err(|e| e.to_string())?;
    if done != total {
        return Err("Source size changed during transfer; retry".into());
    }
    Ok(())
}
