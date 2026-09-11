//! MCP server (Model Context Protocol, Streamable HTTP transport): JSON-RPC
//! 2.0 over `POST http://127.0.0.1:<port>/mcp/<token>`. Claude Code or any
//! other MCP client connects directly to the running office and can read the
//! terminal screen, search and add notes, and push text into the AI assist
//! page, so the user's coding assistant answers instead of a paid API call.
//!
//! Nothing here calls into Lua: writes to the terminal and messages for the
//! assist page land in an inbox that `love.update` drains
//! (`cbo_mcp_take`). Text sent with `office_type` is reviewed by the user
//! before anything reaches the shell. The server binds loopback only and the
//! URL carries a random token.

use std::io::{self, BufRead, BufReader, Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use serde_json::{json, Value};

use crate::session::{lock, now_ms};

pub const PROTOCOL_VERSION: &str = "2025-03-26";
pub const SERVER_NAME: &str = "causewaybay-office";
const MAX_BODY: usize = 4 * 1024 * 1024;
const MAX_INBOX: usize = 256;
const MAX_TEXT: usize = 200_000;
const MAX_HEADERS: usize = 16 * 1024;
const MAX_HEADER_COUNT: usize = 64;
const MAX_CONNECTIONS: usize = 16;
const REQUEST_TIMEOUT: Duration = Duration::from_secs(15);

struct Server {
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
    port: u16,
    token: String,
    active: Arc<AtomicUsize>,
}

#[derive(Default)]
struct State {
    server: Option<Server>,
    inbox: Vec<Value>,
    next_id: u64,
    requests: u64,
    last_request_ms: u64,
    last_client: String,
    session: i32,
}

static STATE: Mutex<State> = Mutex::new(State {
    server: None,
    inbox: Vec::new(),
    next_id: 0,
    requests: 0,
    last_request_ms: 0,
    last_client: String::new(),
    session: -1,
});

pub fn url_for(port: u16, token: &str) -> String {
    format!("http://127.0.0.1:{}/mcp/{}", port, token)
}

/// 256 bits from the operating system. Entropy failure prevents startup.
pub fn random_token() -> Result<String, String> {
    let mut bytes = [0u8; 32];
    getrandom::getrandom(&mut bytes).map_err(|_| "OS randomness unavailable".to_string())?;
    let mut out = String::with_capacity(64);
    for byte in bytes {
        out.push_str(&format!("{byte:02x}"));
    }
    Ok(out)
}

fn valid_token(token: &str) -> bool {
    token.len() == 64 && token.bytes().all(|b| b.is_ascii_hexdigit())
}

fn token_for_start(existing: &str) -> Result<String, String> {
    if valid_token(existing) {
        Ok(existing.to_string())
    } else {
        // Includes every legacy 16-character token; old client URLs expire.
        random_token()
    }
}

/// Which live session the MCP tools mean by default (the terminal on screen).
pub fn set_session(id: i32) {
    lock(&STATE).session = id;
}

/// Running state, URL and counters, as JSON.
pub fn info() -> Value {
    let st = lock(&STATE);
    let (running, url, port) = match &st.server {
        Some(s) => (true, url_for(s.port, &s.token), s.port),
        None => (false, String::new(), 0),
    };
    json!({
        "running": running,
        "url": url,
        "port": port,
        "requests": st.requests,
        "last_request_ms": st.last_request_ms,
        "last_client": st.last_client,
        "inbox": st.inbox.len(),
        "session": st.session,
        "connections": st.server.as_ref().map(|s| s.active.load(Ordering::Relaxed)).unwrap_or(0),
    })
}

/// Drain the inbox: JSON array of `{id, ts_ms, kind, text, title?}`.
pub fn take_inbox() -> String {
    let mut st = lock(&STATE);
    Value::Array(std::mem::take(&mut st.inbox)).to_string()
}

fn push_inbox(kind: &str, text: &str, title: Option<&str>) -> u64 {
    let mut st = lock(&STATE);
    st.next_id += 1;
    let id = st.next_id;
    let mut item = json!({"id": id, "ts_ms": now_ms(), "kind": kind, "text": text});
    if let Some(t) = title.filter(|t| !t.trim().is_empty()) {
        item["title"] = Value::String(t.to_string());
    }
    if st.inbox.len() >= MAX_INBOX {
        st.inbox.remove(0);
    }
    st.inbox.push(item);
    id
}

/// The tools the office offers to MCP clients.
pub fn tool_list() -> Value {
    let text_arg = |name: &str, desc: &str| json!({"type": "object", "properties": {name: {"type": "string", "description": desc}}, "required": [name]});
    json!([
        {
            "name": "office_send",
            "description": "Show a message in the CAUSEWAYBAY OFFICE AI assist page (chat bubble). Use it to hand the user an explanation, a command or a code sample without spending office API credit.",
            "inputSchema": {"type": "object", "properties": {
                "text": {"type": "string", "description": "Markdown/plain text; fenced code blocks get RUN and PRACTICE buttons"},
                "title": {"type": "string", "description": "Optional short label"}
            }, "required": ["text"]}
        },
        {
            "name": "office_practice",
            "description": "Start a coding practice in the office: the code is shown line by line and the user types it into the terminal.",
            "inputSchema": {"type": "object", "properties": {
                "code": {"type": "string", "description": "The lines to type"},
                "title": {"type": "string"}
            }, "required": ["code"]}
        },
        {
            "name": "office_type",
            "description": "Propose terminal input. The user reviews it in the office before it is sent to the shell; nothing runs on its own.",
            "inputSchema": text_arg("text", "Text for the terminal (newlines run commands after review)")
        },
        {
            "name": "office_screen",
            "description": "The visible text of the terminal on screen (or of the session given by id).",
            "inputSchema": {"type": "object", "properties": {"session": {"type": "integer"}}}
        },
        {
            "name": "office_cwd",
            "description": "The remote working directory of the terminal on screen, when the shell reports it.",
            "inputSchema": {"type": "object", "properties": {"session": {"type": "integer"}}}
        },
        {
            "name": "office_sessions",
            "description": "List the live ssh sessions: id, name, user, host, state.",
            "inputSchema": {"type": "object", "properties": {}}
        },
        {
            "name": "office_notes_search",
            "description": "Search the user's saved notes (hybrid BM25 + vector).",
            "inputSchema": {"type": "object", "properties": {
                "query": {"type": "string"},
                "limit": {"type": "integer", "description": "default 5, max 50"}
            }, "required": ["query"]}
        },
        {
            "name": "office_note_add",
            "description": "Save a note in the office (searchable later, fed to the office AI).",
            "inputSchema": text_arg("text", "Note text")
        }
    ])
}

fn arg_str<'a>(args: &'a Value, key: &str) -> Option<&'a str> {
    args.get(key).and_then(|v| v.as_str())
}

