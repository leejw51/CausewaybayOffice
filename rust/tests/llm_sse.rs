//! SSE parsing for all three providers, plus the full HTTP + SSE path against
//! a tiny local server that replays fixtures. No network, no keys.

mod common;

use std::io::{Read, Write};
use std::net::TcpListener;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde_json::Value;

use cbo_core::llm::{
    cancel, free, get, parse_sse_line, set_endpoint_override, start, Provider, SseEvent, StartArgs,
    ANTHROPIC_MAX_TOKENS, ANTHROPIC_VERSION, REFUSAL_NOTE,
};
use common::{from_c, LLM_DONE, LLM_ERROR, LLM_STREAMING};

// ------------------------------------------------------------- pure parsing

fn collect(provider: Provider, stream: &str) -> (String, bool, Option<String>) {
    let mut text = String::new();
    for line in stream.split_inclusive('\n') {
        match parse_sse_line(provider, line) {
            SseEvent::Text(t) => text.push_str(&t),
            SseEvent::Done => return (text, true, None),
            SseEvent::Error(e) => return (text, false, Some(e)),
            SseEvent::Tools(_) | SseEvent::Nothing => {}
        }
    }
    (text, false, None)
}

const OPENAI_FIXTURE: &str = concat!(
    ": keep-alive\n",
    "\n",
    "data: {\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"\"}}]}\n",
    "data: {\"choices\":[{\"index\":0,\"delta\":{\"reasoning_content\":\"thinking...\"}}]}\n",
    "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"안녕\"}}]}\r\n",
    "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"하세요 \"}}]}\n",
    "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Příliš žluťoučký kůň\"}}]}\n",
    "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n",
    "data: [DONE]\n",
    "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"AFTER DONE\"}}]}\n",
);

const ANTHROPIC_FIXTURE: &str = concat!(
    "event: message_start\n",
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"role\":\"assistant\"}}\n",
    "\n",
    "event: content_block_start\n",
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n",
    "\n",
    "event: ping\n",
    "data: {\"type\":\"ping\"}\n",
    "\n",
    "event: content_block_delta\n",
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"你好\"}}\n",
    "\n",
    "event: content_block_delta\n",
    "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"a\\\":1}\"}}\n",
    "\n",
    "event: content_block_delta\n",
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"世界 こんにちは\"}}\n",
    "\n",
    "event: content_block_stop\n",
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n",
    "\n",
    "event: message_delta\n",
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":5}}\n",
    "\n",
    "event: message_stop\n",
    "data: {\"type\":\"message_stop\"}\n",
    "\n",
);

#[test]
fn openai_and_xai_fixture() {
    for p in [Provider::OpenAi, Provider::Xai] {
        let (text, done, err) = collect(p, OPENAI_FIXTURE);
        assert_eq!(text, "안녕하세요 Příliš žluťoučký kůň", "{:?}", p);
        assert!(done, "{:?} must see [DONE]", p);
        assert!(err.is_none());
    }
}

#[test]
fn anthropic_fixture() {
    let (text, done, err) = collect(Provider::Anthropic, ANTHROPIC_FIXTURE);
    assert_eq!(text, "你好世界 こんにちは");
    assert!(done);
    assert!(err.is_none());
}

#[test]
fn anthropic_refusal_stop_reason_adds_note() {
    let stream = concat!(
        "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"I \"}}\n",
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"refusal\"}}\n",
        "data: {\"type\":\"message_stop\"}\n",
    );
    let (text, done, _) = collect(Provider::Anthropic, stream);
    assert_eq!(text, format!("I {}", REFUSAL_NOTE));
    assert!(done);
}

