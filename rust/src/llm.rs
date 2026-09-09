//! Streaming chat completions (SSE) for openai / xai / anthropic. Blocking
//! HTTP via `ureq` on a spawned thread; the FFI side polls state and drains
//! the delta buffer.

use std::io::{BufRead, BufReader, Read};
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use serde_json::{json, Value};

use crate::session::lock;

pub const LLM_PENDING: i32 = 0;
pub const LLM_STREAMING: i32 = 1;
pub const LLM_DONE: i32 = 2;
pub const LLM_ERROR: i32 = 3;

const MAX_REQUESTS: usize = 64;
const MAX_STREAM_BYTES: usize = 4 * 1024 * 1024;
const MAX_LINE_BYTES: u64 = 1024 * 1024;
pub const ANTHROPIC_VERSION: &str = "2023-06-01";
pub const ANTHROPIC_MAX_TOKENS: u32 = 8192;
pub const REFUSAL_NOTE: &str = "[declined by safety classifier]";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Provider {
    OpenAi,
    Xai,
    Anthropic,
}

impl Provider {
    pub fn parse(s: &str) -> Option<Provider> {
        match s.trim().to_ascii_lowercase().as_str() {
            "openai" => Some(Provider::OpenAi),
            "xai" | "grok" | "x.ai" => Some(Provider::Xai),
            "anthropic" | "claude" => Some(Provider::Anthropic),
            _ => None,
        }
    }

    pub fn endpoint(self) -> &'static str {
        match self {
            Provider::OpenAi => "https://api.openai.com/v1/chat/completions",
            Provider::Xai => "https://api.x.ai/v1/chat/completions",
            Provider::Anthropic => "https://api.anthropic.com/v1/messages",
        }
    }

    pub fn default_model(self) -> &'static str {
        match self {
            Provider::OpenAi => "gpt-5",
            Provider::Xai => "grok-4.6",
            Provider::Anthropic => "claude-opus-5",
        }
    }
}

/// Build the JSON request body for a provider.
pub fn build_body(
    provider: Provider,
    model: &str,
    system: Option<&str>,
    messages: &Value,
) -> Value {
    match provider {
        Provider::Anthropic => {
            let mut body = json!({
                "model": model,
                "max_tokens": ANTHROPIC_MAX_TOKENS,
                "stream": true,
                "messages": messages,
            });
            if let Some(sys) = system.filter(|s| !s.is_empty()) {
                body["system"] = Value::String(sys.to_string());
            }
            body
        }
        Provider::OpenAi | Provider::Xai => {
            let mut all = Vec::new();
            if let Some(sys) = system.filter(|s| !s.is_empty()) {
                all.push(json!({"role": "system", "content": sys}));
            }
            if let Some(arr) = messages.as_array() {
                all.extend(arr.iter().cloned());
            }
            json!({
                "model": model,
                "stream": true,
                "messages": all,
            })
        }
    }
}

/// One parsed SSE `data:` payload.
#[derive(Debug, PartialEq, Eq)]
pub enum SseEvent {
    /// Nothing interesting (comment, empty, keepalive, non-text delta).
    Nothing,
    Text(String),
    Done,
    Error(String),
}

/// Parse a single line of an SSE stream for the given provider. `event:`
/// lines are ignored: both providers carry the type inside the JSON.
pub fn parse_sse_line(provider: Provider, line: &str) -> SseEvent {
    let line = line.trim_end_matches(['\r', '\n']);
    let Some(data) = line.strip_prefix("data:") else {
        return SseEvent::Nothing;
    };
    let data = data.trim();
    if data.is_empty() {
        return SseEvent::Nothing;
    }
    match provider {
        Provider::OpenAi | Provider::Xai => {
            if data == "[DONE]" {
                return SseEvent::Done;
            }
            let v: Value = match serde_json::from_str(data) {
                Ok(v) => v,
                Err(_) => return SseEvent::Nothing,
            };
            if let Some(err) = v.get("error") {
                return SseEvent::Error(error_message(err));
            }
            let choice = v.get("choices").and_then(|c| c.get(0));
            if let Some(text) = choice
                .and_then(|c| c.get("delta"))
                .and_then(|d| d.get("content"))
                .and_then(|c| c.as_str())
            {
                if !text.is_empty() {
                    return SseEvent::Text(text.to_string());
                }
            }
            SseEvent::Nothing
        }
        Provider::Anthropic => {
            let v: Value = match serde_json::from_str(data) {
                Ok(v) => v,
                Err(_) => return SseEvent::Nothing,
            };
            match v.get("type").and_then(|t| t.as_str()).unwrap_or("") {
                "content_block_delta" => {
                    let delta = v.get("delta");
                    let is_text = delta
                        .and_then(|d| d.get("type"))
                        .and_then(|t| t.as_str())
                        .map(|t| t == "text_delta")
                        .unwrap_or(false);
                    if is_text {
                        if let Some(t) = delta.and_then(|d| d.get("text")).and_then(|t| t.as_str())
                        {
                            return SseEvent::Text(t.to_string());
                        }
                    }
                    SseEvent::Nothing
                }
                "message_delta" => {
                    let stop = v
                        .get("delta")
                        .and_then(|d| d.get("stop_reason"))
                        .and_then(|s| s.as_str())
                        .unwrap_or("");
                    if stop == "refusal" {
                        SseEvent::Text(REFUSAL_NOTE.to_string())
                    } else {
                        SseEvent::Nothing
                    }
                }
                "message_stop" => SseEvent::Done,
                "error" => SseEvent::Error(
                    v.get("error")
                        .map(error_message)
                        .unwrap_or_else(|| "stream error".into()),
                ),
                _ => SseEvent::Nothing,
            }
        }
    }
}

