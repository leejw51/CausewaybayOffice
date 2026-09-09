//! Live provider checks, gated on XAI_API_KEY / OPENAI_API_KEY (each test
//! prints "skipped" and passes when its key is absent). Reasoning models can
//! take ~20 s before the first text delta, hence the generous timeouts.

mod common;

use std::time::{Duration, Instant};

use cbo_core::*;
use common::*;

const PROMPT: &str =
    "Reply with exactly this Korean sentence and nothing else: 안녕하세요, 세션 이름은 무엇입니까?";

fn start(provider: &str, key: &str, prompt: &str) -> i32 {
    let p = cs(provider);
    let k = cs(key);
    let sys = cs("You are a terse assistant. Never add commentary.");
    let msgs = cs(&serde_json::json!([{"role": "user", "content": prompt}]).to_string());
    let req = unsafe {
        cbo_llm_start(
            p.as_ptr(),
            k.as_ptr(),
            std::ptr::null(),
            sys.as_ptr(),
            msgs.as_ptr(),
        )
    };
    assert!(
        req >= 0,
        "cbo_llm_start({}) failed: {}",
        provider,
        last_error()
    );
    req
}

struct Run {
    state: i32,
    text: String,
    deltas: usize,
    states: Vec<i32>,
}

fn drive(req: i32, timeout: Duration, mut stop_after: Option<usize>) -> Run {
    let t0 = Instant::now();
    let mut run = Run {
        state: LLM_PENDING,
        text: String::new(),
        deltas: 0,
        states: Vec::new(),
    };
    loop {
        let st = cbo_llm_state(req);
        if run.states.last() != Some(&st) {
            run.states.push(st);
        }
        let d = from_c(cbo_llm_take_delta(req));
        if !d.is_empty() {
            run.deltas += 1;
            run.text.push_str(&d);
            if let Some(n) = stop_after {
                if run.deltas >= n {
                    stop_after = None;
                    cbo_llm_cancel(req);
                }
            }
        }
        if st == LLM_DONE || st == LLM_ERROR {
            run.text.push_str(&from_c(cbo_llm_take_delta(req)));
            run.state = st;
            return run;
        }
        assert!(
            t0.elapsed() < timeout,
            "timeout after {:?}; states {:?}, text {:?}",
            timeout,
            run.states,
            run.text
        );
        std::thread::sleep(Duration::from_millis(25));
    }
}

fn has_hangul(s: &str) -> bool {
    s.chars().any(|c| ('\u{AC00}'..='\u{D7A3}').contains(&c))
}

fn streaming(provider: &str) {
    let Some(key) = env_key(provider) else {
        println!("skipped: no API key for {}", provider);
        return;
    };
    let req = start(provider, &key, PROMPT);
    let run = drive(req, Duration::from_secs(120), None);
    println!(
        "[{}] states {:?}, {} deltas: {:?}",
        provider, run.states, run.deltas, run.text
    );
    assert_eq!(
        run.state,
        LLM_DONE,
        "{}: {}",
        provider,
        from_c(cbo_llm_error(req))
    );
    assert!(
        run.states.contains(&LLM_STREAMING),
        "STREAMING must be observed: {:?}",
        run.states
    );
    let pos_s = run.states.iter().position(|&s| s == LLM_STREAMING);
    let pos_d = run.states.iter().position(|&s| s == LLM_DONE);
    assert!(pos_s < pos_d, "STREAMING before DONE: {:?}", run.states);
    assert!(
        has_hangul(&run.text),
        "Korean text expected: {:?}",
        run.text
    );
    assert!(
        run.text.contains("안녕하세요"),
        "greeting intact: {:?}",
        run.text
    );
    assert!(std::str::from_utf8(run.text.as_bytes()).is_ok());
    assert_eq!(from_c(cbo_llm_error(req)), "");
    cbo_llm_free(req);
    assert_eq!(cbo_llm_state(req), LLM_ERROR, "freed id reads as ERROR");
}

fn cancel_mid_stream(provider: &str) {
    let Some(key) = env_key(provider) else {
        println!("skipped: no API key for {}", provider);
        return;
    };
    let req = start(
        provider,
        &key,
        "Count from 1 to 200, one number per line, no other text.",
    );
    let run = drive(req, Duration::from_secs(120), Some(2));
    println!(
        "[{}] cancelled after {} deltas, state {}",
        provider, run.deltas, run.state
    );
    assert_eq!(run.state, LLM_DONE, "cancel settles to DONE");
    assert!(run.deltas >= 2);
    // Nothing more arrives after cancel.
    std::thread::sleep(Duration::from_millis(1500));
    assert_eq!(from_c(cbo_llm_take_delta(req)), "");
    assert!(
        !run.text.contains("\n200"),
        "stream should have been cut short: {:?}",
        run.text
    );
    cbo_llm_free(req);
}

fn bad_key(provider: &str, expect_status: &[&str]) {
    if std::env::var("CBO_LIVE").as_deref() != Ok("1") {
        println!("skipped: set CBO_LIVE=1 for provider checks");
        return;
    }
    if env_key("xai").is_none() && env_key("openai").is_none() && env_key("anthropic").is_none() {
        println!("skipped: no live keys, not exercising the network");
        return;
    }
    let req = start(provider, "sk-invalid-key-for-cbo-tests", "hi");
    let run = drive(req, Duration::from_secs(60), None);
    let err = from_c(cbo_llm_error(req));
    println!("[{}] bad key -> {}", provider, err);
    assert_eq!(run.state, LLM_ERROR);
    assert_eq!(run.text, "");
    assert!(
        expect_status.iter().any(|s| err.starts_with(s)),
        "{}: expected one of {:?}, got {}",
        provider,
        expect_status,
        err
    );
    assert!(err.len() > 12, "HTTP body must be included: {}", err);
    cbo_llm_free(req);
}

#[test]
fn xai_streaming() {
    streaming("xai");
}

#[test]
fn openai_streaming() {
    streaming("openai");
}

#[test]
fn xai_cancel_mid_stream() {
    cancel_mid_stream("xai");
}

#[test]
fn openai_cancel_mid_stream() {
    cancel_mid_stream("openai");
}

#[test]
fn xai_bad_key_is_error_with_body() {
    // x.ai answers 400 for a malformed key, 401 for a well-formed unknown one.
    bad_key("xai", &["HTTP 400", "HTTP 401", "HTTP 403"]);
}

#[test]
fn openai_bad_key_is_error_with_body() {
    bad_key("openai", &["HTTP 401"]);
}

#[test]
fn anthropic_bad_key_is_http_401() {
    bad_key("anthropic", &["HTTP 401"]);
}

#[test]
fn anthropic_streaming() {
    streaming("anthropic");
}

#[test]
fn anthropic_cancel_mid_stream() {
    cancel_mid_stream("anthropic");
}