#[test]
fn error_events() {
    let line = "data: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}";
    assert_eq!(
        parse_sse_line(Provider::Anthropic, line),
        SseEvent::Error("Overloaded".into())
    );
    let line = "data: {\"error\":{\"message\":\"rate limited\",\"code\":\"rate_limit\"}}";
    assert_eq!(
        parse_sse_line(Provider::Xai, line),
        SseEvent::Error("rate limited".into())
    );
    let line = "data: {\"error\":\"plain string\"}";
    assert!(matches!(
        parse_sse_line(Provider::OpenAi, line),
        SseEvent::Error(_)
    ));
}

#[test]
fn junk_lines_are_ignored() {
    for p in [Provider::OpenAi, Provider::Anthropic] {
        assert_eq!(parse_sse_line(p, ""), SseEvent::Nothing);
        assert_eq!(parse_sse_line(p, "event: ping"), SseEvent::Nothing);
        assert_eq!(parse_sse_line(p, ": comment"), SseEvent::Nothing);
        assert_eq!(parse_sse_line(p, "data:"), SseEvent::Nothing);
        assert_eq!(parse_sse_line(p, "data: {not json"), SseEvent::Nothing);
        assert_eq!(
            parse_sse_line(p, "data: {\"choices\":[]}"),
            SseEvent::Nothing
        );
    }
    assert_eq!(
        parse_sse_line(Provider::Anthropic, "data: [DONE]"),
        SseEvent::Nothing
    );
}

// ------------------------------------------------------- local HTTP replay

/// A one-shot HTTP/1.1 server: accepts a single connection, reads the
/// request, replies with `status` and `body` in `chunks` writes separated by
/// `gap`, then closes (no content-length, so EOF ends the body).
struct Replay {
    url: String,
    thread: Option<std::thread::JoinHandle<String>>,
}

fn replay(
    status: &'static str,
    body: &'static str,
    chunks: Vec<&'static str>,
    gap: Duration,
) -> Replay {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let port = listener.local_addr().expect("addr").port();
    let thread = std::thread::spawn(move || {
        let (mut sock, _) = listener.accept().expect("accept");
        let _ = sock.set_read_timeout(Some(Duration::from_secs(5)));
        let mut req = Vec::new();
        let mut buf = [0u8; 4096];
        loop {
            let n = sock.read(&mut buf).unwrap_or(0);
            if n == 0 {
                break;
            }
            req.extend_from_slice(&buf[..n]);
            if let Some(pos) = req.windows(4).position(|w| w == b"\r\n\r\n") {
                let head = String::from_utf8_lossy(&req[..pos]).to_string();
                let len = head
                    .lines()
                    .find_map(|l| {
                        l.to_ascii_lowercase()
                            .strip_prefix("content-length:")
                            .map(|v| v.trim().parse::<usize>().unwrap_or(0))
                    })
                    .unwrap_or(0);
                if req.len() >= pos + 4 + len {
                    break;
                }
            }
        }
        let request = String::from_utf8_lossy(&req).to_string();
        let head = format!(
            "HTTP/1.1 {}\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n",
            status
        );
        let _ = sock.write_all(head.as_bytes());
        if chunks.is_empty() {
            let _ = sock.write_all(body.as_bytes());
        } else {
            for c in chunks {
                let _ = sock.write_all(c.as_bytes());
                let _ = sock.flush();
                std::thread::sleep(gap);
            }
        }
        let _ = sock.flush();
        request
    });
    Replay {
        url: format!("http://127.0.0.1:{}/v1/replay", port),
        thread: Some(thread),
    }
}

impl Replay {
    fn request(&mut self) -> String {
        self.thread
            .take()
            .map(|t| t.join().unwrap_or_default())
            .unwrap_or_default()
    }
}

/// The endpoint override is process-global: serialise the tests that use it.
static HTTP: Mutex<()> = Mutex::new(());

fn start_local(provider: &str, url: &str) -> i32 {
    set_endpoint_override(Some(url));
    start(StartArgs {
        provider: provider.into(),
        api_key: "test-key-123".into(),
        model: None,
        system: Some("be brief".into()),
        messages_json: "[{\"role\":\"user\",\"content\":\"hi\"}]".into(),
        tools_json: None,
    })
    .expect("start")
}

