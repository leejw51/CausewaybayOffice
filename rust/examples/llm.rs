//! Live LLM streaming check through the C ABI.
//! `cargo run --release --example llm [provider] [prompt]`
//! Uses XAI_API_KEY / OPENAI_API_KEY / ANTHROPIC_API_KEY from the environment.

use std::ffi::{CStr, CString};
use std::io::Write;
use std::time::{Duration, Instant};

use cbo_core::*;

fn main() {
    cbo_init();
    let args: Vec<String> = std::env::args().collect();
    let provider = args.get(1).cloned().unwrap_or_else(|| "xai".into());
    let prompt = args
        .get(2)
        .cloned()
        .unwrap_or_else(|| "say hi in Korean".into());

    let key = match provider.as_str() {
        "openai" => std::env::var("OPENAI_API_KEY"),
        "anthropic" => std::env::var("ANTHROPIC_API_KEY"),
        _ => std::env::var("XAI_API_KEY").or_else(|_| std::env::var("GROK_API_KEY")),
    };
    let Ok(key) = key else {
        println!("SKIP: no API key for {}", provider);
        return;
    };

    let messages = serde_json::json!([{"role": "user", "content": prompt}]).to_string();
    let cprov = CString::new(provider.clone()).unwrap_or_default();
    let ckey = CString::new(key).unwrap_or_default();
    let csys = CString::new("You are a terse assistant.").unwrap_or_default();
    let cmsg = CString::new(messages).unwrap_or_default();

    let req = unsafe {
        cbo_llm_start(
            cprov.as_ptr(),
            ckey.as_ptr(),
            std::ptr::null(),
            csys.as_ptr(),
            cmsg.as_ptr(),
        )
    };
    assert!(req >= 0, "start failed: {}", unsafe {
        CStr::from_ptr(cbo_last_error()).to_string_lossy()
    });
    println!("[{}] request {} started, streaming:", provider, req);

    let start = Instant::now();
    let mut full = String::new();
    let mut state;
    loop {
        state = cbo_llm_state(req);
        let delta = unsafe { CStr::from_ptr(cbo_llm_take_delta(req)) }
            .to_string_lossy()
            .to_string();
        if !delta.is_empty() {
            print!("{}", delta);
            let _ = std::io::stdout().flush();
            full.push_str(&delta);
        }
        if state == 2 || state == 3 {
            // Drain anything that landed between the state read and the take.
            let tail = unsafe { CStr::from_ptr(cbo_llm_take_delta(req)) }
                .to_string_lossy()
                .to_string();
            print!("{}", tail);
            full.push_str(&tail);
            break;
        }
        if start.elapsed() > Duration::from_secs(120) {
            cbo_llm_cancel(req);
            panic!("timeout");
        }
        std::thread::sleep(Duration::from_millis(30));
    }
    println!();
    if state == 3 {
        let err = unsafe { CStr::from_ptr(cbo_llm_error(req)) }.to_string_lossy();
        cbo_llm_free(req);
        panic!("LLM ERROR: {}", err);
    }
    cbo_llm_free(req);
    println!(
        "[{}] DONE in {:.1}s, {} chars",
        provider,
        start.elapsed().as_secs_f32(),
        full.chars().count()
    );
    assert!(!full.trim().is_empty(), "empty response");
    println!("LLM PASS");
}