fn session_arg(args: &Value) -> Option<i32> {
    let id = args
        .get("session")
        .and_then(|v| v.as_i64())
        .map(|v| v as i32)
        .unwrap_or_else(|| lock(&STATE).session);
    if id < 0 {
        None
    } else {
        Some(id)
    }
}

fn state_name(st: i32) -> &'static str {
    match st {
        0 => "idle",
        1 => "connecting",
        2 => "connected",
        3 => "closed",
        4 => "error",
        _ => "?",
    }
}

fn clip(text: &str) -> Result<&str, String> {
    if text.len() > MAX_TEXT {
        return Err(format!("text longer than {} bytes", MAX_TEXT));
    }
    Ok(text)
}

/// Run one office tool. Ok(text) is the tool result; Err is an isError result.
pub fn call_tool(name: &str, args: &Value) -> Result<String, String> {
    match name {
        "office_send" => {
            let text = clip(arg_str(args, "text").ok_or("text is required")?)?;
            if text.trim().is_empty() {
                return Err("text is empty".into());
            }
            let id = push_inbox("send", text, arg_str(args, "title"));
            Ok(format!("delivered to the AI assist page (message {})", id))
        }
        "office_practice" => {
            let code = clip(arg_str(args, "code").ok_or("code is required")?)?;
            if code.trim().is_empty() {
                return Err("code is empty".into());
            }
            let id = push_inbox("practice", code, arg_str(args, "title"));
            Ok(format!("practice started in the office (item {})", id))
        }
        "office_type" => {
            let text = clip(arg_str(args, "text").ok_or("text is required")?)?;
            if text.trim().is_empty() {
                return Err("text is empty".into());
            }
            let id = push_inbox("type", text, None);
            Ok(format!(
                "queued for the user's review in the terminal (item {}); it runs only if they accept",
                id
            ))
        }
        "office_screen" => {
            let id = session_arg(args).ok_or("no terminal on screen; pass session")?;
            let s = crate::session::get(id).ok_or_else(|| format!("no session {}", id))?;
            let text = s.term().contents();
            let text = text.trim_end_matches(['\n', ' ']);
            Ok(if text.is_empty() {
                "(blank screen)".to_string()
            } else {
                text.to_string()
            })
        }
        "office_cwd" => {
            let id = session_arg(args).ok_or("no terminal on screen; pass session")?;
            let s = crate::session::get(id).ok_or_else(|| format!("no session {}", id))?;
            let cwd = s.term().cwd();
            Ok(if cwd.is_empty() {
                "(unknown: the shell has not reported its folder)".to_string()
            } else {
                cwd
            })
        }
        "office_sessions" => {
            let list: Vec<Value> = crate::session::live()
                .iter()
                .map(|s| {
                    json!({"id": s.id, "name": s.name(), "user": s.params.user,
                           "host": s.params.host, "port": s.params.port,
                           "state": state_name(s.state())})
                })
                .collect();
            Ok(Value::Array(list).to_string())
        }
        "office_notes_search" => {
            let query = arg_str(args, "query").ok_or("query is required")?;
            let limit = args
                .get("limit")
                .and_then(|v| v.as_u64())
                .unwrap_or(5)
                .clamp(1, 50) as usize;
            let hits = crate::search::hybrid_global(query, &["note"], limit)?;
            if hits.is_empty() {
                return Ok("no matching notes".into());
            }
            Ok(hits
                .iter()
                .map(|h| format!("[note {}] {}\n{}", h.id, h.title, h.snippet))
                .collect::<Vec<_>>()
                .join("\n\n"))
        }
        "office_note_add" => {
            let text = clip(arg_str(args, "text").ok_or("text is required")?)?;
            let session = lock(&STATE).session.max(0) as i64;
            let id = crate::db::with(|c| crate::notes::add(c, text, session))?;
            Ok(format!("saved note {}", id))
        }
        _ => Err(format!("unknown tool '{}'", name)),
    }
}

