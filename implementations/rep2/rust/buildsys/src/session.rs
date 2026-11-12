//! Session scripts: parsing `session.txt`, running the steps against a
//! workspace, and producing `log.txt`.

use std::fmt;

use crate::engine::build;
use crate::scheduler::EventKind;
use crate::workspace::Workspace;

/// One step of a session script.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SessionStep {
    /// `build [TARGET ...] [-j N]`
    Build {
        /// Requested targets; empty means the default targets.
        targets: Vec<String>,
        /// The worker count.
        jobs: usize,
    },
    /// `create PATH` with a content block.
    Create {
        /// The path to create.
        path: String,
        /// The new content.
        content: Vec<u8>,
    },
    /// `edit PATH` with a content block.
    Edit {
        /// The path to edit.
        path: String,
        /// The new content.
        content: Vec<u8>,
    },
    /// `delete PATH`
    Delete {
        /// The path to delete.
        path: String,
    },
    /// `touch PATH`
    Touch {
        /// The path to touch.
        path: String,
    },
    /// `clean`
    Clean,
}

/// A malformed session script.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionError {
    /// 1-based line number of the offending line.
    pub line: usize,
    /// What was wrong.
    pub message: String,
}

impl fmt::Display for SessionError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "session.txt:{}: {}", self.line, self.message)
    }
}

impl std::error::Error for SessionError {}

/// A parsed session script.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Session {
    /// The steps in script order.
    pub steps: Vec<SessionStep>,
}

fn is_blank(b: u8) -> bool {
    b == b' ' || b == b'\t'
}

impl Session {
    /// Parses a session script.
    ///
    /// ```
    /// use kiln::session::{Session, SessionStep};
    /// let s = Session::parse(b"# hi\nbuild @all -j 4\nclean\n").unwrap();
    /// assert_eq!(s.steps.len(), 2);
    /// assert_eq!(
    ///     s.steps[0],
    ///     SessionStep::Build { targets: vec!["@all".into()], jobs: 4 }
    /// );
    /// ```
    pub fn parse(src: &[u8]) -> Result<Session, SessionError> {
        let mut lines: Vec<&[u8]> = src.split(|&b| b == b'\n').collect();
        if src.last() == Some(&b'\n') || src.is_empty() {
            lines.pop();
        }
        let mut steps = Vec::new();
        let mut i = 0;
        while i < lines.len() {
            let line = trim(lines[i]);
            let lineno = i + 1;
            i += 1;
            if line.is_empty() || line[0] == b'#' {
                continue;
            }
            let words: Vec<String> = line
                .split(|&b| is_blank(b))
                .filter(|w| !w.is_empty())
                .map(|w| String::from_utf8_lossy(w).into_owned())
                .collect();
            let err = |m: &str| SessionError {
                line: lineno,
                message: m.to_string(),
            };
            match words[0].as_str() {
                "build" => {
                    let rest = &words[1..];
                    let (targets, jobs) = if rest.len() >= 2 && rest[rest.len() - 2] == "-j" {
                        let n = rest[rest.len() - 1]
                            .parse::<usize>()
                            .map_err(|_| err("bad -j value"))?;
                        (rest[..rest.len() - 2].to_vec(), n)
                    } else {
                        (rest.to_vec(), 1)
                    };
                    steps.push(SessionStep::Build { targets, jobs });
                }
                kw @ ("create" | "edit") => {
                    if words.len() != 2 {
                        return Err(err("expected one path"));
                    }
                    let mut content = Vec::new();
                    loop {
                        let Some(l) = lines.get(i) else {
                            return Err(err("unterminated content block"));
                        };
                        i += 1;
                        if *l == b"---" {
                            break;
                        }
                        content.extend_from_slice(l);
                        content.push(b'\n');
                    }
                    let path = words[1].clone();
                    steps.push(if kw == "create" {
                        SessionStep::Create { path, content }
                    } else {
                        SessionStep::Edit { path, content }
                    });
                }
                "delete" | "touch" if words.len() == 2 => {
                    let path = words[1].clone();
                    steps.push(if words[0] == "delete" {
                        SessionStep::Delete { path }
                    } else {
                        SessionStep::Touch { path }
                    });
                }
                "clean" if words.len() == 1 => steps.push(SessionStep::Clean),
                _ => return Err(err("unrecognised session step")),
            }
        }
        Ok(Session { steps })
    }

