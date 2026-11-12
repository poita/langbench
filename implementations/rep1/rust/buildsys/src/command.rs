//! The sixteen built-in commands: signatures, canonical rendering and
//! execution against file contents.

use crate::builtins::{find, replace_all};
use crate::error::{Error, ErrorKind, Result};
use crate::hash::{fnv1a, hex};
use crate::value::Value;
use crate::workspace::{is_workspace_path, Workspace};
use std::collections::{BTreeSet, HashSet};
use std::rc::Rc;

/// Argument type of a command.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ArgTy {
    Str,
    Int,
}

impl ArgTy {
    fn token(self) -> &'static str {
        match self {
            ArgTy::Str => "str",
            ArgTy::Int => "int",
        }
    }

    fn accepts(self, v: &Value) -> bool {
        matches!((self, v), (ArgTy::Str, Value::Str(_)) | (ArgTy::Int, Value::Int(_)))
    }
}

/// Static description of a command.
#[derive(Debug)]
pub struct CommandSpec {
    pub name: &'static str,
    pub args: &'static [ArgTy],
    pub min_inputs: usize,
    /// `usize::MAX` means "or more".
    pub max_inputs: usize,
    pub uses_depfile: bool,
    pub default_cost: u64,
}

const N: usize = usize::MAX;

macro_rules! c {
    ($name:expr, [$($a:ident),*], $lo:expr, $hi:expr, $dep:expr, $cost:expr) => {
        CommandSpec {
            name: $name,
            args: &[$(ArgTy::$a),*],
            min_inputs: $lo,
            max_inputs: $hi,
            uses_depfile: $dep,
            default_cost: $cost,
        }
    };
}

static COMMANDS: [CommandSpec; 16] = [
    c!("write", [Str], 0, 0, false, 1),
    c!("copy", [], 1, 1, false, 1),
    c!("concat", [], 1, N, false, 2),
    c!("upper", [], 1, 1, false, 2),
    c!("lower", [], 1, 1, false, 2),
    c!("grep", [Str], 1, 1, false, 3),
    c!("replace", [Str, Str], 1, 1, false, 3),
    c!("sort_lines", [], 1, 1, false, 4),
    c!("reverse_lines", [], 1, 1, false, 2),
    c!("dedup", [], 1, 1, false, 3),
    c!("number", [], 1, 1, false, 2),
    c!("indent", [Int], 1, 1, false, 2),
    c!("wrap", [Str, Str], 1, 1, false, 1),
    c!("count_lines", [], 1, N, false, 2),
    c!("hash", [], 1, N, false, 3),
    c!("preprocess", [], 1, 1, true, 6),
];

/// Finds a command by name.
pub fn lookup(name: &str) -> Option<&'static CommandSpec> {
    COMMANDS.iter().find(|c| c.name == name)
}

/// A command invocation with evaluated arguments.
#[derive(Clone, Debug)]
pub struct Command {
    pub spec: &'static CommandSpec,
    pub args: Vec<Value>,
}

impl Command {
    /// Checks argument count, then types in ascending order.
    pub fn new(spec: &'static CommandSpec, args: Vec<Value>) -> Result<Command> {
        if args.len() != spec.args.len() {
            return Err(Error::new(
                ErrorKind::Arity,
                format!("cmd {}: expected {}, got {}", spec.name, spec.args.len(), args.len()),
            ));
        }
        for (i, (ty, a)) in spec.args.iter().zip(&args).enumerate() {
            if !ty.accepts(a) {
                return Err(Error::type_error(
                    &format!("cmd {} argument {}", spec.name, i + 1),
                    ty.token(),
                    a.type_name(),
                ));
            }
        }
        Ok(Command { spec, args })
    }