fn rpc_error(id: Value, code: i64, message: impl Into<String>) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message.into()}})
}

fn rpc_ok(id: Value, result: Value) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "result": result})
}

/// Answer one JSON-RPC message. `None` for notifications (nothing to send).
pub fn handle_rpc(msg: &Value) -> Option<Value> {
    let id = msg.get("id").cloned().unwrap_or(Value::Null);
    let method = msg.get("method").and_then(|m| m.as_str()).unwrap_or("");
    if method.is_empty() {
        return Some(rpc_error(id, -32600, "method is required"));
    }
    if method.starts_with("notifications/") {
        return None;
    }
    let params = msg.get("params").cloned().unwrap_or_else(|| json!({}));
    Some(match method {
        "initialize" => {
            let requested = params
                .get("protocolVersion")
                .and_then(|v| v.as_str())
                .unwrap_or(PROTOCOL_VERSION);
            let version = if requested == "2024-11-05" || requested == PROTOCOL_VERSION {
                requested
            } else {
                PROTOCOL_VERSION
            };
            rpc_ok(
                id,
                json!({
                    "protocolVersion": version,
                    "capabilities": {"tools": {"listChanged": false}},
                    "serverInfo": {"name": SERVER_NAME, "version": crate::VERSION},
                    "instructions": "CAUSEWAYBAY OFFICE: a retro ssh terminal with an AI assist page. office_screen reads the terminal, office_send shows your answer in the assist page, office_practice starts a typing practice, office_type proposes shell input the user reviews first.",
                }),
            )
        }
        "ping" => rpc_ok(id, json!({})),
        "tools/list" => rpc_ok(id, json!({"tools": tool_list()})),
        "tools/call" => {
            let name = params.get("name").and_then(|n| n.as_str()).unwrap_or("");
            let args = params
                .get("arguments")
                .cloned()
                .unwrap_or_else(|| json!({}));
            match call_tool(name, &args) {
                Ok(text) => rpc_ok(id, json!({"content": [{"type": "text", "text": text}]})),
                Err(e) => rpc_ok(
                    id,
                    json!({"content": [{"type": "text", "text": e}], "isError": true}),
                ),
            }
        }
        "resources/list" => rpc_ok(id, json!({"resources": []})),
        "prompts/list" => rpc_ok(id, json!({"prompts": []})),
        _ => rpc_error(id, -32601, format!("method not found: {}", method)),
    })
}

/// A request body: one message or a batch. Returns the response body (empty
/// for notification-only input).
pub fn handle_body(body: &str) -> Result<String, String> {
    let v: Value = serde_json::from_str(body).map_err(|e| format!("parse error: {}", e))?;
    match v {
        Value::Array(items) => {
            let out: Vec<Value> = items.iter().filter_map(handle_rpc).collect();
            Ok(if out.is_empty() {
                String::new()
            } else {
                Value::Array(out).to_string()
            })
        }
        other => Ok(handle_rpc(&other)
            .map(|r| r.to_string())
            .unwrap_or_default()),
    }
}

struct Request {
    method: String,
    body: String,
}

#[derive(Debug)]
struct RequestError {
    status: &'static str,
    message: &'static str,
}

