//! Command-only learning from simple, visibly echoed prompt lines. No raw output.
//! Readiness is decided by the echo, not by what the prompt looks like: the
//! typed text must be visible on the cursor line (hidden input such as a
//! password never is). Editing/history/full-screen input invalidates the
//! line rather than guessing.
#[derive(Default)]
pub struct Learning {
    bytes: Vec<u8>,
    prompt: String,
    trusted: bool,
    previous: Option<String>,
    /// Prompt text in front of the last learned command; lets an empty line
    /// count as "at the prompt" for prompts that end in an emoji or a word.
    last_prompt: Option<String>,
}
impl Learning {
    const PROMPT_ENDS: &'static [char] =
        &['$', '%', '#', '>', '❯', '➜', '»', 'λ', '›', '→', '❱', '▶'];
    fn prompt(line: &str) -> bool {
        let line = line.trim_end();
        !line.is_empty()
            && line
                .chars()
                .last()
                .is_some_and(|c| Self::PROMPT_ENDS.contains(&c))
    }
    /// The prompt part of `line` when the typed text is echoed at its end.
    fn echoed_prompt<'a>(line: &'a str, typed: &str) -> Option<&'a str> {
        let line = line.trim_end();
        line.strip_suffix(typed)
    }
    pub fn ready(&self, line: Option<&str>) -> bool {
        let Some(line) = line else {
            return false;
        };
        let line = line.trim_end();
        if self.bytes.is_empty() {
            return Self::prompt(line)
                || self
                    .last_prompt
                    .as_deref()
                    .is_some_and(|p| !p.trim().is_empty() && p.trim_end() == line);
        }
        if !self.trusted {
            return false;
        }
        let Ok(typed) = std::str::from_utf8(&self.bytes) else {
            return false;
        };
        let typed = typed.trim_end();
        if typed.is_empty() {
            return false;
        }
        let prompt = self.prompt.trim_end();
        let full = format!("{}{}", self.prompt, typed);
        let full = full.trim_end();
        // The text in front of the echo. A trailing '?' is a yes/no question
        // ("remove x? y"), not a shell prompt.
        // exact echo, or the echo still catching up (some of it on screen,
        // nothing else changed)
        let caught_up = line == full || (full.starts_with(line) && line.len() > prompt.len());
        let before = if caught_up {
            Some(prompt)
        } else if let Some(before) = Self::echoed_prompt(line, typed) {
            Some(before) // prompt captured late or redrawn: the typed text sits at the cursor
        } else if !line.is_empty() && typed.ends_with(line) && line.len() < typed.len() {
            Some("") // a long command wrapped: the cursor row holds the tail of it
        } else {
            None
        };
        before.is_some_and(|b| !b.trim_end().ends_with('?'))
    }
    pub fn typing(&self) -> String {
        String::from_utf8(self.bytes.clone()).unwrap_or_default()
    }
    pub fn feed(&mut self, input: &[u8], line: Option<&str>) -> Vec<(String, Option<String>)> {
        let mut done = Vec::new();
        if self.bytes.is_empty() {
            self.trusted = line.is_some();
            self.prompt = line.unwrap_or("").to_string();
        }
        for &byte in input {
            match byte {
                b'\r' | b'\n' => {
                    if self.ready(line) && !self.bytes.is_empty() {
                        let cmd = self.typing();
                        let trimmed = cmd.trim_end().to_string();
                        self.last_prompt = Some(
                            line.and_then(|l| Self::echoed_prompt(l, &trimmed))
                                .map(str::to_string)
                                .unwrap_or_else(|| self.prompt.clone()),
                        );
                        let prev = self.previous.replace(cmd.clone());
                        done.push((cmd, prev));
                    }
                    self.bytes.clear();
                    self.trusted = false;
                }
                8 | 127 => {
                    while let Some(b) = self.bytes.pop() {
                        if b & 0xc0 != 0x80 {
                            break;
                        }
                    }
                }
                3 | 21 => {
                    self.bytes.clear();
                    self.trusted = false;
                }
                0..=31 => {
                    self.trusted = false;
                }
                _ => {
                    if self.bytes.len() < 4096 {
                        self.bytes.push(byte);
                    } else {
                        self.trusted = false;
                    }
                }
            }
        }
        done
    }
}
pub fn on_input(sess: &crate::session::Session, bytes: &[u8]) {
    let line = crate::session::lock(&sess.term).prompt_line();
    let completed = crate::session::lock(&sess.learning).feed(bytes, line.as_deref());
    if !crate::record::enabled_cached() {
        for (cmd, prev) in completed {
            crate::record::learn_command(
                sess.host_id.load(std::sync::atomic::Ordering::Relaxed),
                cmd,
                prev,
            );
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn learns_echoed_commands_and_sequences_but_not_hidden_input() {
        let mut l = Learning::default();
        assert!(l.feed(b"ls", Some("u@host $ ")).is_empty());
        assert!(l.ready(Some("u@host $ ls")));
        assert_eq!(
            l.feed(b"\r", Some("u@host $ ls")),
            vec![("ls".into(), None)]
        );
        l.feed(b"pwd", Some("u@host $ "));
        assert_eq!(
            l.feed(b"\r", Some("u@host $ pwd")),
            vec![("pwd".into(), Some("ls".into()))]
        );
        l.feed(b"secret", Some("Password: "));
        assert!(!l.ready(Some("Password: ")));
        assert!(l.feed(b"\r", Some("Password: ")).is_empty());
        l.feed(b"hidden", Some("$ "));
        assert!(l.feed(b"\r", Some("$ ")).is_empty());
    }
    #[test]
    fn rejects_ambiguous_edits_and_fullscreen_input() {
        let mut l = Learning::default();
        l.feed(b"echo hi", Some("$ "));
        l.feed(b"\x1b[D", Some("$ echo hi"));
        assert!(l.feed(b"\r", Some("$ echo hi")).is_empty());
        l.feed(b"secret", None);
        assert!(l.feed(b"\r", None).is_empty());
    }
    #[test]
    fn any_prompt_shape_works_when_the_input_is_echoed() {
        // emoji / word prompts (PS1="🍎 ", starship "❯") never end in $ % # >
        let mut l = Learning::default();
        assert!(!l.ready(Some("🍎 ")));
        l.feed(b"ls", Some("🍎 "));
        assert!(l.ready(Some("🍎 ls")));
        assert_eq!(l.feed(b"\r", Some("🍎 ls")), vec![("ls".into(), None)]);
        // once a command was learned there, the empty line counts as the prompt
        assert!(l.ready(Some("🍎 ")));
        assert!(!l.ready(Some("Password: ")));
        let mut s = Learning::default();
        s.feed(b"git status", Some("~/repo on main ❯ "));
        assert!(s.ready(Some("~/repo on main ❯ git status")));
        assert!(Learning::default().ready(Some("~/repo on main ❯ ")));
    }
    #[test]
    fn tolerates_echo_lag_and_late_prompts_but_not_questions() {
        let mut l = Learning::default();
        l.feed(b"make check", Some("$ "));
        assert!(l.ready(Some("$ make chec"))); // last byte not echoed yet
        assert!(!l.ready(Some("$ "))); // nothing echoed: hidden
        assert_eq!(
            l.feed(b"\r", Some("$ make chec")),
            vec![("make check".into(), None)]
        );
        // typed before the new prompt was drawn: the captured "prompt" is stale
        let mut late = Learning::default();
        late.feed(b"ls", Some("total 12"));
        assert!(late.ready(Some("🍎 ls")));
        // a yes/no question echoes too, but is not a command
        let mut q = Learning::default();
        q.feed(b"y", Some("remove file.txt? "));
        assert!(!q.ready(Some("remove file.txt? y")));
        assert!(q.feed(b"\r", Some("remove file.txt? y")).is_empty());
        // a wrapped command: the cursor row holds only the tail
        let mut w = Learning::default();
        w.feed(b"echo 0123456789", Some("$ "));
        assert!(w.ready(Some("3456789")));
    }
}
