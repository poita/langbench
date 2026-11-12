//! Tests of the command-line contract: `kiln <input dir> <output dir>`.

use std::fs;
use std::path::PathBuf;
use std::process::Command;

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("kiln-cli-{name}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
}

#[test]
fn writes_log_and_workspace() {
    let root = scratch("ok");
    let input = root.join("in");
    let output = root.join("out");
    fs::create_dir_all(input.join("src")).unwrap();
    fs::create_dir_all(&output).unwrap();
    fs::write(input.join("src/a.txt"), "hi\n").unwrap();
    fs::write(
        input.join("main.kiln"),
        "step {\n out \"out/a.txt\"\n in \"src/a.txt\"\n cmd upper()\n}\ndefault \"out/a.txt\"\n",
    )
    .unwrap();
    fs::write(input.join("session.txt"), "build\n").unwrap();

    let status = Command::new(env!("CARGO_BIN_EXE_kiln"))
        .arg(&input)
        .arg(&output)
        .status()
        .unwrap();
    assert!(status.success());
    assert_eq!(
        fs::read_to_string(output.join("log.txt")).unwrap(),
        "step 1: build (default) -j 1\n  run 0 2 w0 out/a.txt upper()\n  ok ran=1 hit=0 time=2\n"
    );
    assert_eq!(fs::read_to_string(output.join("workspace/out/a.txt")).unwrap(), "HI\n");
    assert_eq!(fs::read_to_string(output.join("workspace/src/a.txt")).unwrap(), "hi\n");
    assert!(output.join("workspace/.kiln-state").exists());
    assert!(!output.join("workspace/session.txt").exists());
    let _ = fs::remove_dir_all(root);
}

#[test]
fn build_errors_still_exit_zero() {
    let root = scratch("err");
    let input = root.join("in");
    let output = root.join("out");
    fs::create_dir_all(&input).unwrap();
    fs::create_dir_all(&output).unwrap();
    fs::write(input.join("main.kiln"), "let = 1\n").unwrap();
    fs::write(input.join("session.txt"), "build\n").unwrap();
    let status = Command::new(env!("CARGO_BIN_EXE_kiln"))
        .arg(&input)
        .arg(&output)
        .status()
        .unwrap();
    assert!(status.success());
    assert_eq!(
        fs::read_to_string(output.join("log.txt")).unwrap(),
        "step 1: build (default) -j 1\n  error E_PARSE main.kiln:1\n"
    );
    let _ = fs::remove_dir_all(root);
}

#[test]
fn bad_usage_fails() {
    let status = Command::new(env!("CARGO_BIN_EXE_kiln")).status().unwrap();
    assert!(!status.success());
}