    /// The canonical rendering `name(arg, arg, ...)`.
    pub fn canonical(&self) -> Vec<u8> {
        let mut out = self.spec.name.as_bytes().to_vec();
        out.push(b'(');
        for (i, a) in self.args.iter().enumerate() {
            if i > 0 {
                out.extend_from_slice(b", ");
            }
            match a {
                Value::Int(n) => out.extend_from_slice(n.to_string().as_bytes()),
                Value::Str(s) => {
                    out.push(b'"');
                    for &b in s.iter() {
                        match b {
                            b'\\' => out.extend_from_slice(b"\\\\"),
                            b'"' => out.extend_from_slice(b"\\\""),
                            b'\n' => out.extend_from_slice(b"\\n"),
                            b'\t' => out.extend_from_slice(b"\\t"),
                            b'\r' => out.extend_from_slice(b"\\r"),
                            0..=0x1f | 0x7f => out.extend_from_slice(format!("\\x{b:02x}").as_bytes()),
                            _ => out.push(b),
                        }
                    }
                    out.push(b'"');
                }
                _ => unreachable!("command arguments are str or int"),
            }
        }
        out.push(b')');
        out
    }

    fn str_arg(&self, i: usize) -> &[u8] {
        match &self.args[i] {
            Value::Str(s) => s,
            _ => unreachable!("checked"),
        }
    }
}

/// The lines of a byte string: split at every `\n`, dropping one final empty
/// piece; the empty string has no lines.
pub fn lines(c: &[u8]) -> Vec<&[u8]> {
    if c.is_empty() {
        return Vec::new();
    }
    let mut v: Vec<&[u8]> = c.split(|&b| b == b'\n').collect();
    if v.last().is_some_and(|l| l.is_empty()) {
        v.pop();
    }
    v
}

fn join_lines<'a>(ls: impl IntoIterator<Item = &'a [u8]>) -> Vec<u8> {
    let mut out = Vec::new();
    for l in ls {
        out.extend_from_slice(l);
        out.push(b'\n');
    }
    out
}

/// A file input as read at dispatch time.
#[derive(Clone, Debug)]
pub struct Input {
    pub path: Vec<u8>,
    pub content: Rc<Vec<u8>>,
    pub hash: u64,
}

/// What a successful command produces.
#[derive(Debug, Default)]
pub struct Output {
    pub content: Vec<u8>,
    pub depfile: Option<Vec<u8>>,
    /// Discovered dependency paths, sorted and distinct.
    pub discovered: Vec<Vec<u8>>,
}

/// Runs a command. `ws` is consulted only by `preprocess`, for needed files.
pub fn execute(cmd: &Command, inputs: &[Input], ws: &Workspace) -> Result<Output> {
    let first = || inputs[0].content.as_slice();
    let content = match cmd.spec.name {
        "write" => cmd.str_arg(0).to_vec(),
        "copy" => first().to_vec(),
        "concat" => inputs.iter().flat_map(|i| i.content.iter().copied()).collect(),
        "upper" => first().to_ascii_uppercase(),
        "lower" => first().to_ascii_lowercase(),
        "grep" => {
            let needle = cmd.str_arg(0);
            join_lines(lines(first()).into_iter().filter(|l| find(l, needle, 0).is_some()))
        }
        "replace" => replace_all(first(), cmd.str_arg(0), cmd.str_arg(1)),
        "sort_lines" => {
            let mut ls = lines(first());
            ls.sort_unstable();
            join_lines(ls)
        }
        "reverse_lines" => join_lines(lines(first()).into_iter().rev()),
        "dedup" => {
            let mut seen: HashSet<&[u8]> = HashSet::new();
            join_lines(lines(first()).into_iter().filter(|l| seen.insert(l)))
        }
        "number" => {
            let mut out = Vec::new();
            for (i, l) in lines(first()).into_iter().enumerate() {
                out.extend_from_slice(format!("{}: ", i + 1).as_bytes());
                out.extend_from_slice(l);
                out.push(b'\n');
            }
            out
        }
        "indent" => {
            let n = match cmd.args[0] {
                Value::Int(n) => n.max(0) as usize,
                _ => unreachable!("checked"),
            };
            let mut out = Vec::new();
            for l in lines(first()) {
                out.resize(out.len() + n, b' ');
                out.extend_from_slice(l);
                out.push(b'\n');
            }
            out
        }
        "wrap" => {
            let mut out = cmd.str_arg(0).to_vec();
            out.extend_from_slice(first());
            out.extend_from_slice(cmd.str_arg(1));
            out
        }
        "count_lines" => {
            let mut out = Vec::new();
            let mut total = 0usize;
            for i in inputs {
                let n = lines(&i.content).len();
                total += n;
                out.extend_from_slice(format!("{n} ").as_bytes());
                out.extend_from_slice(&i.path);
                out.push(b'\n');
            }
            out.extend_from_slice(format!("{total} total\n").as_bytes());
            out
        }
        "hash" => {
            let mut out = Vec::new();
            for i in inputs {
                out.extend_from_slice(hex(fnv1a(&i.content)).as_bytes());
                out.push(b' ');
                out.extend_from_slice(&i.path);
                out.push(b'\n');
            }
            out
        }
        "preprocess" => return preprocess(&inputs[0], ws),
        other => unreachable!("unknown command {other}"),
    };
    Ok(Output { content, ..Output::default() })
}

