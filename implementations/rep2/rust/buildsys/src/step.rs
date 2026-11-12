//! Build steps and phony targets as produced by evaluating build files.

use crate::command::Command;
use crate::error::{Error, ErrorKind, Result};
use crate::workspace::{is_generated, is_workspace_path};

/// A build step.
#[derive(Debug, Clone)]
pub struct Step {
    /// Creation order across the whole build (0, 1, 2, …).
    pub serial: usize,
    /// Declared outputs; the first is the primary output.
    pub outputs: Vec<String>,
    /// Declared inputs, including `@phony` references.
    pub inputs: Vec<String>,
    /// Order-only dependencies.
    pub after: Vec<String>,
    /// The depfile path, if any.
    pub depfile: Option<String>,
    /// The cost charged on a worker.
    pub cost: u64,
    /// The command to run.
    pub command: Command,
    /// Declared inputs that are not phony references, in order.
    pub file_inputs: Vec<String>,
    /// Declared outputs followed by the depfile.
    pub full_outputs: Vec<String>,
    /// The canonical command string.
    pub canonical: Vec<u8>,
}

impl Step {
    /// The primary output path, the step's name in messages and the state key.
    pub fn primary(&self) -> &str {
        &self.outputs[0]
    }
}

/// A phony target: a named, ordering-only group of dependencies.
#[derive(Debug, Clone)]
pub struct Phony {
    /// The name, without the leading `@`.
    pub name: String,
    /// Its ordering-only dependencies.
    pub deps: Vec<String>,
}

/// Whether `b` is `@` followed by an identifier-shaped name.
pub fn is_phony_ref(b: &[u8]) -> bool {
    match b.split_first() {
        Some((b'@', rest)) => {
            matches!(rest.first(), Some(c) if c.is_ascii_alphabetic() || *c == b'_')
                && rest.iter().all(|c| c.is_ascii_alphanumeric() || *c == b'_')
        }
        _ => false,
    }
}

/// Checks an `in`, `after` or phony-dependency entry and converts it.
pub fn check_reference(b: &[u8]) -> Result<String> {
    if is_phony_ref(b) || is_workspace_path(b) {
        Ok(String::from_utf8_lossy(b).into_owned())
    } else {
        Err(Error::new(ErrorKind::BadPath, b))
    }
}

/// A step under construction, accumulating the fields of a `step` block.
#[derive(Debug, Default)]
pub struct StepDraft {
    /// Declared outputs, unvalidated.
    pub outs: Vec<Vec<u8>>,
    /// Declared inputs, unvalidated.
    pub ins: Vec<Vec<u8>>,
    /// Order-only dependencies, unvalidated.
    pub after: Vec<Vec<u8>>,
    /// The `cost` field, if given.
    pub cost: Option<u64>,
    /// The `depfile` field, if given.
    pub depfile: Option<Vec<u8>>,
    /// The `cmd` field, if given.
    pub command: Option<Command>,
}

fn step_field(reason: &str) -> Error {
    Error::new(ErrorKind::StepField, reason)
}

impl StepDraft {
    /// Validates the draft at the block's closing brace and builds the step.
    pub fn finish(self, serial: usize) -> Result<Step> {
        let command = self.command.ok_or_else(|| step_field("missing cmd"))?;
        if self.outs.is_empty() {
            return Err(step_field("missing out"));
        }
        let mut outputs = Vec::new();
        for o in self.outs.iter().chain(self.depfile.iter()) {
            output_path(o)?;
        }
        for o in &self.outs {
            outputs.push(String::from_utf8_lossy(o).into_owned());
        }
        let depfile = self
            .depfile
            .map(|d| String::from_utf8_lossy(&d).into_owned());
        let inputs = self
            .ins
            .iter()
            .map(|i| check_reference(i))
            .collect::<Result<Vec<_>>>()?;
        let after = self
            .after
            .iter()
            .map(|i| check_reference(i))
            .collect::<Result<Vec<_>>>()?;
        let file_inputs: Vec<String> = inputs
            .iter()
            .filter(|i| !i.starts_with('@'))
            .cloned()
            .collect();
        command.kind.check_inputs(file_inputs.len())?;
        if outputs.len() != 1 {
            return Err(Error::new(
                ErrorKind::CmdShape,
                format!(
                    "{}: expected outputs 1, got {}",
                    command.kind.name(),
                    outputs.len()
                ),
            ));
        }
        match (command.kind.uses_depfile(), depfile.is_some()) {
            (true, false) => {
                return Err(Error::new(
                    ErrorKind::CmdShape,
                    format!("{}: depfile required", command.kind.name()),
                ))
            }
            (false, true) => {
                return Err(Error::new(
                    ErrorKind::CmdShape,
                    format!("{}: depfile not allowed", command.kind.name()),
                ))
            }
            _ => {}
        }
        command.check_args()?;
        let mut full_outputs = outputs.clone();
        full_outputs.extend(depfile.iter().cloned());
        Ok(Step {
            serial,
            cost: self.cost.unwrap_or_else(|| command.kind.default_cost()),
            canonical: command.canonical(),
            outputs,
            inputs,
            after,
            depfile,
            command,
            file_inputs,
            full_outputs,
        })
    }
}

