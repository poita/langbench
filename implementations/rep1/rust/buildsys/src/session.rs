//! Session scripts: parsing `session.txt` and running it, producing the log.

use crate::build::{build, BuildReport, EventKind};
use crate::workspace::Workspace;

/// One step of a session script.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SessionStep {
    Build { targets: Vec<Vec<u8>>, jobs: usize },
    Create { path: Vec<u8>, content: Vec<u8> },
    Edit { path: Vec<u8>, content: Vec<u8> },
    Delete { path: Vec<u8> },
    Touch { path: Vec<u8> },
    Clean,
}

fn is_blank(b: &u8) -> bool {
    *b == b' ' || *b == b'\t'
}

fn trim(mut s: &[u8]) -> &[u8] {
    while let Some((f, rest)) = s.split_first() {
        if is_blank(f) {
            s = rest;
        } else {
            break;
        }
    }
    while let Some((l, rest)) = s.split_last() {
        if is_blank(l) {
            s = rest;
        } else {
            break;
        }
    }
    s
}

/// Parses a session script. Lines that match none of the step forms are
/// ignored.
pub fn parse_session(src: &[u8]) -> Vec<SessionStep> {
    let mut lines: Vec<&[u8]> = src.split(|&b| b == b'\n').collect();
    if src.last() == Some(&b'\n') || src.is_empty() {
        lines.pop();
    }
    let mut steps = Vec::new();
    let mut i = 0;
    while i < lines.len() {
        let line = trim(lines[i]);
        i += 1;
        if line.is_empty() || line[0] == b'#' {
            continue;
        }
        let words: Vec<&[u8]> = line.split(is_blank).filter(|w| !w.is_empty()).collect();
        match words[0] {
            b"build" => {
                let mut targets: Vec<Vec<u8>> = words[1..].iter().map(|w| w.to_vec()).collect();
                let mut jobs = 1;
                if targets.len() >= 2 && targets[targets.len() - 2] == b"-j" {
                    let n = std::str::from_utf8(&targets[targets.len() - 1]).ok().and_then(|s| s.parse::<usize>().ok());
                    if let Some(n) = n {
                        jobs = n;
                        targets.truncate(targets.len() - 2);
                    }
                }
                steps.push(SessionStep::Build { targets, jobs });
            }
            b"create" | b"edit" if words.len() == 2 => {
                let mut content = Vec::new();
                while i < lines.len() && lines[i] != b"---" {
                    content.extend_from_slice(lines[i]);
                    content.push(b'\n');
                    i += 1;
                }
                i += 1; // the `---` terminator
                let path = words[1].to_vec();
                steps.push(if words[0] == b"create" {
                    SessionStep::Create { path, content }
                } else {
                    SessionStep::Edit { path, content }
                });
            }
            b"delete" if words.len() == 2 => steps.push(SessionStep::Delete { path: words[1].to_vec() }),
            b"touch" if words.len() == 2 => steps.push(SessionStep::Touch { path: words[1].to_vec() }),
            b"clean" if words.len() == 1 => steps.push(SessionStep::Clean),
            _ => {}
        }
    }
    steps
}

fn push_line(log: &mut Vec<u8>, parts: &[&[u8]]) {
    for p in parts {
        log.extend_from_slice(p);
    }
    log.push(b'\n');
}

/// Runs the session against the workspace and returns the log text.
pub fn run_session(ws: &mut Workspace, steps: &[SessionStep]) -> Vec<u8> {
    let mut log = Vec::new();
    for (idx, step) in steps.iter().enumerate() {
        let n = idx + 1;
        match step {
            SessionStep::Build { targets, jobs } => {
                let mut head = format!("step {n}: build").into_bytes();
                if targets.is_empty() {
                    head.extend_from_slice(b" (default)");
                }
                for t in targets {
                    head.push(b' ');
                    head.extend_from_slice(t);
                }
                head.extend_from_slice(format!(" -j {jobs}").as_bytes());
                push_line(&mut log, &[&head]);
                let report = build(ws, targets, *jobs);
                write_report(&mut log, &report);
            }
            SessionStep::Create { path, content } | SessionStep::Edit { path, content } => {
                let verb = if matches!(step, SessionStep::Create { .. }) { "create" } else { "edit" };
                push_line(&mut log, &[format!("step {n}: {verb} ").as_bytes(), path]);
                ws.write(path, content.clone());
                push_line(&mut log, &[format!("  ok size={}", content.len()).as_bytes()]);
            }
            SessionStep::Delete { path } => {
                push_line(&mut log, &[format!("step {n}: delete ").as_bytes(), path]);
                ws.remove(path);
                push_line(&mut log, &[b"  ok"]);
            }
            SessionStep::Touch { path } => {
                push_line(&mut log, &[format!("step {n}: touch ").as_bytes(), path]);
                ws.touch(path);
                push_line(&mut log, &[b"  ok"]);
            }
            SessionStep::Clean => {
                push_line(&mut log, &[format!("step {n}: clean").as_bytes()]);
                let removed = ws.clean();
                for p in &removed {
                    push_line(&mut log, &[b"  remove ", p]);
                }
                push_line(&mut log, &[format!("  ok removed={}", removed.len()).as_bytes()]);
            }
        }
    }
    log
}

fn write_report(log: &mut Vec<u8>, report: &BuildReport) {
    for e in &report.events {
        match e.kind {
            EventKind::Hit => push_line(log, &[format!("  hit {} ", e.start).as_bytes(), &e.target]),
            kind => {
                let word = match kind {
                    EventKind::Run => "run",
                    EventKind::Fail => "fail",
                    _ => "cancel",
                };
                push_line(
                    log,
                    &[format!("  {word} {} {} w{} ", e.start, e.end, e.worker).as_bytes(), &e.target, b" ", &e.command],
                );
            }
        }
    }
    match &report.result {
        Ok(s) => push_line(log, &[format!("  ok ran={} hit={} time={}", s.ran, s.hits, s.time).as_bytes()]),
        Err(e) => push_line(log, &[b"  error ", &e.render()]),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_all_forms() {
        let src = b"# comment\n\n  build a b -j 4\nbuild\nbuild -j 2\nbuild x -j\ncreate p/q\n l1 \n\n---\nedit r\n---\ndelete d\ntouch t\nclean\n";
        let steps = parse_session(src);
        assert_eq!(steps[0], SessionStep::Build { targets: vec![b"a".to_vec(), b"b".to_vec()], jobs: 4 });
        assert_eq!(steps[1], SessionStep::Build { targets: vec![], jobs: 1 });
        assert_eq!(steps[2], SessionStep::Build { targets: vec![], jobs: 2 });
        assert_eq!(steps[3], SessionStep::Build { targets: vec![b"x".to_vec(), b"-j".to_vec()], jobs: 1 });
        assert_eq!(steps[4], SessionStep::Create { path: b"p/q".to_vec(), content: b" l1 \n\n".to_vec() });
        assert_eq!(steps[5], SessionStep::Edit { path: b"r".to_vec(), content: vec![] });
        assert_eq!(steps.len(), 9);
    }

    #[test]
    fn comment_lines_inside_content_are_content() {
        let steps = parse_session(b"create a\n# not a comment\n\n---\n");
        assert_eq!(steps, vec![SessionStep::Create { path: b"a".to_vec(), content: b"# not a comment\n\n".to_vec() }]);
    }
}