struct Expander<'a> {
    ws: &'a Workspace,
    stack: Vec<Vec<u8>>,
    discovered: BTreeSet<Vec<u8>>,
    out: Vec<u8>,
}

impl Expander<'_> {
    fn expand(&mut self, path: &[u8], content: &[u8]) -> Result<()> {
        self.stack.push(path.to_vec());
        for line in lines(content) {
            match line.strip_prefix(b"@need ").filter(|q| !q.is_empty()) {
                Some(q) => {
                    if !is_workspace_path(q) {
                        return Err(Error::new(ErrorKind::NeedPath, q));
                    }
                    let Some(file) = self.ws.get(q) else {
                        let mut d = q.to_vec();
                        d.extend_from_slice(b" needed by ");
                        d.extend_from_slice(path);
                        return Err(Error::new(ErrorKind::NeedMissing, d));
                    };
                    if self.stack.iter().any(|s| s.as_slice() == q) {
                        return Err(Error::new(ErrorKind::NeedCycle, q));
                    }
                    self.discovered.insert(q.to_vec());
                    let inner = file.content.clone();
                    self.expand(q, &inner)?;
                }
                None => {
                    self.out.extend_from_slice(line);
                    self.out.push(b'\n');
                }
            }
        }
        self.stack.pop();
        Ok(())
    }
}

