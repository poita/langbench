//! The script driver: parse `commands.txt`, run each command and write the
//! result files.

use crate::chol::cholesky;
use crate::error::LinalgError;
use crate::matrix::Matrix;
use crate::{eig, lu, mmio, qr, svd};
use std::collections::HashMap;
use std::fmt;
use std::fs;
use std::io;
use std::path::Path;
use std::rc::Rc;

/// The sixteen supported operations.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Op {
    Add,
    Mul,
    Transpose,
    Lu,
    Det,
    Inv,
    Solve,
    Qr,
    Chol,
    Eig,
    Svd,
    Lstsq,
    Norm1,
    NormInf,
    NormFro,
    Cond,
}

impl Op {
    /// Look an operation up by its exact (lower-case) name.
    pub fn from_name(name: &str) -> Option<Op> {
        Some(match name {
            "add" => Op::Add,
            "mul" => Op::Mul,
            "transpose" => Op::Transpose,
            "lu" => Op::Lu,
            "det" => Op::Det,
            "inv" => Op::Inv,
            "solve" => Op::Solve,
            "qr" => Op::Qr,
            "chol" => Op::Chol,
            "eig" => Op::Eig,
            "svd" => Op::Svd,
            "lstsq" => Op::Lstsq,
            "norm1" => Op::Norm1,
            "norminf" => Op::NormInf,
            "normfro" => Op::NormFro,
            "cond" => Op::Cond,
            _ => return None,
        })
    }

    /// The operation's name as written in a script.
    pub fn name(&self) -> &'static str {
        match self {
            Op::Add => "add",
            Op::Mul => "mul",
            Op::Transpose => "transpose",
            Op::Lu => "lu",
            Op::Det => "det",
            Op::Inv => "inv",
            Op::Solve => "solve",
            Op::Qr => "qr",
            Op::Chol => "chol",
            Op::Eig => "eig",
            Op::Svd => "svd",
            Op::Lstsq => "lstsq",
            Op::Norm1 => "norm1",
            Op::NormInf => "norminf",
            Op::NormFro => "normfro",
            Op::Cond => "cond",
        }
    }

    /// Number of matrix arguments.
    pub fn arity(&self) -> usize {
        match self {
            Op::Add | Op::Mul | Op::Solve | Op::Lstsq => 2,
            _ => 1,
        }
    }
}

/// One parsed command line.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Command {
    /// The operation.
    pub op: Op,
    /// Matrix file names, in order.
    pub args: Vec<String>,
}

/// A problem in a script or in running one.
#[derive(Debug)]
pub enum ScriptError {
    /// A malformed command line (1-based command number and reason).
    Syntax(usize, String),
    /// Reading or writing a file failed.
    Io(String, io::Error),
    /// A matrix file could not be parsed.
    Parse(String, mmio::ParseError),
}

impl fmt::Display for ScriptError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ScriptError::Syntax(n, msg) => write!(f, "command {n}: {msg}"),
            ScriptError::Io(path, e) => write!(f, "{path}: {e}"),
            ScriptError::Parse(path, e) => write!(f, "{path}: {e}"),
        }
    }
}

impl std::error::Error for ScriptError {}

/// Parse the text of a `commands.txt`. Blank lines and `#` comments are
/// skipped and do not count as commands.
pub fn parse_commands(text: &str) -> Result<Vec<Command>, ScriptError> {
    let mut cmds = Vec::new();
    for line in text.lines() {
        let line = line.trim_matches(|c| c == ' ' || c == '\t' || c == '\r');
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let n = cmds.len() + 1;
        let mut toks = line.split([' ', '\t']).filter(|t| !t.is_empty());
        let name = toks.next().unwrap();
        let op = Op::from_name(name)
            .ok_or_else(|| ScriptError::Syntax(n, format!("unknown operation {name:?}")))?;
        let args: Vec<String> = toks.map(str::to_string).collect();
        if args.len() != op.arity() {
            return Err(ScriptError::Syntax(
                n,
                format!("{} takes {} argument(s), got {}", name, op.arity(), args.len()),
            ));
        }
        cmds.push(Command { op, args });
    }
    Ok(cmds)
}