/// `E_BAD_PATH` then `E_OUTPUT_PATH` for one output path.
fn output_path(p: &[u8]) -> Result<()> {
    if !is_workspace_path(p) {
        return Err(Error::new(ErrorKind::BadPath, p));
    }
    let s = String::from_utf8_lossy(p);
    if !is_generated(&s) {
        return Err(Error::new(ErrorKind::OutputPath, p));
    }
    Ok(())
}


#[cfg(test)]
mod tests {
    use super::*;
    use crate::command::{CmdArg, CmdKind};

    fn draft(outs: &[&str], ins: &[&str], cmd: Command) -> StepDraft {
        StepDraft {
            outs: outs.iter().map(|s| s.as_bytes().to_vec()).collect(),
            ins: ins.iter().map(|s| s.as_bytes().to_vec()).collect(),
            command: Some(cmd),
            ..StepDraft::default()
        }
    }

    fn copy() -> Command {
        Command {
            kind: CmdKind::Copy,
            args: vec![],
        }
    }

    #[test]
    fn phony_reference_shape() {
        assert!(is_phony_ref(b"@all"));
        assert!(is_phony_ref(b"@_x1"));
        assert!(!is_phony_ref(b"@"));
        assert!(!is_phony_ref(b"@1a"));
        assert!(!is_phony_ref(b"@a-b"));
        assert!(!is_phony_ref(b"all"));
    }

    #[test]
    fn validation_order() {
        let e = StepDraft::default().finish(0).unwrap_err();
        assert_eq!(e.to_string(), "E_STEP_FIELD missing cmd");
        let mut d = draft(&[], &[], copy());
        assert_eq!(d.finish(0).unwrap_err().to_string(), "E_STEP_FIELD missing out");
        d = draft(&["src/x"], &["a"], copy());
        assert_eq!(d.finish(0).unwrap_err().to_string(), "E_OUTPUT_PATH src/x");
        d = draft(&["out/x", "bad path"], &["a"], copy());
        assert_eq!(d.finish(0).unwrap_err().to_string(), "E_BAD_PATH bad path");
        d = draft(&["out/x"], &["a", "@p"], copy());
        assert!(d.finish(0).is_ok());
        d = draft(&["out/x"], &["a", "b"], copy());
        assert_eq!(
            d.finish(0).unwrap_err().to_string(),
            "E_CMD_SHAPE copy: expected inputs 1-1, got 2"
        );
        d = draft(&["out/x", "out/y"], &["a"], copy());
        assert_eq!(
            d.finish(0).unwrap_err().to_string(),
            "E_CMD_SHAPE copy: expected outputs 1, got 2"
        );
        let mut d = draft(&["out/x"], &["a"], copy());
        d.depfile = Some(b"out/x.d".to_vec());
        assert_eq!(
            d.finish(0).unwrap_err().to_string(),
            "E_CMD_SHAPE copy: depfile not allowed"
        );
    }

    #[test]
    fn full_outputs_and_defaults() {
        let cmd = Command {
            kind: CmdKind::Preprocess,
            args: vec![],
        };
        let mut d = draft(&["out/x"], &["a"], cmd);
        d.depfile = Some(b"out/x.d".to_vec());
        let s = d.finish(3).unwrap();
        assert_eq!(s.full_outputs, vec!["out/x", "out/x.d"]);
        assert_eq!(s.cost, 6);
        assert_eq!(s.serial, 3);
        let _ = CmdArg::Int(0);
    }
}
