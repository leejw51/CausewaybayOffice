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

/// A streamed function call, complete once the stream ends.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ToolCall {
    pub index: usize,
    pub id: String,
    pub name: String,
    /// JSON text of the arguments (fragments concatenated; "{}" when empty).
    pub arguments: String,
}

impl ToolCall {
    pub fn to_json(&self) -> Value {
        json!({
            "id": self.id,
            "name": self.name,
            "arguments": if self.arguments.trim().is_empty() { "{}".to_string() } else { self.arguments.clone() },
        })
    }
}

/// One fragment of a streamed function call. `id`/`name` arrive on the first
/// fragment of a call; `arguments` fragments concatenate into JSON text.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ToolDelta {
    pub index: usize,
    pub id: Option<String>,
    pub name: Option<String>,
    pub arguments: String,
}

/// The neutral tool shape the UI sends: [{name, description, parameters}]
/// (parameters = JSON schema object, optional). Converted per provider.
fn tools_for(provider: Provider, tools: Option<&Value>) -> Option<Vec<Value>> {
    let list = tools?.as_array()?;
    let out: Vec<Value> = list
        .iter()
        .filter_map(|t| {
            let name = t.get("name")?.as_str()?.trim();
            if name.is_empty() {
                return None;
            }
            let description = t
                .get("description")
                .and_then(|d| d.as_str())
                .unwrap_or("")
                .to_string();
            let schema = t
                .get("parameters")
                .filter(|p| p.is_object())
                .cloned()
                .unwrap_or_else(|| json!({"type": "object", "properties": {}}));
            Some(match provider {
                Provider::Anthropic => json!({
                    "name": name, "description": description, "input_schema": schema,
                }),
                Provider::OpenAi | Provider::Xai => json!({
                    "type": "function",
                    "function": {"name": name, "description": description, "parameters": schema},
                }),
            })
        })
        .collect();
    if out.is_empty() {
        None
    } else {
        Some(out)
    }
}

/// Arguments as a JSON object for Anthropic `tool_use` blocks (a string is parsed).
fn args_object(v: Option<&Value>) -> Value {
    match v {
        Some(Value::String(s)) => serde_json::from_str::<Value>(s)
            .ok()
            .filter(|p| p.is_object())
            .unwrap_or_else(|| json!({})),
        Some(o) if o.is_object() => o.clone(),
        _ => json!({}),
    }
}

/// Arguments as JSON text for OpenAI-style `function.arguments`.
fn args_text(v: Option<&Value>) -> String {
    match v {
        Some(Value::String(s)) if !s.trim().is_empty() => s.clone(),
        Some(o) if o.is_object() => o.to_string(),
        _ => "{}".to_string(),
    }
}

/// Convert the neutral message list into the provider's wire shape.
///
/// Neutral messages: `{role: user|assistant, content}`; an assistant message
/// may carry `tool_calls: [{id, name, arguments}]`; a tool result is
/// `{role: "tool", tool_call_id, name?, content}`. Anthropic needs every
/// result of one assistant turn in a single following user message, so
/// consecutive tool results merge into one message there.
pub fn normalize_messages(provider: Provider, messages: &Value) -> Vec<Value> {
    let mut out: Vec<Value> = Vec::new();
    let Some(list) = messages.as_array() else {
        return out;
    };
    for m in list {
        let role = m.get("role").and_then(|r| r.as_str()).unwrap_or("user");
        let content = m.get("content").and_then(|c| c.as_str()).unwrap_or("");
        let calls = m.get("tool_calls").and_then(|c| c.as_array());
        match (provider, role) {
            (_, "assistant") if calls.is_some_and(|c| !c.is_empty()) => {
                let calls = calls.unwrap_or(&Vec::new()).clone();
                match provider {
                    Provider::Anthropic => {
                        let mut blocks = Vec::new();
                        if !content.is_empty() {
                            blocks.push(json!({"type": "text", "text": content}));
                        }
                        for c in &calls {
                            blocks.push(json!({
                                "type": "tool_use",
                                "id": c.get("id").and_then(|i| i.as_str()).unwrap_or(""),
                                "name": c.get("name").and_then(|n| n.as_str()).unwrap_or(""),
                                "input": args_object(c.get("arguments")),
                            }));
                        }
                        out.push(json!({"role": "assistant", "content": blocks}));
                    }
                    Provider::OpenAi | Provider::Xai => {
                        let tool_calls: Vec<Value> = calls
                            .iter()
                            .map(|c| {
                                json!({
                                    "id": c.get("id").and_then(|i| i.as_str()).unwrap_or(""),
                                    "type": "function",
                                    "function": {
                                        "name": c.get("name").and_then(|n| n.as_str()).unwrap_or(""),
                                        "arguments": args_text(c.get("arguments")),
                                    },
                                })
                            })
                            .collect();
                        let mut msg = json!({"role": "assistant", "tool_calls": tool_calls});
                        msg["content"] = if content.is_empty() {
                            Value::Null
                        } else {
                            Value::String(content.to_string())
                        };
                        out.push(msg);
                    }
                }
            }
            (Provider::Anthropic, "tool") => {
                let block = json!({
                    "type": "tool_result",
                    "tool_use_id": m.get("tool_call_id").and_then(|i| i.as_str()).unwrap_or(""),
                    "content": content,
                });
                let merged = out.last_mut().filter(|last| {
                    last.get("role").and_then(|r| r.as_str()) == Some("user")
                        && last
                            .get("content")
                            .and_then(|c| c.as_array())
                            .and_then(|a| a.first())
                            .and_then(|b| b.get("type"))
                            .and_then(|t| t.as_str())
                            == Some("tool_result")
                });
                match merged
                    .and_then(|last| last.get_mut("content"))
                    .and_then(|c| c.as_array_mut())
                {
                    Some(arr) => arr.push(block),
                    None => out.push(json!({"role": "user", "content": [block]})),
                }
            }
            (Provider::OpenAi | Provider::Xai, "tool") => {
                out.push(json!({
                    "role": "tool",
                    "tool_call_id": m.get("tool_call_id").and_then(|i| i.as_str()).unwrap_or(""),
                    "content": content,
                }));
            }
            _ => out.push(json!({"role": role, "content": content})),
        }
    }
    out
}

