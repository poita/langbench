//! The sixteen built-in commands: their signatures, canonical rendering and
//! execution against the virtual file system.

use std::collections::{BTreeSet, HashSet};

use crate::builtins::{int_text, replace_bytes};
use crate::error::{Error, ErrorKind, Result};
use crate::hash::hex;
use crate::workspace::{is_workspace_path, Workspace};

/// Which command a step runs. Variants are named after the commands.
#[allow(missing_docs)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CmdKind {
    Write,
    Copy,
    Concat,
    Upper,
    Lower,
    Grep,
    Replace,
    SortLines,
    ReverseLines,
    Dedup,
    Number,
    Indent,
    Wrap,
    CountLines,
    Hash,
    Preprocess,
}

/// The type of a command argument.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ArgTy {
    /// A byte string.
    Str,
    /// A signed integer.
    Int,
}

impl ArgTy {
    /// The type token used in error messages.
    pub fn token(self) -> &'static str {
        match self {
            ArgTy::Str => "str",
            ArgTy::Int => "int",
        }
    }
}

struct Info {
    name: &'static str,
    kind: CmdKind,
    args: &'static [ArgTy],
    /// Inclusive range of file inputs; `None` upper bound means unbounded.
    inputs: (usize, Option<usize>),
    depfile: bool,
    cost: u64,
}

const S: ArgTy = ArgTy::Str;

const fn info(
    name: &'static str,
    kind: CmdKind,
    args: &'static [ArgTy],
    inputs: (usize, Option<usize>),
    depfile: bool,
    cost: u64,
) -> Info {
    Info {
        name,
        kind,
        args,
        inputs,
        depfile,
        cost,
    }
}

static COMMANDS: [Info; 16] = [
    info("write", CmdKind::Write, &[S], (0, Some(0)), false, 1),
    info("copy", CmdKind::Copy, &[], (1, Some(1)), false, 1),
    info("concat", CmdKind::Concat, &[], (1, None), false, 2),
    info("upper", CmdKind::Upper, &[], (1, Some(1)), false, 2),
    info("lower", CmdKind::Lower, &[], (1, Some(1)), false, 2),
    info("grep", CmdKind::Grep, &[S], (1, Some(1)), false, 3),
    info("replace", CmdKind::Replace, &[S, S], (1, Some(1)), false, 3),
    info("sort_lines", CmdKind::SortLines, &[], (1, Some(1)), false, 4),
    info("reverse_lines", CmdKind::ReverseLines, &[], (1, Some(1)), false, 2),
    info("dedup", CmdKind::Dedup, &[], (1, Some(1)), false, 3),
    info("number", CmdKind::Number, &[], (1, Some(1)), false, 2),
    info("indent", CmdKind::Indent, &[ArgTy::Int], (1, Some(1)), false, 2),
    info("wrap", CmdKind::Wrap, &[S, S], (1, Some(1)), false, 1),
    info("count_lines", CmdKind::CountLines, &[], (1, None), false, 2),
    info("hash", CmdKind::Hash, &[], (1, None), false, 3),
    info("preprocess", CmdKind::Preprocess, &[], (1, Some(1)), true, 6),
];

impl CmdKind {
    /// Looks a command up by name.
    pub fn from_name(name: &str) -> Option<CmdKind> {
        COMMANDS.iter().find(|i| i.name == name).map(|i| i.kind)
    }

    fn info(self) -> &'static Info {
        COMMANDS.iter().find(|i| i.kind == self).expect("command table is complete")
    }

    /// The command's name.
    pub fn name(self) -> &'static str {
        self.info().name
    }

    /// The command's argument types.
    pub fn arg_types(self) -> &'static [ArgTy] {
        self.info().args
    }

    /// The cost used when a step has no `cost` field.
    pub fn default_cost(self) -> u64 {
        self.info().cost
    }

    /// Whether the command requires a `depfile` field.
    pub fn uses_depfile(self) -> bool {
        self.info().depfile
    }

    /// Checks the number of file inputs against the command's shape.
    pub fn check_inputs(self, n: usize) -> Result<()> {
        let i = self.info();
        let (lo, hi) = i.inputs;
        if n < lo || hi.is_some_and(|h| n > h) {
            let range = match hi {
                Some(h) => format!("{lo}-{h}"),
                None => format!("{lo}-N"),
            };
            return Err(Error::new(
                ErrorKind::CmdShape,
                format!("{}: expected inputs {range}, got {n}", i.name),
            ));
        }
        Ok(())
    }
}

/// An evaluated command argument.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CmdArg {
    /// A string argument.
    Str(Vec<u8>),
    /// An integer argument.
    Int(i64),
}

