//! Tests for the command-line tool.

mod common;

use common::*;
use sqlitefile::Value;
use std::fs;
use std::process::Command;

fn scratch(name: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("sqlitefile-test-{}-{name}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
}

#[test]
fn writes_one_numbered_file_per_query() {
    let root = scratch("cli");
    let (input, output) = (root.join("in"), root.join("out"));
    fs::create_dir_all(&input).unwrap();
    fs::create_dir_all(&output).unwrap();

    let mut b = DbBuilder::new(1024);
    let t = b.table(&[(1, record(&[Value::Null, text("a")])), (2, record(&[Value::Null, text("b")]))], 10);
    b.schema_row("table", "t", "t", t, Some("CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT)"));
    fs::write(input.join("db.sqlite"), b.finish()).unwrap();
    // No trailing newline on the last line.
    fs::write(input.join("queries.txt"), ".tables\nSELECT * FROM t WHERE v = 'zz'\nSELECT * FROM t\nbad query").unwrap();

    let status = Command::new(env!("CARGO_BIN_EXE_sqlitefile"))
        .arg(&input)
        .arg(&output)
        .status()
        .unwrap();
    assert!(status.success());

    let mut names: Vec<String> = fs::read_dir(&output)
        .unwrap()
        .map(|e| e.unwrap().file_name().into_string().unwrap())
        .collect();
    names.sort();
    assert_eq!(names, ["001.txt", "002.txt", "003.txt", "004.txt"]);
    assert_eq!(fs::read_to_string(output.join("001.txt")).unwrap(), "t\n");
    assert_eq!(fs::read(output.join("002.txt")).unwrap(), b"");
    assert_eq!(fs::read_to_string(output.join("003.txt")).unwrap(), "1\ta\n2\tb\n");
    assert_eq!(fs::read_to_string(output.join("004.txt")).unwrap(), "error\n");
    let _ = fs::remove_dir_all(&root);
}

#[test]
fn usage_error_without_arguments() {
    let status = Command::new(env!("CARGO_BIN_EXE_sqlitefile")).status().unwrap();
    assert!(!status.success());
}
