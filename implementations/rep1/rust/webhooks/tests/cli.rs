//! End-to-end tests that drive the compiled binary through stdin/stdout.

use std::io::Write;
use std::process::{Command, Stdio};

fn run(input: &[u8]) -> (String, i32) {
    let mut child = Command::new(env!("CARGO_BIN_EXE_webhooks"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .expect("spawn");
    child.stdin.take().unwrap().write_all(input).unwrap();
    let out = child.wait_with_output().unwrap();
    (String::from_utf8(out.stdout).unwrap(), out.status.code().unwrap())
}

#[test]
fn spec_examples() {
    let payload = "7b2274657374223a20323433323233323331347d";
    let header = "76312c6730684d395373452b4f54504a5447742f746d494b7453795a6c453375464a454c566c4e494f4c4a314f453d";
    let secret = "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw";
    let id = "msg_p5jXN8AQM9LWM0D4loKWxJek";
    let input = format!(
        "sha256 -\nsign {secret} {id} 1614265330 {payload}\n\
         verify {secret} {id} 1614265330 1614265400 {header} {payload}\n\
         verify {secret} {id} 1614265330 1614265631 {header} {payload}\n\
         verify {secret} {id} 1614265330 1614265400 - {payload}\nsha256 ABCD\n"
    );
    let (out, code) = run(input.as_bytes());
    assert_eq!(code, 0);
    assert_eq!(
        out,
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\n\
         v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=\nok 0 0\nfail timestamp-too-old\n\
         fail missing-signature\nerror\n"
    );
}

#[test]
fn long_lines_and_non_utf8_input() {
    let long = format!("sha256 {}\n", "ab".repeat(32 * 1024));
    let (out, code) = run(long.as_bytes());
    assert_eq!(code, 0);
    assert_eq!(out.trim_end().len(), 64);

    let (out, code) = run(b"sha256 \xff\xfe\nsha256 -");
    assert_eq!(code, 0);
    assert_eq!(out.lines().next(), Some("error"));
    assert_eq!(out.lines().count(), 2);
}

#[test]
fn empty_input_gives_empty_output() {
    assert_eq!(run(b""), (String::new(), 0));
}