/// A command with its evaluated arguments.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Command {
    /// Which command.
    pub kind: CmdKind,
    /// Its evaluated arguments.
    pub args: Vec<CmdArg>,
}

impl Command {
    /// The canonical rendering, e.g. `write("hello\n")`.
    pub fn canonical(&self) -> Vec<u8> {
        let mut out = self.kind.name().as_bytes().to_vec();
        out.push(b'(');
        for (i, a) in self.args.iter().enumerate() {
            if i > 0 {
                out.extend_from_slice(b", ");
            }
            match a {
                CmdArg::Int(n) => out.extend_from_slice(&int_text(*n)),
                CmdArg::Str(s) => {
                    out.push(b'"');
                    for &b in s {
                        match b {
                            b'\\' => out.extend_from_slice(b"\\\\"),
                            b'"' => out.extend_from_slice(b"\\\""),
                            b'\n' => out.extend_from_slice(b"\\n"),
                            b'\t' => out.extend_from_slice(b"\\t"),
                            b'\r' => out.extend_from_slice(b"\\r"),
                            0..=0x1f | 0x7f => {
                                out.extend_from_slice(format!("\\x{b:02x}").as_bytes())
                            }
                            _ => out.push(b),
                        }
                    }
                    out.push(b'"');
                }
            }
        }
        out.push(b')');
        out
    }

    /// Command-specific argument checks (`E_ARG cmd …`).
    pub fn check_args(&self) -> Result<()> {
        match (self.kind, self.args.as_slice()) {
            (CmdKind::Replace, [CmdArg::Str(from), _]) if from.is_empty() => {
                Err(Error::arg("cmd", "replace", "empty pattern"))
            }
            (CmdKind::Indent, [CmdArg::Int(n)]) if *n < 0 => {
                Err(Error::arg("cmd", "indent", "negative"))
            }
            _ => Ok(()),
        }
    }

    fn str_arg(&self, i: usize) -> &[u8] {
        match self.args.get(i) {
            Some(CmdArg::Str(s)) => s,
            _ => &[],
        }
    }
}

/// What a command produced when it ran.
#[derive(Debug, Clone, Default)]
pub struct Execution {
    /// `(path, content)` for the declared outputs followed by the depfile.
    pub outputs: Vec<(String, Vec<u8>)>,
    /// The file inputs with the hash of the content read.
    pub inputs: Vec<(String, u64)>,
    /// Discovered dependencies, sorted, with the hash of the content read.
    pub deps: Vec<(String, u64)>,
}

/// The lines of a byte string (see the specification).
pub fn lines(c: &[u8]) -> Vec<&[u8]> {
    if c.is_empty() {
        return Vec::new();
    }
    let mut v: Vec<&[u8]> = c.split(|&b| b == b'\n').collect();
    if c.last() == Some(&b'\n') {
        v.pop();
    }
    v
}

fn emit_lines<'a>(out: &mut Vec<u8>, ls: impl IntoIterator<Item = &'a [u8]>) {
    for l in ls {
        out.extend_from_slice(l);
        out.push(b'\n');
    }
}

