use std::io::Write;
use std::process::{Command, Stdio};
#[test]
fn bash_and_zsh_report_cwd_without_prompt_customization() {
    let root = std::env::temp_dir().join(format!("cbo-shell-{}", std::process::id()));
    std::fs::create_dir_all(root.join("space ' %25 한글")).unwrap();
    for shell in ["/bin/bash", "/bin/zsh"] {
        if !std::path::Path::new(shell).exists() {
            continue;
        }
        let mut child = Command::new("/bin/sh")
            .arg("-c")
            .arg(include_str!("../src/shell_init.sh"))
            .env("HOME", &root)
            .env("SHELL", shell)
            .env_remove("ZDOTDIR")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all("PS1='work> '\ncd \"$HOME/space ' %25 한글\"\nexit\n".as_bytes())
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(
            output.status.success(),
            "{shell}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        let mut term = cbo_core::term::Term::new(100, 24);
        term.process(&output.stdout);
        assert_eq!(
            term.cwd(),
            root.join("space ' %25 한글").to_str().unwrap(),
            "{shell}: {} {}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }
}