/// Same, with a tool offered and a conversation that already carries a call
/// and its result, so the request body exercises the whole conversion.
fn start_local_tools(provider: &str, url: &str) -> i32 {
    set_endpoint_override(Some(url));
    start(StartArgs {
        provider: provider.into(),
        api_key: "test-key-123".into(),
        model: None,
        system: Some("be brief".into()),
        messages_json: r#"[
            {"role":"user","content":"what is on screen?"},
            {"role":"assistant","content":"","tool_calls":[{"id":"c1","name":"read_screen","arguments":"{\"lines\":5}"}]},
            {"role":"tool","tool_call_id":"c1","name":"read_screen","content":"$ ls\nCargo.toml"}
        ]"#
        .into(),
        tools_json: Some(
            r#"[{"name":"read_screen","description":"the screen","parameters":{"type":"object","properties":{"lines":{"type":"integer"}}}}]"#
                .into(),
        ),
    })
    .expect("start")
}

fn drive(id: i32, timeout: Duration) -> (i32, String, Vec<String>) {
    let start = Instant::now();
    let mut text = String::new();
    let mut deltas = Vec::new();
    let mut states = Vec::new();
    loop {
        let st = get(id).map(|r| r.state()).expect("req");
        if states.last() != Some(&st) {
            states.push(st);
        }
        let d = get(id).map(|r| r.take_delta()).unwrap_or_default();
        if !d.is_empty() {
            deltas.push(d.clone());
            text.push_str(&d);
        }
        if st == LLM_DONE || st == LLM_ERROR {
            let tail = get(id).map(|r| r.take_delta()).unwrap_or_default();
            text.push_str(&tail);
            return (st, text, deltas);
        }
        assert!(start.elapsed() < timeout, "timeout; states {:?}", states);
        std::thread::sleep(Duration::from_millis(5));
    }
}

#[test]
fn http_openai_stream_split_across_chunks() {
    let _g = HTTP.lock().unwrap_or_else(|e| e.into_inner());
    // Lines split mid-JSON and mid-token across TCP writes.
    let chunks = vec![
        "data: {\"choices\":[{\"delta\":{\"con",
        "tent\":\"안",
        "녕\"}}]}\n",
        "data: {\"choices\":[{\"delta\":{\"content\":\"하세요\"}}]}\n\n",
        "data: [DO",
        "NE]\n",
    ];
    let mut srv = replay("200 OK", "", chunks, Duration::from_millis(40));
    let id = start_local("openai", &srv.url);
    let (st, text, deltas) = drive(id, Duration::from_secs(10));
    set_endpoint_override(None);
    assert_eq!(st, LLM_DONE);
    assert_eq!(text, "안녕하세요");
    assert!(
        deltas.len() >= 2,
        "expected streaming deltas, got {:?}",
        deltas
    );
    let req = srv.request();
    assert!(req.starts_with("POST /v1/replay "), "{}", req);
    assert!(
        req.contains("Authorization: Bearer test-key-123"),
        "{}",
        req
    );
    let body = req.split("\r\n\r\n").nth(1).unwrap_or("");
    let v: serde_json::Value = serde_json::from_str(body).expect("json body");
    assert_eq!(v["model"], "gpt-5");
    assert_eq!(v["stream"], true);
    assert_eq!(v["messages"][0]["role"], "system");
    assert_eq!(v["messages"][1]["content"], "hi");
    free(id);
}