fn error_message(err: &Value) -> String {
    err.get("message")
        .and_then(|m| m.as_str())
        .map(|s| s.to_string())
        .unwrap_or_else(|| err.to_string())
}

pub struct LlmReq {
    pub state: AtomicI32,
    pub cancel: AtomicBool,
    pub delta: Mutex<String>,
    pub error: Mutex<String>,
}

impl LlmReq {
    fn new() -> Self {
        LlmReq {
            state: AtomicI32::new(LLM_PENDING),
            cancel: AtomicBool::new(false),
            delta: Mutex::new(String::new()),
            error: Mutex::new(String::new()),
        }
    }

    pub fn state(&self) -> i32 {
        self.state.load(Ordering::SeqCst)
    }

    fn set_state(&self, st: i32) {
        let _delta = lock(&self.delta);
        self.state.store(
            if self.cancelled() { LLM_DONE } else { st },
            Ordering::SeqCst,
        );
    }

    fn fail(&self, msg: impl Into<String>) {
        *lock(&self.error) = msg.into();
        self.set_state(LLM_ERROR);
    }

    pub fn take_delta(&self) -> String {
        std::mem::take(&mut *lock(&self.delta))
    }

    pub fn error(&self) -> String {
        lock(&self.error).clone()
    }

    fn cancelled(&self) -> bool {
        self.cancel.load(Ordering::SeqCst)
    }
}

static REQUESTS: Mutex<Vec<Option<Arc<LlmReq>>>> = Mutex::new(Vec::new());

/// Test hook: when set, every provider posts to this URL instead of its real
/// endpoint (lets a local server replay SSE fixtures). Not exposed over FFI.
static ENDPOINT_OVERRIDE: Mutex<Option<String>> = Mutex::new(None);

pub fn set_endpoint_override(url: Option<&str>) {
    *lock(&ENDPOINT_OVERRIDE) = url.map(str::to_string);
}

/// The URL a request for `provider` goes to (honours the test override).
pub fn endpoint_for(provider: Provider) -> String {
    lock(&ENDPOINT_OVERRIDE)
        .clone()
        .unwrap_or_else(|| provider.endpoint().to_string())
}

fn requests() -> MutexGuard<'static, Vec<Option<Arc<LlmReq>>>> {
    let mut g = lock(&REQUESTS);
    if g.len() < MAX_REQUESTS {
        g.resize_with(MAX_REQUESTS, || None);
    }
    g
}

pub fn get(id: i32) -> Option<Arc<LlmReq>> {
    if id < 0 || id as usize >= MAX_REQUESTS {
        return None;
    }
    requests()[id as usize].clone()
}

pub fn cancel(id: i32) {
    if let Some(r) = get(id) {
        let _delta = lock(&r.delta);
        r.cancel.store(true, Ordering::SeqCst);
        r.state.store(LLM_DONE, Ordering::SeqCst);
    }
}

pub fn free(id: i32) {
    if id < 0 || id as usize >= MAX_REQUESTS {
        return;
    }
    if let Some(r) = requests()[id as usize].take() {
        let _delta = lock(&r.delta);
        r.cancel.store(true, Ordering::SeqCst);
        r.state.store(LLM_DONE, Ordering::SeqCst);
    }
}

