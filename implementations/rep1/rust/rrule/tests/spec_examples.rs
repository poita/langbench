//! Integration tests: the worked examples of the specification, through both
//! the library API and the command-line binary.

use std::io::Write;
use std::process::{Command, Stdio};

use rrule::Request;

const CASES: &[(&str, &str)] = &[
    (
        "19970902T090000 FREQ=MONTHLY;INTERVAL=2;BYDAY=-1FR;COUNT=10 100",
        "19970926T090000 19971128T090000 19980130T090000 19980327T090000 19980529T090000 19980731T090000 19980925T090000 19981127T090000 19990129T090000 19990326T090000",
    ),
    (
        "19970902T090000 FREQ=WEEKLY;INTERVAL=2;WKST=SU;BYDAY=TU,TH;COUNT=8 100",
        "19970902T090000 19970904T090000 19970916T090000 19970918T090000 19970930T090000 19971002T090000 19971014T090000 19971016T090000",
    ),
    (
        "19970902T090000 FREQ=WEEKLY;INTERVAL=2;WKST=MO;BYDAY=TU,SU;COUNT=4 4",
        "19970902T090000 19970907T090000 19970916T090000 19970921T090000",
    ),
    (
        "20240229T120000 FREQ=YEARLY;COUNT=3 10",
        "20240229T120000 20280229T120000 20320229T120000",
    ),
    (
        "20240131T000000 FREQ=MONTHLY;BYMONTHDAY=-1;UNTIL=20240430T000000 10",
        "20240131T000000 20240229T000000 20240331T000000 20240430T000000",
    ),
    (
        "20240301T080000 FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1;COUNT=3 10",
        "20240329T080000 20240430T080000 20240531T080000",
    ),
    ("20260101T000000 FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=30;COUNT=5 10", ""),
    (
        "20200101T000000 FREQ=YEARLY;BYWEEKNO=53;BYDAY=MO;COUNT=3 10",
        "20201228T000000 20261228T000000 20321227T000000",
    ),
    (
        "20110101T000000 FREQ=YEARLY;BYWEEKNO=53;COUNT=4 10",
        "20110101T000000 20110102T000000 20151228T000000 20151229T000000",
    ),
    // N limits the output below COUNT.
    ("20240101T000000 FREQ=DAILY;COUNT=5 2", "20240101T000000 20240102T000000"),
    // BYSETPOS as the only BY part.
    ("20240115T100000 FREQ=MONTHLY;BYSETPOS=1;COUNT=2 10", "20240115T100000 20240215T100000"),
    ("20240115T100000 FREQ=MONTHLY;BYSETPOS=2;COUNT=2 10", ""),
    // BYYEARDAY with negative values.
    ("20240101T000000 FREQ=YEARLY;BYYEARDAY=1,-1;COUNT=3 10", "20240101T000000 20241231T000000 20250101T000000"),
    // Rules that run into the year-9999 limit.
    ("99981231T000000 FREQ=YEARLY 10", "99981231T000000 99991231T000000"),
    ("99991201T000000 FREQ=MONTHLY;INTERVAL=1 10", "99991201T000000"),
];

#[test]
fn library_examples() {
    for (input, expected) in CASES {
        let request = Request::parse(input).unwrap();
        assert_eq!(&request.render(), expected, "{input}");
    }
}

fn run_cli(input: &str) -> (String, bool) {
    let mut child = Command::new(env!("CARGO_BIN_EXE_rrule"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(input.as_bytes()).unwrap();
    let out = child.wait_with_output().unwrap();
    (String::from_utf8(out.stdout).unwrap(), out.status.success())
}

#[test]
fn cli_processes_all_lines() {
    let input: Vec<&str> = CASES.iter().map(|c| c.0).collect();
    let expected: String = CASES.iter().map(|c| format!("{}\n", c.1)).collect();
    // Without a trailing newline on the last line as well.
    let (out, ok) = run_cli(&input.join("\n"));
    assert!(ok);
    assert_eq!(out, expected);
    let (out, ok) = run_cli(&format!("{}\n", input.join("\n")));
    assert!(ok);
    assert_eq!(out, expected);
}

#[test]
fn cli_fails_on_malformed_input() {
    let (_, ok) = run_cli("garbage\n");
    assert!(!ok);
}

#[test]
fn cli_empty_input() {
    let (out, ok) = run_cli("");
    assert!(ok);
    assert!(out.is_empty());
}