fn bad(message: &'static str) -> RequestError {
    RequestError {
        status: "400 Bad Request",
        message,
    }
}

impl From<io::Error> for RequestError {
    fn from(error: io::Error) -> Self {
        if error.kind() == io::ErrorKind::TimedOut {
            Self {
                status: "408 Request Timeout",
                message: "request deadline exceeded",
            }
        } else {
            bad("incomplete request")
        }
    }
}

// A timeout on each socket read alone lets a slow client hold a worker forever.
// Every underlying read shares this absolute deadline, including the body.
struct DeadlineReader<'a> {
    stream: &'a mut TcpStream,
    deadline: Instant,
    stop: &'a AtomicBool,
}

impl DeadlineReader<'_> {
    fn check(&self) -> io::Result<Duration> {
        if self.stop.load(Ordering::SeqCst) {
            return Err(io::Error::new(
                io::ErrorKind::ConnectionAborted,
                "server stopped",
            ));
        }
        self.deadline
            .checked_duration_since(Instant::now())
            .filter(|d| !d.is_zero())
            .ok_or_else(|| io::Error::new(io::ErrorKind::TimedOut, "request deadline exceeded"))
    }
}

impl Read for DeadlineReader<'_> {
    fn read(&mut self, bytes: &mut [u8]) -> io::Result<usize> {
        loop {
            let remaining = self.check()?;
            self.stream
                .set_read_timeout(Some(remaining.min(Duration::from_millis(100))))?;
            match self.stream.read(bytes) {
                Err(e)
                    if matches!(
                        e.kind(),
                        io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
                    ) => {}
                result => return result,
            }
        }
    }
}

fn header_line(reader: &mut impl BufRead, remaining: &mut usize) -> Result<String, RequestError> {
    let mut line = Vec::new();
    let count = reader
        .take((*remaining + 1) as u64)
        .read_until(b'\n', &mut line)?;
    if count > *remaining {
        return Err(RequestError {
            status: "431 Request Header Fields Too Large",
            message: "headers too large",
        });
    }
    *remaining -= count;
    if !line.ends_with(b"\r\n") {
        return Err(bad("invalid header line"));
    }
    line.truncate(line.len() - 2);
    if line
        .iter()
        .any(|b| !b.is_ascii() || (*b < 32 && *b != b'\t') || *b == 127)
    {
        return Err(bad("invalid header characters"));
    }
    String::from_utf8(line).map_err(|_| bad("invalid headers"))
}

fn valid_authority(host: &str, port: u16) -> bool {
    host.eq_ignore_ascii_case(&format!("localhost:{port}")) || host == format!("127.0.0.1:{port}")
}

fn valid_origin(origin: &str, port: u16) -> bool {
    origin.eq_ignore_ascii_case(&format!("http://localhost:{port}"))
        || origin == format!("http://127.0.0.1:{port}")
}

fn read_request(
    stream: &mut TcpStream,
    token: &str,
    port: u16,
    stop: &AtomicBool,
    deadline: Instant,
) -> Result<Request, RequestError> {
    let mut reader = BufReader::new(DeadlineReader {
        stream,
        deadline,
        stop,
    });
    let mut remaining = MAX_HEADERS;
    let line = header_line(&mut reader, &mut remaining)?;
    let parts: Vec<_> = line.split_whitespace().collect();
    if parts.len() != 3 || parts[2] != "HTTP/1.1" {
        return Err(bad("HTTP/1.1 request required"));
    }
    let method = parts[0].to_string();
    let path = parts[1].to_string();
    let (mut host, mut origin, mut length) = (None, None, None);
    let mut header_count = 0;
    loop {
        reader.get_ref().check()?;
        let line = header_line(&mut reader, &mut remaining)?;
        if line.is_empty() {
            break;
        }
        header_count += 1;
        if header_count > MAX_HEADER_COUNT {
            return Err(RequestError {
                status: "431 Request Header Fields Too Large",
                message: "too many headers",
            });
        }
        let (name, value) = line.split_once(':').ok_or_else(|| bad("invalid header"))?;
        if name.is_empty() || !name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-') {
            return Err(bad("invalid header name"));
        }
        let value = value.trim();
        match name.to_ascii_lowercase().as_str() {
            "host" => {
                if host.replace(value.to_string()).is_some() {
                    return Err(bad("duplicate host"));
                }
            }
            "origin" => {
                if origin.replace(value.to_string()).is_some() {
                    return Err(bad("duplicate origin"));
                }
            }
            "content-length" => {
                if length.is_some()
                    || value.is_empty()
                    || !value.bytes().all(|b| b.is_ascii_digit())
                {
                    return Err(bad("invalid content length"));
                }
                length = Some(
                    value
                        .parse::<usize>()
                        .map_err(|_| bad("invalid content length"))?,
                );
            }
            "transfer-encoding" => return Err(bad("transfer encoding is unsupported")),
            _ => {}
        }
    }
    if !host.as_deref().is_some_and(|h| valid_authority(h, port))
        || origin.as_deref().is_some_and(|o| !valid_origin(o, port))
    {
        return Err(RequestError {
            status: "403 Forbidden",
            message: "host or origin not allowed",
        });
    }
    let expected = format!("/mcp/{token}");
    if path != expected && path != format!("{expected}/") {
        return Err(RequestError {
            status: "404 Not Found",
            message: "unknown path",
        });
    }
    let length = length.unwrap_or(0);
    if length > MAX_BODY {
        return Err(RequestError {
            status: "413 Payload Too Large",
            message: "body too large",
        });
    }
    // Validate authority, origin and authentication before allocating/reading a body.
    reader.get_ref().check()?;
    let mut body = vec![0u8; length];
    reader.read_exact(&mut body)?;
    reader.get_ref().check()?;
    Ok(Request {
        method,
        body: String::from_utf8(body).map_err(|_| bad("invalid UTF-8 body"))?,
    })
}