pub struct StartArgs {
    pub provider: String,
    pub api_key: String,
    pub model: Option<String>,
    pub system: Option<String>,
    pub messages_json: String,
}

/// Validate arguments, allocate a request slot and start streaming.
pub fn start(args: StartArgs) -> Result<i32, String> {
    let provider = Provider::parse(&args.provider)
        .ok_or_else(|| format!("unknown provider '{}'", args.provider))?;
    if args.api_key.trim().is_empty() {
        return Err(format!("no API key for {}", args.provider));
    }
    let messages: Value = serde_json::from_str(&args.messages_json)
        .map_err(|e| format!("messages_json is not valid JSON: {}", e))?;
    if !messages.is_array() {
        return Err("messages_json must be a JSON array".into());
    }
    let model = args
        .model
        .filter(|m| !m.trim().is_empty())
        .unwrap_or_else(|| provider.default_model().to_string());
    let body = build_body(provider, &model, args.system.as_deref(), &messages);

    let req = Arc::new(LlmReq::new());
    let id = {
        let mut reg = requests();
        let slot = reg
            .iter()
            .position(|r| r.is_none())
            .ok_or_else(|| format!("llm request limit reached ({})", MAX_REQUESTS))?;
        reg[slot] = Some(Arc::clone(&req));
        slot as i32
    };

    let api_key = args.api_key.trim().to_string();
    let worker = Arc::clone(&req);
    let spawned = std::thread::Builder::new()
        .name(format!("cbo-llm-{}", id))
        .spawn(move || {
            let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                run(&worker, provider, &api_key, body)
            }));
            match r {
                Ok(Ok(())) => {
                    if worker.state() != LLM_ERROR {
                        worker.set_state(LLM_DONE);
                    }
                }
                Ok(Err(msg)) => worker.fail(msg),
                Err(_) => worker.fail("internal error: llm worker panicked"),
            }
        });
    if let Err(e) = spawned {
        req.fail(format!("cannot spawn llm thread: {}", e));
    }
    Ok(id)
}