/// Build the JSON request body for a provider.
pub fn build_body(
    provider: Provider,
    model: &str,
    system: Option<&str>,
    messages: &Value,
) -> Value {
    build_body_tools(provider, model, system, messages, None)
}

/// `build_body` with an optional neutral tool list.
pub fn build_body_tools(
    provider: Provider,
    model: &str,
    system: Option<&str>,
    messages: &Value,
    tools: Option<&Value>,
) -> Value {
    let messages = normalize_messages(provider, messages);
    let tools = tools_for(provider, tools);
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
            if let Some(t) = tools {
                body["tools"] = Value::Array(t);
            }
            body
        }
        Provider::OpenAi | Provider::Xai => {
            let mut all = Vec::new();
            if let Some(sys) = system.filter(|s| !s.is_empty()) {
                all.push(json!({"role": "system", "content": sys}));
            }
            all.extend(messages);
            let mut body = json!({
                "model": model,
                "stream": true,
                "messages": all,
            });
            if let Some(t) = tools {
                body["tools"] = Value::Array(t);
            }
            body
        }
    }
}

/// One parsed SSE `data:` payload.
#[derive(Debug, PartialEq, Eq)]
pub enum SseEvent {
    /// Nothing interesting (comment, empty, keepalive, non-text delta).
    Nothing,
    Text(String),
    /// Function-call fragments (OpenAI `tool_calls` deltas, Anthropic
    /// `tool_use` blocks and `input_json_delta`s).
    Tools(Vec<ToolDelta>),
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
            let delta = choice.and_then(|c| c.get("delta"));
            if let Some(text) = delta
                .and_then(|d| d.get("content"))
                .and_then(|c| c.as_str())
            {
                if !text.is_empty() {
                    return SseEvent::Text(text.to_string());
                }
            }
            if let Some(calls) = delta
                .and_then(|d| d.get("tool_calls"))
                .and_then(|t| t.as_array())
            {
                let deltas: Vec<ToolDelta> = calls
                    .iter()
                    .enumerate()
                    .map(|(i, c)| {
                        let f = c.get("function");
                        ToolDelta {
                            index: c
                                .get("index")
                                .and_then(|x| x.as_u64())
                                .map(|x| x as usize)
                                .unwrap_or(i),
                            id: c
                                .get("id")
                                .and_then(|x| x.as_str())
                                .filter(|x| !x.is_empty())
                                .map(str::to_string),
                            name: f
                                .and_then(|f| f.get("name"))
                                .and_then(|x| x.as_str())
                                .filter(|x| !x.is_empty())
                                .map(str::to_string),
                            arguments: f
                                .and_then(|f| f.get("arguments"))
                                .and_then(|x| x.as_str())
                                .unwrap_or("")
                                .to_string(),
                        }
                    })
                    .collect();
                if !deltas.is_empty() {
                    return SseEvent::Tools(deltas);
                }
            }
            SseEvent::Nothing
        }
        Provider::Anthropic => {
            let v: Value = match serde_json::from_str(data) {
                Ok(v) => v,
                Err(_) => return SseEvent::Nothing,
            };
            let index = v
                .get("index")
                .and_then(|i| i.as_u64())
                .map(|i| i as usize)
                .unwrap_or(0);
            match v.get("type").and_then(|t| t.as_str()).unwrap_or("") {
                "content_block_start" => {
                    let block = v.get("content_block");
                    let is_tool = block.and_then(|b| b.get("type")).and_then(|t| t.as_str())
                        == Some("tool_use");
                    if !is_tool {
                        return SseEvent::Nothing;
                    }
                    SseEvent::Tools(vec![ToolDelta {
                        index,
                        id: block
                            .and_then(|b| b.get("id"))
                            .and_then(|x| x.as_str())
                            .map(str::to_string),
                        name: block
                            .and_then(|b| b.get("name"))
                            .and_then(|x| x.as_str())
                            .map(str::to_string),
                        arguments: String::new(),
                    }])
                }
                "content_block_delta" => {
                    let delta = v.get("delta");
                    let kind = delta
                        .and_then(|d| d.get("type"))
                        .and_then(|t| t.as_str())
                        .unwrap_or("");
                    if kind == "text_delta" {
                        if let Some(t) = delta.and_then(|d| d.get("text")).and_then(|t| t.as_str())
                        {
                            return SseEvent::Text(t.to_string());
                        }
                    } else if kind == "input_json_delta" {
                        if let Some(p) = delta
                            .and_then(|d| d.get("partial_json"))
                            .and_then(|t| t.as_str())
                        {
                            return SseEvent::Tools(vec![ToolDelta {
                                index,
                                id: None,
                                name: None,
                                arguments: p.to_string(),
                            }]);
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
    /// Function calls assembled from the stream, in call order.
    pub calls: Mutex<Vec<ToolCall>>,
}

impl LlmReq {
    fn new() -> Self {
        LlmReq {
            state: AtomicI32::new(LLM_PENDING),
            cancel: AtomicBool::new(false),
            delta: Mutex::new(String::new()),
            error: Mutex::new(String::new()),
            calls: Mutex::new(Vec::new()),
        }
    }

    /// Fold a stream fragment into the call list (keyed by stream index).
    pub fn push_tool_delta(&self, d: ToolDelta) {
        let mut calls = lock(&self.calls);
        let call = match calls.iter_mut().find(|c| c.index == d.index) {
            Some(c) => c,
            None => {
                calls.push(ToolCall {
                    index: d.index,
                    ..ToolCall::default()
                });
                calls.last_mut().expect("just pushed")
            }
        };
        if let Some(id) = d.id {
            call.id = id;
        }
        if let Some(name) = d.name {
            call.name = name;
        }
        call.arguments.push_str(&d.arguments);
    }

    /// The assembled calls as JSON `[{id, name, arguments}]` (meaningful once DONE).
    pub fn calls_json(&self) -> String {
        let calls = lock(&self.calls);
        Value::Array(
            calls
                .iter()
                .filter(|c| !c.name.is_empty())
                .map(ToolCall::to_json)
                .collect(),
        )
        .to_string()
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
    /// Neutral tool list JSON (see `normalize_messages`); None = no tools.
    pub tools_json: Option<String>,
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
    let tools = match args.tools_json.as_deref().filter(|t| !t.trim().is_empty()) {
        Some(t) => Some(
            serde_json::from_str::<Value>(t)
                .map_err(|e| format!("tools_json is not valid JSON: {}", e))?,
        ),
        None => None,
    };
    if tools.as_ref().is_some_and(|t| !t.is_array()) {
        return Err("tools_json must be a JSON array".into());
    }
    let body = build_body_tools(
        provider,
        &model,
        args.system.as_deref(),
        &messages,
        tools.as_ref(),
    );

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
            SseEvent::Tools(deltas) => {
                for d in deltas {
                    received = received.saturating_add(d.arguments.len());
                    if received > MAX_STREAM_BYTES {
                        return Err("response exceeded size limit".into());
                    }
                    req.push_tool_delta(d);
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
                SseEvent::Tools(_) | SseEvent::Nothing => {}
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
            tools_json: None,
        });
        assert!(bad.is_err());
        let bad = start(StartArgs {
            provider: "openai".into(),
            api_key: "".into(),
            model: None,
            system: None,
            messages_json: "[]".into(),
            tools_json: None,
        });
        assert!(bad.is_err());
    }

    const OPENAI_TOOL_STREAM: &str = concat!(
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"read_screen\",\"arguments\":\"\"}}]}}]}\n",
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{\\\"li\"}}]}}]}\n",
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"nes\\\":5}\"}}]}}]}\n",
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":1,\"id\":\"call_2\",\"function\":{\"name\":\"save_note\",\"arguments\":\"{}\"}}]}}]}\n",
        "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n",
        "data: [DONE]\n",
    );

    const ANTHROPIC_TOOL_STREAM: &str = concat!(
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n",
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Looking.\"}}\n",
        "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"read_screen\",\"input\":{}}}\n",
        "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"lines\\\":\"}}\n",
        "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"5}\"}}\n",
        "data: {\"type\":\"content_block_stop\",\"index\":1}\n",
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"}}\n",
        "data: {\"type\":\"message_stop\"}\n",
    );

    fn assemble(provider: Provider, stream: &str) -> (String, Vec<ToolCall>) {
        let req = LlmReq::new();
        let mut text = String::new();
        for line in stream.lines() {
            match parse_sse_line(provider, line) {
                SseEvent::Text(t) => text.push_str(&t),
                SseEvent::Tools(ds) => {
                    for d in ds {
                        req.push_tool_delta(d);
                    }
                }
                SseEvent::Done => break,
                SseEvent::Error(e) => panic!("{}", e),
                SseEvent::Nothing => {}
            }
        }
        let calls = lock(&req.calls).clone();
        assert_eq!(
            serde_json::from_str::<Value>(&req.calls_json())
                .unwrap()
                .as_array()
                .map(|a| a.len()),
            Some(calls.len())
        );
        (text, calls)
    }

    #[test]
    fn openai_tool_calls_assemble_by_index() {
        let (text, calls) = assemble(Provider::OpenAi, OPENAI_TOOL_STREAM);
        assert_eq!(text, "");
        assert_eq!(calls.len(), 2);
        assert_eq!(calls[0].id, "call_1");
        assert_eq!(calls[0].name, "read_screen");
        assert_eq!(calls[0].arguments, "{\"lines\":5}");
        assert_eq!(calls[1].name, "save_note");
        assert_eq!(calls[1].to_json()["arguments"], "{}");
    }

    #[test]
    fn anthropic_tool_use_assembles() {
        let (text, calls) = assemble(Provider::Anthropic, ANTHROPIC_TOOL_STREAM);
        assert_eq!(text, "Looking.");
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0].id, "toolu_1");
        assert_eq!(calls[0].name, "read_screen");
        assert_eq!(calls[0].arguments, "{\"lines\":5}");
    }

    #[test]
    fn tools_and_results_follow_provider_shape() {
        let tools = json!([
            {"name": "read_screen", "description": "screen text",
             "parameters": {"type": "object", "properties": {"lines": {"type": "integer"}}}},
            {"name": "", "description": "dropped"},
        ]);
        let msgs = json!([
            {"role": "user", "content": "what is on screen?"},
            {"role": "assistant", "content": "", "tool_calls": [
                {"id": "c1", "name": "read_screen", "arguments": "{\"lines\":5}"}]},
            {"role": "tool", "tool_call_id": "c1", "name": "read_screen", "content": "$ ls"},
            {"role": "tool", "tool_call_id": "c2", "name": "x", "content": "y"},
            {"role": "assistant", "content": "It shows ls."},
        ]);
        let o = build_body_tools(Provider::OpenAi, "gpt-5", None, &msgs, Some(&tools));
        let ot = o["tools"].as_array().unwrap();
        assert_eq!(ot.len(), 1);
        assert_eq!(ot[0]["type"], "function");
        assert_eq!(ot[0]["function"]["name"], "read_screen");
        let om = o["messages"].as_array().unwrap();
        assert_eq!(om.len(), 5);
        assert_eq!(
            om[1]["tool_calls"][0]["function"]["arguments"],
            "{\"lines\":5}"
        );
        assert!(om[1]["content"].is_null());
        assert_eq!(om[2]["role"], "tool");
        assert_eq!(om[2]["tool_call_id"], "c1");

        let a = build_body_tools(
            Provider::Anthropic,
            "claude-opus-5",
            None,
            &msgs,
            Some(&tools),
        );
        let at = a["tools"].as_array().unwrap();
        assert_eq!(at[0]["input_schema"]["type"], "object");
        let am = a["messages"].as_array().unwrap();
        // user, assistant(tool_use), user(two tool_results merged), assistant
        assert_eq!(am.len(), 4);
        assert_eq!(am[1]["content"][0]["type"], "tool_use");
        assert_eq!(am[1]["content"][0]["input"]["lines"], 5);
        assert_eq!(am[2]["role"], "user");
        assert_eq!(am[2]["content"].as_array().map(|c| c.len()), Some(2));
        assert_eq!(am[2]["content"][0]["type"], "tool_result");
        assert_eq!(am[2]["content"][1]["tool_use_id"], "c2");
        assert_eq!(am[3]["content"], "It shows ls.");

        // no tools: bodies stay exactly as before
        let plain = build_body(
            Provider::OpenAi,
            "gpt-5",
            None,
            &json!([{"role":"user","content":"hi"}]),
        );
        assert!(plain.get("tools").is_none());
    }
}
