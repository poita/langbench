mod common;

use std::fs;
use std::process::Command;

use common::*;

#[test]
fn cli_writes_one_numbered_file_per_command() {
    let r = TestRepo::new();
    let blob = r.blob("one file\n");
    let tree = r.tree(&[("100644", b"only.txt", blob)]);
    let c = r.commit(tree, &[], 7, "Only commit");
    r.set_ref("refs/heads/main", &c);

    let input = r.root.with_extension("input");
    let output = r.root.with_extension("output");
    let _ = fs::remove_dir_all(&input);
    let _ = fs::remove_dir_all(&output);
    fs::create_dir_all(&input).unwrap();
    fs::rename(&r.root, input.join("repo")).unwrap();
    // No trailing newline on the last line; a bad command in the middle.
    fs::write(input.join("commands.txt"), "rev-parse main\nbogus\nrev-parse  main\nls-tree main").unwrap();

    let status = Command::new(env!("CARGO_BIN_EXE_gitrepo")).arg(&input).arg(&output).status().unwrap();
    assert!(status.success());
    let read = |n: &str| fs::read_to_string(output.join(n)).unwrap();
    assert_eq!(read("001.out"), format!("{c}\n"));
    assert_eq!(read("002.out"), "error\n");
    assert_eq!(read("003.out"), "error\n");
    assert_eq!(read("004.out"), format!("100644 blob {blob}\tonly.txt\n"));
    assert_eq!(fs::read_dir(&output).unwrap().count(), 4);

    // Put the repository back so `TestRepo` can clean up after itself.
    fs::rename(input.join("repo"), &r.root).unwrap();
    let _ = fs::remove_dir_all(&input);
    let _ = fs::remove_dir_all(&output);
}
