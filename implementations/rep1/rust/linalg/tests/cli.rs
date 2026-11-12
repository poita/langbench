//! End-to-end tests: run the real binary on a scratch input directory.

use std::fs;
use std::path::PathBuf;
use std::process::Command;

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("linalg-test-{}-{}", name, std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(dir.join("in")).unwrap();
    fs::create_dir_all(dir.join("out")).unwrap();
    dir
}

fn run(dir: &PathBuf) -> std::process::ExitStatus {
    Command::new(env!("CARGO_BIN_EXE_linalg"))
        .arg(dir.join("in"))
        .arg(dir.join("out"))
        .status()
        .unwrap()
}

fn listing(dir: &PathBuf) -> Vec<String> {
    let mut names: Vec<String> = fs::read_dir(dir.join("out"))
        .unwrap()
        .map(|e| e.unwrap().file_name().into_string().unwrap())
        .collect();
    names.sort();
    names
}

#[test]
fn spec_worked_example() {
    let dir = scratch("example");
    let input = dir.join("in");
    fs::write(input.join("commands.txt"), "# a two by two example\nadd a.mtx b.mtx\n\ndet a.mtx\nchol s.mtx\n").unwrap();
    fs::write(input.join("a.mtx"), "%%MatrixMarket matrix array real general\n2 2\n1.0\n3.0\n2.0\n4.0\n").unwrap();
    fs::write(input.join("b.mtx"), "%%MatrixMarket matrix coordinate real general\n2 2 2\n1 1 0.5\n2 2 -1.5\n").unwrap();
    fs::write(input.join("s.mtx"), "%%MatrixMarket matrix array real symmetric\n2 2\n4.0\n2.0\n5.0\n").unwrap();
    assert!(run(&dir).success());
    assert_eq!(listing(&dir), ["001_add.mtx", "002_det.mtx", "003_chol_L.mtx"]);
    let out = dir.join("out");
    assert_eq!(
        fs::read_to_string(out.join("001_add.mtx")).unwrap(),
        "%%MatrixMarket matrix array real general\n2 2\n1.5000000000e+00\n3.0000000000e+00\n2.0000000000e+00\n2.5000000000e+00\n"
    );
    let det = fs::read_to_string(out.join("002_det.mtx")).unwrap();
    assert_eq!(det, "%%MatrixMarket matrix array real general\n1 1\n-2.0000000000e+00\n");
    assert_eq!(
        fs::read_to_string(out.join("003_chol_L.mtx")).unwrap(),
        "%%MatrixMarket matrix array real general\n2 2\n2.0000000000e+00\n1.0000000000e+00\n0.0000000000e+00\n2.0000000000e+00\n"
    );
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn errors_replace_result_files() {
    let dir = scratch("errors");
    let input = dir.join("in");
    fs::write(input.join("commands.txt"), "chol r.mtx\nsolve r.mtx c.mtx\nlu s.mtx\nnorm1 r.mtx\n").unwrap();
    fs::write(input.join("r.mtx"), "%%MatrixMarket matrix array real general\n2 3\n1\n2\n3\n4\n5\n6\n").unwrap();
    fs::write(input.join("c.mtx"), "%%MatrixMarket matrix array real general\n3 1\n1\n2\n3\n").unwrap();
    fs::write(input.join("s.mtx"), "%%MatrixMarket matrix array real general\n2 2\n1\n2\n2\n4\n").unwrap();
    assert!(run(&dir).success());
    assert_eq!(listing(&dir), ["001_error.txt", "002_error.txt", "003_error.txt", "004_norm1.mtx"]);
    let out = dir.join("out");
    assert_eq!(fs::read_to_string(out.join("001_error.txt")).unwrap(), "not_square\n");
    assert_eq!(fs::read_to_string(out.join("002_error.txt")).unwrap(), "not_square\n");
    assert_eq!(fs::read_to_string(out.join("003_error.txt")).unwrap(), "singular\n");
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn eig_and_svd_outputs() {
    let dir = scratch("decomp");
    let input = dir.join("in");
    fs::write(input.join("commands.txt"), "eig a.mtx\nsvd a.mtx\n").unwrap();
    fs::write(input.join("a.mtx"), "%%MatrixMarket matrix array real symmetric\n2 2\n2\n1\n3\n").unwrap();
    assert!(run(&dir).success());
    assert_eq!(
        listing(&dir),
        ["001_eig_V.mtx", "001_eig_w.mtx", "002_svd_S.mtx", "002_svd_U.mtx", "002_svd_V.mtx"]
    );
    let w = fs::read_to_string(dir.join("out/001_eig_w.mtx")).unwrap();
    assert!(w.contains("1.3819660113e+00\n3.6180339887e+00\n"), "{w}");
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn wrong_usage_fails() {
    let status = Command::new(env!("CARGO_BIN_EXE_linalg")).status().unwrap();
    assert!(!status.success());
}