#[test]
fn http_anthropic_stream_headers_and_body() {
    let _g = HTTP.lock().unwrap_or_else(|e| e.into_inner());
    let mut srv = replay("200 OK", ANTHROPIC_FIXTURE, vec![], Duration::ZERO);
    let id = start_local("anthropic", &srv.url);
    let (st, text, _) = drive(id, Duration::from_secs(10));
    set_endpoint_override(None);
    assert_eq!(st, LLM_DONE);
    assert_eq!(text, "你好世界 こんにちは");
    let req = srv.request();
    assert!(req.contains("x-api-key: test-key-123"), "{}", req);
    assert!(
        req.contains(&format!("anthropic-version: {}", ANTHROPIC_VERSION)),
        "{}",
        req
    );
    let body = req.split("\r\n\r\n").nth(1).unwrap_or("");
    let v: serde_json::Value = serde_json::from_str(body).expect("json body");
    assert_eq!(v["model"], "claude-opus-5");
    assert_eq!(v["max_tokens"], ANTHROPIC_MAX_TOKENS);
    assert_eq!(v["system"], "be brief");
    assert_eq!(v["messages"].as_array().map(|m| m.len()), Some(1));
    free(id);
}

#[test]
fn http_xai_reports_truncated_stream() {
    let _g = HTTP.lock().unwrap_or_else(|e| e.into_inner());
    // Preserve partial text, but report a missing completion marker.
    let body = "data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n";
    let mut srv = replay("200 OK", body, vec![], Duration::ZERO);
    let id = start_local("xai", &srv.url);
    let (st, text, _) = drive(id, Duration::from_secs(10));
    set_endpoint_override(None);
    assert_eq!(st, LLM_ERROR);
    assert_eq!(text, "partial");
    let req = srv.request();
    let v: serde_json::Value =
        serde_json::from_str(req.split("\r\n\r\n").nth(1).unwrap_or("")).expect("json");
    assert_eq!(v["model"], "grok-4.6");
    free(id);
}

#[test]
fn http_non_2xx_is_error_with_body() {
    let _g = HTTP.lock().unwrap_or_else(|e| e.into_inner());
    let body =
        "{\"error\":{\"message\":\"Incorrect API key provided\",\"code\":\"invalid_api_key\"}}";
    let mut srv = replay("401 Unauthorized", body, vec![], Duration::ZERO);
    let id = start_local("openai", &srv.url);
    let (st, text, _) = drive(id, Duration::from_secs(10));
    set_endpoint_override(None);
    assert_eq!(st, LLM_ERROR);
    assert_eq!(text, "");
    let err = get(id).map(|r| r.error()).unwrap_or_default();
    assert!(err.starts_with("HTTP 401"), "{}", err);
    assert!(err.contains("Incorrect API key provided"), "{}", err);
    let _ = srv.request();
    free(id);
}

#[test]
fn http_inline_error_event_is_error() {
    let _g = HTTP.lock().unwrap_or_else(|e| e.into_inner());
    let body = concat!(
        "data: {\"choices\":[{\"delta\":{\"content\":\"a\"}}]}\n",
        "data: {\"error\":{\"message\":\"boom\"}}\n",
    );
    let mut srv = replay("200 OK", body, vec![], Duration::ZERO);
    let id = start_local("openai", &srv.url);
    let (st, text, _) = drive(id, Duration::from_secs(10));
    set_endpoint_override(None);
    assert_eq!(st, LLM_ERROR);
    assert_eq!(text, "a", "text before the error is kept");
    assert_eq!(get(id).map(|r| r.error()).unwrap_or_default(), "boom");
    let _ = srv.request();
    free(id);
}