/// Runs `cmd` for a step with the given file inputs and output paths against
/// `ws`, reading every input now and returning what would be written.
pub fn execute(
    cmd: &Command,
    file_inputs: &[String],
    outputs: &[String],
    depfile: Option<&str>,
    ws: &Workspace,
) -> Result<Execution> {
    let empty: &[u8] = &[];
    let contents: Vec<&[u8]> = file_inputs
        .iter()
        .map(|p| ws.read(p).unwrap_or(empty))
        .collect();
    let first = contents.first().copied().unwrap_or(empty);
    let mut out = Vec::new();
    let mut deps: Vec<(String, u64)> = Vec::new();
    let mut depfile_content = None;
    match cmd.kind {
        CmdKind::Write => out.extend_from_slice(cmd.str_arg(0)),
        CmdKind::Copy => out.extend_from_slice(first),
        CmdKind::Concat => {
            for c in &contents {
                out.extend_from_slice(c);
            }
        }
        CmdKind::Upper => out = first.to_ascii_uppercase(),
        CmdKind::Lower => out = first.to_ascii_lowercase(),
        CmdKind::Grep => {
            let needle = cmd.str_arg(0);
            emit_lines(
                &mut out,
                lines(first)
                    .into_iter()
                    .filter(|l| needle.is_empty() || contains(l, needle)),
            );
        }
        CmdKind::Replace => out = replace_bytes(first, cmd.str_arg(0), cmd.str_arg(1)),
        CmdKind::SortLines => {
            let mut ls = lines(first);
            ls.sort_unstable();
            emit_lines(&mut out, ls);
        }
        CmdKind::ReverseLines => {
            let mut ls = lines(first);
            ls.reverse();
            emit_lines(&mut out, ls);
        }
        CmdKind::Dedup => {
            let mut seen = HashSet::new();
            emit_lines(&mut out, lines(first).into_iter().filter(|l| seen.insert(*l)));
        }
        CmdKind::Number => {
            for (i, l) in lines(first).into_iter().enumerate() {
                out.extend_from_slice(format!("{}: ", i + 1).as_bytes());
                out.extend_from_slice(l);
                out.push(b'\n');
            }
        }
        CmdKind::Indent => {
            let n = match cmd.args.first() {
                Some(CmdArg::Int(n)) => *n as usize,
                _ => 0,
            };
            for l in lines(first) {
                out.resize(out.len() + n, b' ');
                out.extend_from_slice(l);
                out.push(b'\n');
            }
        }
        CmdKind::Wrap => {
            out.extend_from_slice(cmd.str_arg(0));
            out.extend_from_slice(first);
            out.extend_from_slice(cmd.str_arg(1));
        }
        CmdKind::CountLines => {
            let mut total = 0usize;
            for (p, c) in file_inputs.iter().zip(&contents) {
                let n = lines(c).len();
                total += n;
                out.extend_from_slice(format!("{n} {p}\n").as_bytes());
            }
            out.extend_from_slice(format!("{total} total\n").as_bytes());
        }
        CmdKind::Hash => {
            for p in file_inputs {
                let h = ws.hash(p).unwrap_or(crate::hash::fnv1a64(b""));
                out.extend_from_slice(format!("{} {p}\n", hex(h)).as_bytes());
            }
        }
        CmdKind::Preprocess => {
            let mut discovered = BTreeSet::new();
            let mut stack = vec![file_inputs[0].clone()];
            expand(ws, &file_inputs[0], first, &mut stack, &mut discovered, &mut out)?;
            let mut d = b"kiln-deps 1\n".to_vec();
            for p in &discovered {
                d.extend_from_slice(b"need ");
                d.extend_from_slice(p.as_bytes());
                d.push(b'\n');
                deps.push((p.clone(), ws.hash(p).unwrap_or(0)));
            }
            depfile_content = Some(d);
        }
    }
    let mut result = Execution {
        outputs: Vec::new(),
        inputs: file_inputs
            .iter()
            .map(|p| (p.clone(), ws.hash(p).unwrap_or(0)))
            .collect(),
        deps,
    };
    result.outputs.push((outputs[0].clone(), out));
    if let (Some(path), Some(content)) = (depfile, depfile_content) {
        result.outputs.push((path.to_string(), content));
    }
    Ok(result)
}

fn contains(hay: &[u8], needle: &[u8]) -> bool {
    hay.windows(needle.len()).any(|w| w == needle)
}