fn respond(stream: &mut TcpStream, status: &str, body: &str) {
    let head = format!(
        "HTTP/1.1 {}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n",
        status,
        body.len()
    );
    let _ = stream.write_all(head.as_bytes());
    let _ = stream.write_all(body.as_bytes());
    let _ = stream.flush();
}

fn serve(
    mut stream: TcpStream,
    token: &str,
    peer: SocketAddr,
    port: u16,
    stop: &AtomicBool,
    deadline: Instant,
) {
    let _ = stream.set_write_timeout(Some(Duration::from_secs(15)));
    let req = match read_request(&mut stream, token, port, stop, deadline) {
        Ok(r) => r,
        Err(e) => {
            respond(
                &mut stream,
                e.status,
                &json!({"error": e.message}).to_string(),
            );
            return;
        }
    };
    if stop.load(Ordering::SeqCst) {
        return;
    }
    {
        let mut st = lock(&STATE);
        st.requests += 1;
        st.last_request_ms = now_ms();
        st.last_client = peer.to_string();
    }
    match req.method.as_str() {
        "POST" => match handle_body(&req.body) {
            Ok(body) if body.is_empty() => respond(&mut stream, "202 Accepted", ""),
            Ok(body) => respond(&mut stream, "200 OK", &body),
            Err(e) => respond(
                &mut stream,
                "400 Bad Request",
                &rpc_error(Value::Null, -32700, e).to_string(),
            ),
        },
        "DELETE" => respond(&mut stream, "200 OK", "{}"),
        "GET" => respond(
            &mut stream,
            "405 Method Not Allowed",
            r#"{"error":"this server answers JSON-RPC POST requests only (no SSE stream)"}"#,
        ),
        _ => respond(
            &mut stream,
            "405 Method Not Allowed",
            r#"{"error":"POST only"}"#,
        ),
    }
}

struct ConnectionPermit(Arc<AtomicUsize>);

impl ConnectionPermit {
    fn acquire(active: &Arc<AtomicUsize>) -> Option<Self> {
        active
            .fetch_update(Ordering::AcqRel, Ordering::Relaxed, |n| {
                (n < MAX_CONNECTIONS).then_some(n + 1)
            })
            .ok()?;
        Some(Self(Arc::clone(active)))
    }
}

impl Drop for ConnectionPermit {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::AcqRel);
    }
}