#[test]
fn http_cancel_mid_stream() {
    let _g = HTTP.lock().unwrap_or_else(|e| e.into_inner());
    let chunks: Vec<&'static str> = (0..20)
        .map(|_| "data: {\"choices\":[{\"delta\":{\"content\":\"x\"}}]}\n")
        .collect();
    let mut srv = replay("200 OK", "", chunks, Duration::from_millis(50));
    let id = start_local("openai", &srv.url);
    // Wait for the first delta, then cancel.
    let t0 = Instant::now();
    let mut got = String::new();
    while got.is_empty() && t0.elapsed() < Duration::from_secs(5) {
        got = get(id).map(|r| r.take_delta()).unwrap_or_default();
        std::thread::sleep(Duration::from_millis(5));
    }
    assert!(!got.is_empty(), "no delta before cancel");
    assert_eq!(get(id).map(|r| r.state()), Some(LLM_STREAMING));
    cancel(id);
    let t1 = Instant::now();
    while get(id).map(|r| r.state()) == Some(LLM_STREAMING) && t1.elapsed() < Duration::from_secs(3)
    {
        std::thread::sleep(Duration::from_millis(5));
    }
    assert_eq!(
        get(id).map(|r| r.state()),
        Some(LLM_DONE),
        "cancel settles to DONE"
    );
    let after = get(id).map(|r| r.take_delta()).unwrap_or_default();
    assert!(
        after.len() < 20,
        "stream kept flowing after cancel: {:?}",
        after
    );
    set_endpoint_override(None);
    let _ = srv.request();
    free(id);
    assert!(get(id).is_none());
}

#[test]
fn http_connection_refused_is_error() {
    let _g = HTTP.lock().unwrap_or_else(|e| e.into_inner());
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let port = listener.local_addr().expect("addr").port();
    drop(listener);
    let id = start_local("xai", &format!("http://127.0.0.1:{}/x", port));
    let (st, _, _) = drive(id, Duration::from_secs(10));
    set_endpoint_override(None);
    assert_eq!(st, LLM_ERROR);
    let err = get(id).map(|r| r.error()).unwrap_or_default();
    assert!(err.contains("transport"), "{}", err);
    free(id);
}

#[test]
fn ffi_state_of_unknown_request() {
    assert_eq!(cbo_core::cbo_llm_state(-1), LLM_ERROR);
    assert_eq!(cbo_core::cbo_llm_state(9999), LLM_ERROR);
    assert_eq!(from_c(cbo_core::cbo_llm_take_delta(9999)), "");
    assert_eq!(from_c(cbo_core::cbo_llm_error(9999)), "bad request id");
    cbo_core::cbo_llm_cancel(9999);
    cbo_core::cbo_llm_free(9999);
}

// ------------------------------------------------------------ tool calling

const OPENAI_TOOL_SSE: &str = concat!(
    "data: {\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[{\"index\":0,\"id\":\"call_a\",\"type\":\"function\",\"function\":{\"name\":\"read_screen\",\"arguments\":\"\"}}]}}]}\n",
    "data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{\\\"li\"}}]}}]}\n",
    "data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"nes\\\":5}\"}}]}}]}\n",
    "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n",
    "data: [DONE]\n",
);

const ANTHROPIC_TOOL_SSE: &str = concat!(
    "event: content_block_start\n",
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n",
    "\n",
    "event: content_block_delta\n",
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Checking.\"}}\n",
    "\n",
    "event: content_block_start\n",
    "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_a\",\"name\":\"read_screen\",\"input\":{}}}\n",
    "\n",
    "event: content_block_delta\n",
    "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"lines\\\":\"}}\n",
    "\n",
    "event: content_block_delta\n",
    "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"5}\"}}\n",
    "\n",
    "event: message_stop\n",
    "data: {\"type\":\"message_stop\"}\n",
);