/// Recursive `@need` expansion of the file `path` whose content is `content`.
fn expand(
    ws: &Workspace,
    path: &str,
    content: &[u8],
    stack: &mut Vec<String>,
    discovered: &mut BTreeSet<String>,
    out: &mut Vec<u8>,
) -> Result<()> {
    for line in lines(content) {
        match line.strip_prefix(b"@need ") {
            Some(q) if !q.is_empty() => {
                if !is_workspace_path(q) {
                    return Err(Error::new(ErrorKind::NeedPath, q));
                }
                let q = String::from_utf8_lossy(q).into_owned();
                let Some(body) = ws.read(&q) else {
                    return Err(Error::new(
                        ErrorKind::NeedMissing,
                        format!("{q} needed by {path}"),
                    ));
                };
                if stack.contains(&q) {
                    return Err(Error::new(ErrorKind::NeedCycle, q));
                }
                discovered.insert(q.clone());
                stack.push(q.clone());
                expand(ws, &q, body, stack, discovered, out)?;
                stack.pop();
            }
            _ => {
                out.extend_from_slice(line);
                out.push(b'\n');
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cmd(kind: CmdKind, args: Vec<CmdArg>) -> Command {
        Command { kind, args }
    }

    fn run1(c: &Command, input: &str) -> String {
        let mut ws = Workspace::new();
        ws.write("in", input.as_bytes().to_vec());
        let ex = execute(c, &["in".to_string()], &["out/o".to_string()], None, &ws).unwrap();
        String::from_utf8(ex.outputs[0].1.clone()).unwrap()
    }

    #[test]
    fn line_splitting() {
        assert!(lines(b"").is_empty());
        assert_eq!(lines(b"a\nb\n"), vec![&b"a"[..], b"b"]);
        assert_eq!(lines(b"a\nb"), vec![&b"a"[..], b"b"]);
        assert_eq!(lines(b"a\n\nb\n"), vec![&b"a"[..], b"", b"b"]);
        assert_eq!(lines(b"\n"), vec![&b""[..]]);
    }

    #[test]
    fn canonical_rendering() {
        let c = cmd(CmdKind::Write, vec![CmdArg::Str(b"hello\n".to_vec())]);
        assert_eq!(c.canonical(), b"write(\"hello\\n\")");
        let c = cmd(
            CmdKind::Replace,
            vec![CmdArg::Str(b"a\\b".to_vec()), CmdArg::Str(b"\x01\x7f\"\xc3\xbc".to_vec())],
        );
        assert_eq!(c.canonical(), "replace(\"a\\\\b\", \"\\x01\\x7f\\\"ü\")".as_bytes());
        assert_eq!(cmd(CmdKind::Indent, vec![CmdArg::Int(4)]).canonical(), b"indent(4)");
        assert_eq!(cmd(CmdKind::Preprocess, vec![]).canonical(), b"preprocess()");
    }

    #[test]
    fn line_commands() {
        assert_eq!(run1(&cmd(CmdKind::SortLines, vec![]), "b\na\nb"), "a\nb\nb\n");
        assert_eq!(run1(&cmd(CmdKind::ReverseLines, vec![]), "a\nb\n"), "b\na\n");
        assert_eq!(run1(&cmd(CmdKind::Dedup, vec![]), "a\nb\na\n"), "a\nb\n");
        assert_eq!(run1(&cmd(CmdKind::Number, vec![]), "a\nb\nc\n"), "1: a\n2: b\n3: c\n");
        assert_eq!(
            run1(&cmd(CmdKind::Indent, vec![CmdArg::Int(2)]), "a\n\n"),
            "  a\n  \n"
        );
        assert_eq!(
            run1(&cmd(CmdKind::Grep, vec![CmdArg::Str(b"x".to_vec())]), "ax\nb\nxx"),
            "ax\nxx\n"
        );
        assert_eq!(
            run1(&cmd(CmdKind::Grep, vec![CmdArg::Str(vec![])]), "a\nb"),
            "a\nb\n"
        );
        assert_eq!(
            run1(
                &cmd(CmdKind::Wrap, vec![CmdArg::Str(b"<".to_vec()), CmdArg::Str(b">".to_vec())]),
                "x"
            ),
            "<x>"
        );
    }

    #[test]
    fn preprocess_expansion_and_errors() {
        let mut ws = Workspace::new();
        ws.write("a", b"t\n@need b\n@need \n@need\ne".to_vec());
        ws.write("b", b"B\n@need c\n".to_vec());
        ws.write("c", b"C\n".to_vec());
        let c = cmd(CmdKind::Preprocess, vec![]);
        let ex = execute(&c, &["a".into()], &["out/x".into()], Some("out/x.d"), &ws).unwrap();
        assert_eq!(ex.outputs[0].1, b"t\nB\nC\n@need \n@need\ne\n");
        assert_eq!(ex.outputs[1].1, b"kiln-deps 1\nneed b\nneed c\n");
        assert_eq!(ex.deps.len(), 2);

        ws.write("c", b"@need a\n".to_vec());
        let e = execute(&c, &["a".into()], &["out/x".into()], Some("out/x.d"), &ws).unwrap_err();
        assert_eq!(e.to_string(), "E_NEED_CYCLE a");
        ws.write("c", b"@need nope\n".to_vec());
        let e = execute(&c, &["a".into()], &["out/x".into()], Some("out/x.d"), &ws).unwrap_err();
        assert_eq!(e.to_string(), "E_NEED_MISSING nope needed by c");
        ws.write("c", b"@need a b\n".to_vec());
        let e = execute(&c, &["a".into()], &["out/x".into()], Some("out/x.d"), &ws).unwrap_err();
        assert_eq!(e.to_string(), "E_NEED_PATH a b");
    }

    #[test]
    fn shape_errors() {
        assert_eq!(
            CmdKind::Write.check_inputs(1).unwrap_err().to_string(),
            "E_CMD_SHAPE write: expected inputs 0-0, got 1"
        );
        assert_eq!(
            CmdKind::Concat.check_inputs(0).unwrap_err().to_string(),
            "E_CMD_SHAPE concat: expected inputs 1-N, got 0"
        );
        assert!(CmdKind::Hash.check_inputs(5).is_ok());
    }
}