/// Start (or keep) the server. `port` 0 picks a free port. Returns `info()`.
pub fn start_with_token(port: u16, token: &str) -> Result<Value, String> {
    let token = token.trim();
    if !valid_token(token) {
        return Err("token must contain 64 hexadecimal characters".into());
    }
    {
        let st = lock(&STATE);
        if st.server.is_some() {
            drop(st);
            return Ok(info());
        }
    }
    let listener = TcpListener::bind(("127.0.0.1", port))
        .map_err(|e| format!("bind 127.0.0.1:{}: {}", port, e))?;
    listener
        .set_nonblocking(true)
        .map_err(|e| format!("listener: {}", e))?;
    let actual = listener
        .local_addr()
        .map_err(|e| format!("listener: {}", e))?
        .port();
    let stop = Arc::new(AtomicBool::new(false));
    let flag = Arc::clone(&stop);
    let active = Arc::new(AtomicUsize::new(0));
    let connections = Arc::clone(&active);
    let tok = token.to_string();
    let thread = std::thread::Builder::new()
        .name("cbo-mcp".into())
        .spawn(move || {
            while !flag.load(Ordering::SeqCst) {
                match listener.accept() {
                    Ok((stream, peer)) => {
                        let Some(permit) = ConnectionPermit::acquire(&connections) else {
                            // Drop excess sockets without blocking the listener on a response.
                            continue;
                        };
                        let _ = stream.set_nonblocking(false);
                        let t = tok.clone();
                        let worker_stop = Arc::clone(&flag);
                        let deadline = Instant::now() + REQUEST_TIMEOUT;
                        let _ = std::thread::Builder::new()
                            .name("cbo-mcp-conn".into())
                            .spawn(move || {
                                let _permit = permit;
                                let _ =
                                    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                                        serve(stream, &t, peer, actual, &worker_stop, deadline)
                                    }));
                            });
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        std::thread::sleep(Duration::from_millis(25));
                    }
                    Err(_) => std::thread::sleep(Duration::from_millis(100)),
                }
            }
        })
        .map_err(|e| format!("cannot spawn mcp thread: {}", e))?;
    lock(&STATE).server = Some(Server {
        stop,
        thread: Some(thread),
        port: actual,
        token: token.to_string(),
        active,
    });
    Ok(info())
}

/// Start with a persisted OS-random token, rotating legacy/invalid credentials.
pub fn start(port: u16) -> Result<Value, String> {
    let existing = crate::db::kv("mcp.token");
    let token = token_for_start(&existing)?;
    if token != existing {
        crate::db::with(|c| crate::db::kv_set(c, "mcp.token", &token))?;
    }
    start_with_token(port, &token)
}