/// OpenAI shape end to end: the request body carries the tool and the earlier
/// call/result pair, and the streamed fragments assemble into one call.
#[test]
fn openai_tool_call_round_trip_over_http() {
    let _g = HTTP.lock().unwrap_or_else(|e| e.into_inner());
    let mut replay = replay(
        "200 OK",
        "",
        vec![OPENAI_TOOL_SSE],
        Duration::from_millis(0),
    );
    let id = start_local_tools("openai", &replay.url);
    let (st, text, _) = drive(id, Duration::from_secs(10));
    assert_eq!(st, LLM_DONE);
    assert_eq!(text, "", "a pure tool turn streams no text");

    let calls: Value = serde_json::from_str(&get(id).expect("req").calls_json()).expect("json");
    let calls = calls.as_array().expect("array");
    assert_eq!(calls.len(), 1);
    assert_eq!(calls[0]["id"], "call_a");
    assert_eq!(calls[0]["name"], "read_screen");
    assert_eq!(calls[0]["arguments"], "{\"lines\":5}");
    free(id);

    let request = replay.request();
    let body: Value = serde_json::from_str(request.split("\r\n\r\n").nth(1).unwrap_or("{}"))
        .expect("request body is JSON");
    assert_eq!(body["tools"][0]["type"], "function");
    assert_eq!(body["tools"][0]["function"]["name"], "read_screen");
    let msgs = body["messages"].as_array().expect("messages");
    // system, user, assistant(tool_calls), tool
    assert_eq!(msgs.len(), 4);
    assert_eq!(msgs[2]["tool_calls"][0]["id"], "c1");
    assert_eq!(
        msgs[2]["tool_calls"][0]["function"]["arguments"],
        "{\"lines\":5}"
    );
    assert_eq!(msgs[3]["role"], "tool");
    assert_eq!(msgs[3]["tool_call_id"], "c1");
    assert!(msgs[3]["content"]
        .as_str()
        .unwrap_or("")
        .contains("Cargo.toml"));
}

/// Anthropic shape end to end: tools use `input_schema`, the call becomes a
/// `tool_use` block and its result a `tool_result` inside a user message.
#[test]
fn anthropic_tool_call_round_trip_over_http() {
    let _g = HTTP.lock().unwrap_or_else(|e| e.into_inner());
    let mut replay = replay(
        "200 OK",
        "",
        vec![ANTHROPIC_TOOL_SSE],
        Duration::from_millis(0),
    );
    let id = start_local_tools("anthropic", &replay.url);
    let (st, text, _) = drive(id, Duration::from_secs(10));
    assert_eq!(st, LLM_DONE);
    assert_eq!(text, "Checking.", "text and a call can arrive together");

    let calls: Value = serde_json::from_str(&get(id).expect("req").calls_json()).expect("json");
    assert_eq!(calls[0]["id"], "toolu_a");
    assert_eq!(calls[0]["arguments"], "{\"lines\":5}");
    free(id);

    let request = replay.request();
    let body: Value = serde_json::from_str(request.split("\r\n\r\n").nth(1).unwrap_or("{}"))
        .expect("request body is JSON");
    assert_eq!(body["tools"][0]["name"], "read_screen");
    assert_eq!(body["tools"][0]["input_schema"]["type"], "object");
    assert_eq!(body["system"], "be brief");
    let msgs = body["messages"].as_array().expect("messages");
    // user, assistant(tool_use), user(tool_result) - system is its own field
    assert_eq!(msgs.len(), 3);
    assert_eq!(msgs[1]["content"][0]["type"], "tool_use");
    assert_eq!(msgs[1]["content"][0]["input"]["lines"], 5);
    assert_eq!(msgs[2]["role"], "user");
    assert_eq!(msgs[2]["content"][0]["type"], "tool_result");
    assert_eq!(msgs[2]["content"][0]["tool_use_id"], "c1");
}

/// A malformed tool list is refused before anything is sent.
#[test]
fn bad_tools_json_is_rejected() {
    let err = start(StartArgs {
        provider: "openai".into(),
        api_key: "k".into(),
        model: None,
        system: None,
        messages_json: "[]".into(),
        tools_json: Some("{not json".into()),
    })
    .expect_err("must refuse");
    assert!(err.contains("tools_json"), "{}", err);

    let err = start(StartArgs {
        provider: "openai".into(),
        api_key: "k".into(),
        model: None,
        system: None,
        messages_json: "[]".into(),
        tools_json: Some("{\"name\":\"x\"}".into()),
    })
    .expect_err("must refuse a non-array");
    assert!(err.contains("array"), "{}", err);
}