fn run(req: &LlmReq, provider: Provider, api_key: &str, body: Value) -> Result<(), String> {
    let agent = ureq::AgentBuilder::new()
        .redirects(0)
        .timeout_connect(Duration::from_secs(30))
        .timeout_read(Duration::from_secs(180))
        .timeout_write(Duration::from_secs(30))
        .build();

    let mut request = agent
        .post(&endpoint_for(provider))
        .set("Accept", "text/event-stream")
        .set("Content-Type", "application/json");
    request = match provider {
        Provider::Anthropic => request
            .set("x-api-key", api_key)
            .set("anthropic-version", ANTHROPIC_VERSION),
        Provider::OpenAi | Provider::Xai => {
            request.set("Authorization", &format!("Bearer {}", api_key))
        }
    };

    let response = match request.send_json(body) {
        Ok(r) => r,
        Err(ureq::Error::Status(code, resp)) => {
            let text = resp.into_string().unwrap_or_default();
            let text = if text.trim().is_empty() {
                "(empty body)".to_string()
            } else {
                text
            };
            return Err(format!("HTTP {}: {}", code, text.trim()));
        }
        Err(ureq::Error::Transport(t)) => return Err(format!("transport error: {}", t)),
    };
    if req.cancelled() {
        return Ok(());
    }
    req.set_state(LLM_STREAMING);

    let mut reader = BufReader::new(response.into_reader());
    let mut line = String::new();
    let mut received = 0usize;
    loop {
        if req.cancelled() {
            return Ok(());
        }
        line.clear();
        let n = reader
            .by_ref()
            .take(MAX_LINE_BYTES + 1)
            .read_line(&mut line)
            .map_err(|e| format!("stream read: {}", e))?;
        if req.cancelled() {
            return Ok(());
        }
        if n as u64 > MAX_LINE_BYTES {
            return Err("stream line exceeded size limit".into());
        }
        if n == 0 {
            return Err("stream ended before completion; response may be incomplete".into());
        }
        match parse_sse_line(provider, &line) {
            SseEvent::Nothing => {}
            SseEvent::Text(t) => {
                received = received.saturating_add(t.len());
                if received > MAX_STREAM_BYTES {
                    return Err("response exceeded size limit".into());
                }
                let mut delta = lock(&req.delta);
                if !req.cancelled() {
                    delta.push_str(&t);
                }
            }
            SseEvent::Done => return Ok(()),
            SseEvent::Error(msg) => return Err(msg),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const OPENAI_STREAM: &str = concat!(
        ": keepalive\n",
        "\n",
        "data: {\"id\":\"x\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"\"}}]}\n",
        "data: {\"id\":\"x\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"안녕\"}}]}\n",
        "data: {\"id\":\"x\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"하세요\"}}]}\n",
        "data: {\"id\":\"x\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n",
        "data: [DONE]\n",
    );

    const ANTHROPIC_STREAM: &str = concat!(
        "event: message_start\n",
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m\"}}\n",
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
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}\n",
        "\n",
        "event: content_block_delta\n",
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"世界\"}}\n",
        "\n",
        "event: message_delta\n",
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}\n",
        "\n",
        "event: message_stop\n",
        "data: {\"type\":\"message_stop\"}\n",
    );

    fn collect(provider: Provider, stream: &str) -> (String, bool) {
        let mut text = String::new();
        let mut done = false;
        for line in stream.lines() {
            match parse_sse_line(provider, line) {
                SseEvent::Text(t) => text.push_str(&t),
                SseEvent::Done => {
                    done = true;
                    break;
                }
                SseEvent::Error(e) => panic!("unexpected error: {}", e),
                SseEvent::Nothing => {}
            }
        }
        (text, done)
    }

    #[test]
    fn openai_stream_parses() {
        assert_eq!(
            collect(Provider::OpenAi, OPENAI_STREAM),
            ("안녕하세요".to_string(), true)
        );
        assert_eq!(
            collect(Provider::Xai, OPENAI_STREAM),
            ("안녕하세요".to_string(), true)
        );
    }

    #[test]
    fn anthropic_stream_parses() {
        assert_eq!(
            collect(Provider::Anthropic, ANTHROPIC_STREAM),
            ("你好世界".to_string(), true)
        );
    }

    #[test]
    fn anthropic_refusal_is_noted() {
        let line = "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"refusal\"}}";
        assert_eq!(
            parse_sse_line(Provider::Anthropic, line),
            SseEvent::Text(REFUSAL_NOTE.to_string())
        );
    }

    #[test]
    fn inline_errors_surface() {
        let line = "data: {\"error\":{\"message\":\"rate limited\",\"type\":\"x\"}}";
        assert_eq!(
            parse_sse_line(Provider::OpenAi, line),
            SseEvent::Error("rate limited".into())
        );
        let line = "data: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}";
        assert_eq!(
            parse_sse_line(Provider::Anthropic, line),
            SseEvent::Error("Overloaded".into())
        );
    }

    #[test]
    fn bodies_follow_provider_shape() {
        let msgs = json!([{"role": "user", "content": "hi"}]);
        let a = build_body(
            Provider::Anthropic,
            "claude-opus-5",
            Some("be brief"),
            &msgs,
        );
        assert_eq!(a["system"], "be brief");
        assert_eq!(a["max_tokens"], ANTHROPIC_MAX_TOKENS);
        assert_eq!(a["stream"], true);
        assert_eq!(a["messages"].as_array().map(|m| m.len()), Some(1));

        let o = build_body(Provider::OpenAi, "gpt-5", Some("be brief"), &msgs);
        assert!(o.get("system").is_none());
        let m = o["messages"].as_array().cloned().unwrap_or_default();
        assert_eq!(m.len(), 2);
        assert_eq!(m[0]["role"], "system");
        assert_eq!(m[1]["role"], "user");

        let o2 = build_body(Provider::Xai, "grok-4.6", None, &msgs);
        assert_eq!(o2["messages"].as_array().map(|m| m.len()), Some(1));
    }

    #[test]
    fn provider_defaults() {
        assert_eq!(Provider::parse("OpenAI"), Some(Provider::OpenAi));
        assert_eq!(
            Provider::parse("xai").map(|p| p.default_model()),
            Some("grok-4.6")
        );
        assert_eq!(
            Provider::parse("anthropic").map(|p| p.default_model()),
            Some("claude-opus-5")
        );
        assert_eq!(Provider::parse("nope"), None);
    }

    #[test]
    fn start_rejects_bad_args() {
        let bad = start(StartArgs {
            provider: "openai".into(),
            api_key: "k".into(),
            model: None,
            system: None,
            messages_json: "not json".into(),
        });
        assert!(bad.is_err());
        let bad = start(StartArgs {
            provider: "openai".into(),
            api_key: "".into(),
            model: None,
            system: None,
            messages_json: "[]".into(),
        });
        assert!(bad.is_err());
    }
}