pub fn stop() {
    let server = lock(&STATE).server.take();
    if let Some(mut s) = server {
        s.stop.store(true, Ordering::SeqCst);
        if let Some(t) = s.thread.take() {
            let _ = t.join();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    static GLOBAL_TEST: Mutex<()> = Mutex::new(());

    #[test]
    fn secure_tokens_rotate_legacy_credentials() {
        let a = random_token().unwrap();
        let b = random_token().unwrap();
        assert!(valid_token(&a) && valid_token(&b));
        assert_ne!(a, b);
        assert_eq!(token_for_start(&a).unwrap(), a);
        for old in ["", "a1b2c3d4e5f60708", "weak", &"z".repeat(64)] {
            let replacement = token_for_start(old).unwrap();
            assert!(valid_token(&replacement));
            assert_ne!(replacement, old);
        }
        assert!(start_with_token(0, "weak").is_err());
    }

    fn parse_fixture(wire: impl FnOnce(u16, &str) -> String) -> Result<Request, RequestError> {
        let token = "a".repeat(64);
        let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let port = listener.local_addr().unwrap().port();
        let mut client = TcpStream::connect(("127.0.0.1", port)).unwrap();
        client
            .set_write_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        let (mut server, _) = listener.accept().unwrap();
        let text = wire(port, &token);
        let worker = std::thread::spawn(move || {
            read_request(
                &mut server,
                &token,
                port,
                &AtomicBool::new(false),
                Instant::now() + Duration::from_secs(2),
            )
        });
        let _ = client.write_all(text.as_bytes());
        worker.join().unwrap()
    }

    fn rejected(extra: &str, expected: &str) {
        let result = parse_fixture(|port, token| {
            format!("POST /mcp/{token} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n{extra}\r\n")
        });
        assert_eq!(result.err().unwrap().status, expected);
    }

    #[test]
    fn validates_origins_and_auth_before_reading_bodies() {
        // Non-browser clients omit Origin; same-origin browser clients are allowed.
        for origin in [false, true] {
            assert!(parse_fixture(|port, token| format!(
                "POST /mcp/{token} HTTP/1.1\r\nHost: localhost:{port}\r\n{}Content-Length: 2\r\n\r\n{{}}",
                if origin { format!("Origin: http://localhost:{port}\r\n") } else { String::new() }
            )).is_ok());
        }
        for origin in [
            "https://untrusted.example",
            "null",
            "http://localhost.evil.example",
            "http://127.0.0.1:1",
            "",
        ] {
            rejected(
                &format!("Origin: {origin}\r\nContent-Length: 1000\r\n"),
                "403 Forbidden",
            );
        }
        let bad_host = parse_fixture(|_, token| {
            format!("POST /mcp/{token} HTTP/1.1\r\nHost: untrusted.example\r\n\r\n")
        });
        assert_eq!(bad_host.err().unwrap().status, "403 Forbidden");
        let wrong_token = parse_fixture(|port, _| {
            format!(
            "POST /mcp/wrong HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nContent-Length: {MAX_BODY}\r\n\r\n")
        });
        assert_eq!(wrong_token.err().unwrap().status, "404 Not Found");
    }

    #[test]
    fn rejects_oversized_and_ambiguous_requests() {
        rejected(
            &format!("X-Long: {}\r\n", "x".repeat(MAX_HEADERS)),
            "431 Request Header Fields Too Large",
        );
        rejected(
            &"X-Test: x\r\n".repeat(MAX_HEADER_COUNT),
            "431 Request Header Fields Too Large",
        );
        rejected(
            &format!("Content-Length: {}\r\n", MAX_BODY + 1),
            "413 Payload Too Large",
        );
        for headers in [
            "Content-Length: 1\r\nContent-Length: 2\r\n",
            "Content-Length: -1\r\n",
            "Content-Length: nope\r\n",
            "Transfer-Encoding: chunked\r\n",
            "Host: localhost:1\r\n",
            "Origin: null\r\nOrigin: null\r\n",
            " Folded: value\r\n",
        ] {
            rejected(headers, "400 Bad Request");
        }
        let long_line =
            parse_fixture(|_, _| format!("GET /{} HTTP/1.1\r\n\r\n", "x".repeat(MAX_HEADERS)));
        assert_eq!(
            long_line.err().unwrap().status,
            "431 Request Header Fields Too Large"
        );
    }

    #[test]
    fn slow_body_cannot_extend_absolute_deadline() {
        let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let port = listener.local_addr().unwrap().port();
        let mut client = TcpStream::connect(("127.0.0.1", port)).unwrap();
        let (mut server, _) = listener.accept().unwrap();
        let token = "a".repeat(64);
        write!(
            client,
            "POST /mcp/{token} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nContent-Length: 1000\r\n\r\n"
        )
        .unwrap();
        let writer = std::thread::spawn(move || {
            for _ in 0..100 {
                if client.write_all(b"x").is_err() {
                    break;
                }
                std::thread::sleep(Duration::from_millis(10));
            }
        });
        let started = Instant::now();
        let result = read_request(
            &mut server,
            &token,
            port,
            &AtomicBool::new(false),
            started + Duration::from_millis(150),
        );
        assert_eq!(result.err().unwrap().status, "408 Request Timeout");
        assert!(started.elapsed() < Duration::from_secs(1));
        drop(server);
        writer.join().unwrap();
    }

    #[test]
    fn connection_slots_are_bounded_and_released() {
        let active = Arc::new(AtomicUsize::new(0));
        let permits: Vec<_> = (0..MAX_CONNECTIONS)
            .map(|_| ConnectionPermit::acquire(&active).unwrap())
            .collect();
        assert!(ConnectionPermit::acquire(&active).is_none());
        drop(permits);
        assert_eq!(active.load(Ordering::Relaxed), 0);
        assert!(ConnectionPermit::acquire(&active).is_some());
    }

    #[test]
    fn rpc_initialize_list_and_call() {
        let _guard = lock(&GLOBAL_TEST);
        let init = handle_rpc(&json!({"jsonrpc":"2.0","id":1,"method":"initialize",
            "params":{"protocolVersion":"2024-11-05","capabilities":{}}}))
        .unwrap();
        assert_eq!(init["result"]["protocolVersion"], "2024-11-05");
        assert_eq!(init["result"]["serverInfo"]["name"], SERVER_NAME);
        assert!(
            handle_rpc(&json!({"jsonrpc":"2.0","method":"notifications/initialized"})).is_none()
        );
        let list = handle_rpc(&json!({"jsonrpc":"2.0","id":2,"method":"tools/list"})).unwrap();
        let names: Vec<&str> = list["result"]["tools"]
            .as_array()
            .unwrap()
            .iter()
            .map(|t| t["name"].as_str().unwrap())
            .collect();
        assert!(names.contains(&"office_send") && names.contains(&"office_screen"));
        for t in list["result"]["tools"].as_array().unwrap() {
            assert_eq!(t["inputSchema"]["type"], "object", "{}", t["name"]);
        }
        let _ = take_inbox();
        let call = handle_rpc(&json!({"jsonrpc":"2.0","id":3,"method":"tools/call",
            "params":{"name":"office_send","arguments":{"text":"ls -la\n","title":"hint"}}}))
        .unwrap();
        assert_eq!(call["result"]["isError"], Value::Null);
        let inbox: Value = serde_json::from_str(&take_inbox()).unwrap();
        assert_eq!(inbox[0]["kind"], "send");
        assert_eq!(inbox[0]["text"], "ls -la\n");
        assert_eq!(inbox[0]["title"], "hint");
        assert_eq!(take_inbox(), "[]");
        let bad = handle_rpc(&json!({"jsonrpc":"2.0","id":4,"method":"tools/call",
            "params":{"name":"office_send","arguments":{}}}))
        .unwrap();
        assert_eq!(bad["result"]["isError"], true);
        let unknown = handle_rpc(&json!({"jsonrpc":"2.0","id":5,"method":"nope"})).unwrap();
        assert_eq!(unknown["error"]["code"], -32601);
        let screen = handle_rpc(&json!({"jsonrpc":"2.0","id":6,"method":"tools/call",
            "params":{"name":"office_screen","arguments":{"session":120}}}))
        .unwrap();
        assert_eq!(screen["result"]["isError"], true);
        assert!(handle_body("not json").is_err());
        assert_eq!(
            handle_body(r#"[{"jsonrpc":"2.0","method":"notifications/x"}]"#).unwrap(),
            ""
        );
    }

    #[test]
    fn http_server_round_trip() {
        let _guard = lock(&GLOBAL_TEST);
        let token = "b".repeat(64);
        let started = start_with_token(0, &token).unwrap();
        assert_eq!(started["running"], true);
        let url = started["url"].as_str().unwrap().to_string();
        assert!(url.ends_with(&format!("/mcp/{token}")));
        let agent = ureq::AgentBuilder::new()
            .timeout(Duration::from_secs(5))
            .build();
        let resp = agent
            .post(&url)
            .send_json(json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}))
            .unwrap();
        assert_eq!(resp.status(), 200);
        match agent
            .post(&url)
            .set("Origin", "https://untrusted.example")
            .send_json(json!({"jsonrpc":"2.0","id":9,"method":"ping"}))
        {
            Err(ureq::Error::Status(403, _)) => {}
            other => panic!(
                "expected forbidden origin, got {:?}",
                other.map(|r| r.status())
            ),
        }
        let v: Value = resp.into_json().unwrap();
        assert_eq!(v["result"]["protocolVersion"], PROTOCOL_VERSION);
        let resp = agent
            .post(&url)
            .send_json(json!({"jsonrpc":"2.0","method":"notifications/initialized"}))
            .unwrap();
        assert_eq!(resp.status(), 202);
        let _ = take_inbox();
        let resp = agent
            .post(&url)
            .send_json(json!({"jsonrpc":"2.0","id":2,"method":"tools/call",
                "params":{"name":"office_practice","arguments":{"code":"print(1)\n"}}}))
            .unwrap();
        let v: Value = resp.into_json().unwrap();
        assert!(v["result"]["content"][0]["text"]
            .as_str()
            .unwrap()
            .contains("practice"));
        let inbox: Value = serde_json::from_str(&take_inbox()).unwrap();
        assert_eq!(inbox[0]["kind"], "practice");
        match agent
            .post(&url.replace(&token, "wrong"))
            .send_json(json!({}))
        {
            Err(ureq::Error::Status(404, _)) => {}
            other => panic!("expected 404, got {:?}", other.map(|r| r.status())),
        }
        match agent.get(&url).call() {
            Err(ureq::Error::Status(405, _)) => {}
            other => panic!("expected 405, got {:?}", other.map(|r| r.status())),
        }
        assert!(info()["requests"].as_u64().unwrap() >= 4);
        let active = Arc::clone(&lock(&STATE).server.as_ref().unwrap().active);
        let wait_count = |expected| {
            let deadline = Instant::now() + Duration::from_secs(2);
            while active.load(Ordering::Relaxed) != expected && Instant::now() < deadline {
                std::thread::sleep(Duration::from_millis(5));
            }
            assert_eq!(active.load(Ordering::Relaxed), expected);
        };
        wait_count(0);
        let port = started["port"].as_u64().unwrap() as u16;
        let clients: Vec<_> = (0..MAX_CONNECTIONS)
            .map(|_| TcpStream::connect(("127.0.0.1", port)).unwrap())
            .collect();
        wait_count(MAX_CONNECTIONS);
        let mut excess = TcpStream::connect(("127.0.0.1", port)).unwrap();
        excess
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        assert!(matches!(excess.read(&mut [0u8]), Ok(0)));
        drop(clients);
        wait_count(0);
        // STOP also interrupts accepted sockets that have not sent a request.
        let _pending = TcpStream::connect(("127.0.0.1", port)).unwrap();
        wait_count(1);
        stop();
        wait_count(0);
        assert_eq!(info()["running"], false);
        assert!(agent.post(&url).send_json(json!({})).is_err());
        assert_eq!(random_token().unwrap().len(), 64);
    }
}
