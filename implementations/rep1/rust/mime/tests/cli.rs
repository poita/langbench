//! End-to-end tests that run the `mime` binary on small mailboxes.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("mime-test-{}-{}", std::process::id(), name));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
}

fn run(input: &Path, out: &Path) {
    let status = Command::new(env!("CARGO_BIN_EXE_mime")).arg(input).arg(out).status().unwrap();
    assert!(status.success());
}

const WORKED_EXAMPLE: &[u8] = b"From nobody Mon Sep  1 00:00:00 2025\n\
Subject: =?utf-8?Q?Caf=C3=A9?= report\n\
From: Ann Example <ann@example.com>\n\
To: bob@example.org, Carl <carl@example.org>\n\
Date: Mon, 1 Sep 2025 12:30:00 +0200\n\
MIME-Version: 1.0\n\
Content-Type: multipart/mixed; boundary=\"X\"\n\
\n\
ignore me\n\
--X\n\
Content-Type: text/plain; charset=iso-8859-1\n\
\n\
caf\xe9\n\
--X\n\
Content-Type: application/octet-stream\n\
Content-Disposition: attachment; filename=\"a.bin\"\n\
Content-Transfer-Encoding: base64\n\
\n\
AAECAw==\n\
--X--\n\
\n";

const EXPECTED_MESSAGE: &str = "[message]
id 0001
source \"mbox:1\"

[headers]
subject: \"Café report\"
from: \"Ann Example <ann@example.com>\"
to: \"bob@example.org, Carl <carl@example.org>\"
date: \"Mon, 1 Sep 2025 12:30:00 +0200\"
mime-version: \"1.0\"
content-type: \"multipart/mixed; boundary=\\\"X\\\"\"

[addresses]
from 0 display=\"Ann Example\" spec=\"ann@example.com\"
to 0 display=\"\" spec=\"bob@example.org\"
to 1 display=\"Carl\" spec=\"carl@example.org\"

[date]
raw \" Mon, 1 Sep 2025 12:30:00 +0200\"
valid yes
utc 2025-09-01T10:30:00Z
offset +0200
epoch 1756722600

[structure]
0 multipart/mixed cte=7bit boundary=\"X\" parts=2 preamble=9 epilogue=0
  1 text/plain charset=iso-8859-1 cte=7bit size=4 adler32=04680214 role=text
  2 application/octet-stream cte=base64 disposition=attachment filename=\"a.bin\" size=4 adler32=000e0007 role=attachment

[body]
text 1 chars 4
| café
html none

[attachments]
2 type=application/octet-stream filename=\"a.bin\" size=4 adler32=000e0007 file=parts/0001/002.bin
";

#[test]
fn worked_example_from_mbox() {
    let dir = scratch("worked");
    let input = dir.join("input");
    let out = dir.join("out");
    fs::write(&input, WORKED_EXAMPLE).unwrap();
    fs::create_dir(&out).unwrap();
    run(&input, &out);

    assert_eq!(
        fs::read_to_string(out.join("summary.txt")).unwrap(),
        "messages 1\n0001 source=\"mbox:1\" bytes=427 parts=3 attachments=1 text=1 html=-\n"
    );
    assert_eq!(fs::read_to_string(out.join("messages/0001.txt")).unwrap(), EXPECTED_MESSAGE);
    assert_eq!(fs::read(out.join("parts/0001/002.bin")).unwrap(), vec![0, 1, 2, 3]);
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn directory_mode_sorts_and_filters() {
    let dir = scratch("dir");
    let input = dir.join("in");
    let out = dir.join("out");
    fs::create_dir(&input).unwrap();
    fs::write(input.join("b.eml"), "Subject: b\r\n\r\nbody b\r\n").unwrap();
    fs::write(input.join("Z.eml"), "Subject: z\n\nbody z\n").unwrap();
    fs::write(input.join("a.eml.txt"), "ignored").unwrap();
    fs::write(input.join("A.EML"), "ignored").unwrap();
    fs::create_dir(input.join("sub.eml")).unwrap();
    // The output directory need not exist beforehand.
    run(&input, &out);

    let summary = fs::read_to_string(out.join("summary.txt")).unwrap();
    assert_eq!(
        summary,
        "messages 2\n\
         0001 source=\"Z.eml\" bytes=19 parts=1 attachments=0 text=0 html=-\n\
         0002 source=\"b.eml\" bytes=22 parts=1 attachments=0 text=0 html=-\n"
    );
    let second = fs::read_to_string(out.join("messages/0002.txt")).unwrap();
    assert!(second.contains("subject: \"b\"\n"));
    assert!(second.contains("text 0 chars 7\n| body b\n"));
    assert!(!out.join("parts").exists());
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn mbox_without_messages() {
    let dir = scratch("empty");
    let input = dir.join("input");
    let out = dir.join("out");
    fs::write(&input, "Subject: no separator\n\nbody\n").unwrap();
    run(&input, &out);
    assert_eq!(fs::read_to_string(out.join("summary.txt")).unwrap(), "messages 0\n");
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn wrong_arguments_fail() {
    let status = Command::new(env!("CARGO_BIN_EXE_mime")).status().unwrap();
    assert!(!status.success());
}