/// What a command produced: named result matrices, or an error.
pub type Outcome = Result<Vec<(&'static str, Matrix)>, LinalgError>;

fn column(values: &[f64]) -> Matrix {
    Matrix::from_vec(values.len(), 1, values.to_vec())
}

fn scalar(v: f64) -> Matrix {
    Matrix::from_vec(1, 1, vec![v])
}

/// Execute one operation on already-loaded matrices.
///
/// `args` must hold exactly `op.arity()` matrices. The result is a list of
/// `(file suffix, matrix)` pairs, or the error the operation raised.
pub fn execute(op: Op, args: &[&Matrix]) -> Outcome {
    let a = args[0];
    let one = |name: &'static str, m: Matrix| -> Outcome { Ok(vec![(name, m)]) };
    match op {
        Op::Add => one("add", a.add(args[1])?),
        Op::Mul => one("mul", a.mul(args[1])?),
        Op::Transpose => one("transpose", a.transpose()),
        Op::Lu => {
            let f = lu::Lu::factor(a)?;
            Ok(vec![("lu_P", f.p()), ("lu_L", f.l()), ("lu_U", f.u())])
        }
        Op::Det => one("det", scalar(lu::det(a)?)),
        Op::Inv => one("inv", lu::inverse(a)?),
        Op::Solve => one("solve", lu::solve(a, args[1])?),
        Op::Qr => {
            let f = qr::qr(a)?;
            Ok(vec![("qr_Q", f.q), ("qr_R", f.r)])
        }
        Op::Chol => one("chol_L", cholesky(a)?),
        Op::Eig => {
            let e = eig::eigh(a)?;
            Ok(vec![("eig_w", column(&e.values)), ("eig_V", e.vectors)])
        }
        Op::Svd => {
            let f = svd::svd(a);
            Ok(vec![("svd_U", f.u), ("svd_S", column(&f.s)), ("svd_V", f.v)])
        }
        Op::Lstsq => one("lstsq", qr::lstsq(a, args[1])?),
        Op::Norm1 => one("norm1", scalar(a.norm1())),
        Op::NormInf => one("norminf", scalar(a.norm_inf())),
        Op::NormFro => one("normfro", scalar(a.norm_fro())),
        Op::Cond => one("cond", scalar(svd::cond(a)?)),
    }
}

fn io_err(path: &Path, e: io::Error) -> ScriptError {
    ScriptError::Io(path.display().to_string(), e)
}

/// Run the script in `input_dir/commands.txt`, writing result files into
/// `output_dir` (which must already exist).
pub fn run_dir(input_dir: &Path, output_dir: &Path) -> Result<(), ScriptError> {
    let cmd_path = input_dir.join("commands.txt");
    let text = fs::read_to_string(&cmd_path).map_err(|e| io_err(&cmd_path, e))?;
    let commands = parse_commands(&text)?;
    let mut cache: HashMap<String, Rc<Matrix>> = HashMap::new();
    for (idx, cmd) in commands.iter().enumerate() {
        let number = idx + 1;
        let mut mats: Vec<Rc<Matrix>> = Vec::new();
        for name in &cmd.args {
            if !cache.contains_key(name) {
                let path = input_dir.join(name);
                let body = fs::read_to_string(&path).map_err(|e| io_err(&path, e))?;
                let m = mmio::parse(&body)
                    .map_err(|e| ScriptError::Parse(path.display().to_string(), e))?;
                cache.insert(name.clone(), Rc::new(m));
            }
            mats.push(Rc::clone(&cache[name]));
        }
        let refs: Vec<&Matrix> = mats.iter().map(|m| m.as_ref()).collect();
        match execute(cmd.op, &refs) {
            Ok(results) => {
                for (suffix, m) in results {
                    let path = output_dir.join(format!("{number:03}_{suffix}.mtx"));
                    fs::write(&path, mmio::write(&m)).map_err(|e| io_err(&path, e))?;
                }
            }
            Err(e) => {
                let path = output_dir.join(format!("{number:03}_error.txt"));
                fs::write(&path, format!("{}\n", e.code())).map_err(|e| io_err(&path, e))?;
            }
        }
    }
    Ok(())
}


#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_and_numbers_commands() {
        let cmds = parse_commands("# c\n\n  add \t a.mtx   b.mtx \n\t# x\ndet a.mtx\n").unwrap();
        assert_eq!(cmds.len(), 2);
        assert_eq!(cmds[0].op, Op::Add);
        assert_eq!(cmds[0].args, vec!["a.mtx", "b.mtx"]);
        assert_eq!(cmds[1].op, Op::Det);
    }

    #[test]
    fn rejects_bad_commands() {
        assert!(parse_commands("frobnicate a.mtx\n").is_err());
        assert!(parse_commands("add a.mtx\n").is_err());
        assert!(parse_commands("det a.mtx b.mtx\n").is_err());
        assert!(parse_commands("ADD a b\n").is_err());
    }

    #[test]
    fn execute_reports_errors() {
        let a = Matrix::zeros(2, 3);
        assert_eq!(execute(Op::Chol, &[&a]).unwrap_err(), LinalgError::NotSquare);
        let r = execute(Op::Norm1, &[&a]).unwrap();
        assert_eq!(r[0].0, "norm1");
    }
}