    /// Runs the session against `ws`, returning the log.
    pub fn run(&self, ws: &mut Workspace) -> Vec<u8> {
        let mut log = Vec::new();
        for (n, step) in self.steps.iter().enumerate() {
            log.extend_from_slice(format!("step {}: ", n + 1).as_bytes());
            run_step(step, ws, &mut log);
        }
        log
    }
}

fn trim(mut l: &[u8]) -> &[u8] {
    while let [rest @ .., b] = l {
        if is_blank(*b) {
            l = rest;
        } else {
            break;
        }
    }
    while let [b, rest @ ..] = l {
        if is_blank(*b) {
            l = rest;
        } else {
            break;
        }
    }
    l
}

fn line(log: &mut Vec<u8>, parts: &[&[u8]]) {
    for p in parts {
        log.extend_from_slice(p);
    }
    log.push(b'\n');
}

fn run_step(step: &SessionStep, ws: &mut Workspace, log: &mut Vec<u8>) {
    match step {
        SessionStep::Build { targets, jobs } => {
            let head = if targets.is_empty() {
                "(default)".to_string()
            } else {
                targets.join(" ")
            };
            line(log, &[format!("build {head} -j {jobs}").as_bytes()]);
            let report = build(ws, targets, *jobs);
            for e in &report.events {
                let text = match e.kind {
                    EventKind::Hit => format!("  hit {} {}", e.start, e.target).into_bytes(),
                    k => {
                        let tag = match k {
                            EventKind::Run => "run",
                            EventKind::Fail => "fail",
                            _ => "cancel",
                        };
                        let mut t = format!(
                            "  {tag} {} {} w{} {} ",
                            e.start, e.end, e.worker, e.target
                        )
                        .into_bytes();
                        t.extend_from_slice(&e.command);
                        t
                    }
                };
                line(log, &[&text]);
            }
            match &report.outcome {
                Ok(s) => line(
                    log,
                    &[format!("  ok ran={} hit={} time={}", s.ran, s.hits, s.time).as_bytes()],
                ),
                Err(e) => line(log, &[b"  error ", &e.render()]),
            }
        }
        SessionStep::Create { path, content } | SessionStep::Edit { path, content } => {
            let verb = if matches!(step, SessionStep::Create { .. }) {
                "create"
            } else {
                "edit"
            };
            line(log, &[format!("{verb} {path}").as_bytes()]);
            ws.write(path, content.clone());
            line(log, &[format!("  ok size={}", content.len()).as_bytes()]);
        }
        SessionStep::Delete { path } => {
            line(log, &[format!("delete {path}").as_bytes()]);
            ws.remove(path);
            line(log, &[b"  ok"]);
        }
        SessionStep::Touch { path } => {
            line(log, &[format!("touch {path}").as_bytes()]);
            ws.touch(path);
            line(log, &[b"  ok"]);
        }
        SessionStep::Clean => {
            line(log, &[b"clean"]);
            let gone = ws.clean();
            for p in &gone {
                line(log, &[format!("  remove {p}").as_bytes()]);
            }
            line(log, &[format!("  ok removed={}", gone.len()).as_bytes()]);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_all_forms() {
        let src = b"# c\n\n  build a b -j 3\nbuild\nbuild -j\nbuild x -j -j 2\ncreate p\n a \n# keep\n\n---\nedit q\n---\ndelete p\ntouch q\nclean\n";
        let s = Session::parse(src).unwrap();
        assert_eq!(s.steps.len(), 9);
        assert_eq!(
            s.steps[0],
            SessionStep::Build {
                targets: vec!["a".into(), "b".into()],
                jobs: 3
            }
        );
        assert_eq!(
            s.steps[2],
            SessionStep::Build {
                targets: vec!["-j".into()],
                jobs: 1
            }
        );
        assert_eq!(
            s.steps[3],
            SessionStep::Build {
                targets: vec!["x".into(), "-j".into()],
                jobs: 2
            }
        );
        assert_eq!(
            s.steps[4],
            SessionStep::Create {
                path: "p".into(),
                content: b" a \n# keep\n\n".to_vec()
            }
        );
        assert_eq!(
            s.steps[5],
            SessionStep::Edit {
                path: "q".into(),
                content: vec![]
            }
        );
    }

    #[test]
    fn rejects_garbage() {
        assert!(Session::parse(b"frobnicate\n").is_err());
        assert!(Session::parse(b"create p\nabc\n").is_err());
    }
}