fn preprocess(input: &Input, ws: &Workspace) -> Result<Output> {
    let mut ex = Expander { ws, stack: Vec::new(), discovered: BTreeSet::new(), out: Vec::new() };
    ex.expand(&input.path, &input.content)?;
    let mut depfile = b"kiln-deps 1\n".to_vec();
    for p in &ex.discovered {
        depfile.extend_from_slice(b"need ");
        depfile.extend_from_slice(p);
        depfile.push(b'\n');
    }
    Ok(Output { content: ex.out, depfile: Some(depfile), discovered: ex.discovered.into_iter().collect() })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cmd(name: &str, args: Vec<Value>) -> Command {
        Command::new(lookup(name).unwrap(), args).unwrap()
    }

    fn input(path: &str, content: &str) -> Input {
        let c = content.as_bytes().to_vec();
        Input { path: path.as_bytes().to_vec(), hash: fnv1a(&c), content: Rc::new(c) }
    }

    fn run(c: &Command, inputs: &[Input]) -> Vec<u8> {
        execute(c, inputs, &Workspace::new()).unwrap().content
    }

    #[test]
    fn line_splitting() {
        assert_eq!(lines(b""), Vec::<&[u8]>::new());
        assert_eq!(lines(b"\n"), vec![b"" as &[u8]]);
        assert_eq!(lines(b"a\nb"), vec![b"a" as &[u8], b"b"]);
        assert_eq!(lines(b"a\n\nb\n"), vec![b"a" as &[u8], b"", b"b"]);
    }

    #[test]
    fn canonical_strings() {
        assert_eq!(cmd("write", vec![Value::str("hello\n")]).canonical(), b"write(\"hello\\n\")");
        assert_eq!(cmd("replace", vec![Value::str("a\\b"), Value::str("c")]).canonical(), b"replace(\"a\\\\b\", \"c\")");
        assert_eq!(cmd("indent", vec![Value::Int(4)]).canonical(), b"indent(4)");
        assert_eq!(cmd("concat", vec![]).canonical(), b"concat()");
        assert_eq!(cmd("write", vec![Value::str("\u{1}\u{7f}\"é")]).canonical(), "write(\"\\x01\\x7f\\\"é\")".as_bytes());
    }

    #[test]
    fn simple_commands() {
        let i = [input("a", "b\na\nb\n")];
        assert_eq!(run(&cmd("sort_lines", vec![]), &i), b"a\nb\nb\n");
        assert_eq!(run(&cmd("dedup", vec![]), &i), b"b\na\n");
        assert_eq!(run(&cmd("number", vec![]), &i), b"1: b\n2: a\n3: b\n");
        assert_eq!(run(&cmd("reverse_lines", vec![]), &i), b"b\na\nb\n");
        assert_eq!(run(&cmd("indent", vec![Value::Int(2)]), &i), b"  b\n  a\n  b\n");
        assert_eq!(run(&cmd("grep", vec![Value::str("a")]), &i), b"a\n");
        assert_eq!(run(&cmd("grep", vec![Value::str("")]), &i), b"b\na\nb\n");
        assert_eq!(run(&cmd("wrap", vec![Value::str("<"), Value::str(">")]), &i), b"<b\na\nb\n>");
    }

    #[test]
    fn count_lines_and_hash() {
        let i = [input("src/a.txt", "x\ny\n"), input("src/b.txt", "")];
        assert_eq!(run(&cmd("count_lines", vec![]), &i), b"2 src/a.txt\n0 src/b.txt\n2 total\n");
        let h = run(&cmd("hash", vec![]), &[input("p", "hello\n")]);
        assert_eq!(h, b"a9bc80cca21f28b3 p\n");
    }

    #[test]
    fn preprocess_expands_and_records() {
        let mut ws = Workspace::new();
        ws.write(b"src/part.txt", b"PART\n@need src/deep.txt\n".to_vec());
        ws.write(b"src/deep.txt", b"DEEP\n".to_vec());
        let i = input("src/main.txt", "title\n@need src/part.txt\nend\n");
        let out = execute(&cmd("preprocess", vec![]), &[i], &ws).unwrap();
        assert_eq!(out.content, b"title\nPART\nDEEP\nend\n");
        assert_eq!(out.depfile.unwrap(), b"kiln-deps 1\nneed src/deep.txt\nneed src/part.txt\n");
    }

    #[test]
    fn preprocess_errors() {
        let mut ws = Workspace::new();
        ws.write(b"a", b"@need b\n".to_vec());
        ws.write(b"b", b"@need a\n".to_vec());
        let run_err = |content: &str| {
            let i = input("a", content);
            execute(&cmd("preprocess", vec![]), &[i], &ws).unwrap_err().render()
        };
        assert_eq!(run_err("@need b\n"), b"E_NEED_CYCLE a");
        assert_eq!(run_err("@need nope\n"), b"E_NEED_MISSING nope needed by a");
        assert_eq!(run_err("@need ../x\n"), b"E_NEED_PATH ../x");
        assert_eq!(run_err("@need  b\n"), b"E_NEED_PATH  b");
        // A bare `@need ` is an ordinary line.
        let i = input("a", "@need \n");
        let out = execute(&cmd("preprocess", vec![]), &[i], &ws).unwrap();
        assert_eq!(out.content, b"@need \n");
    }
}
