//! Build steps and phony targets, and the validation applied when a `step`
//! block closes.

use crate::command::Command;
use crate::error::{Error, ErrorKind, Result};
use crate::value::Value;
use crate::workspace::{is_generated, is_ident_shaped, is_workspace_path};

/// One build step.
#[derive(Clone, Debug)]
pub struct Step {
    /// Creation order across the whole build.
    pub serial: usize,
    /// Declared outputs (exactly one after validation).
    pub outputs: Vec<Vec<u8>>,
    pub depfile: Option<Vec<u8>>,
    /// Declared inputs, including `@phony` references.
    pub inputs: Vec<Vec<u8>>,
    /// Order-only dependencies.
    pub after: Vec<Vec<u8>>,
    /// Declared inputs that are files (hashed dependencies).
    pub file_inputs: Vec<Vec<u8>>,
    /// Declared outputs followed by the depfile.
    pub full_outputs: Vec<Vec<u8>>,
    pub command: Command,
    /// The canonical command string.
    pub command_text: Vec<u8>,
    pub cost: u64,
}

impl Step {
    /// The step's primary output.
    pub fn primary(&self) -> &[u8] {
        &self.outputs[0]
    }
}

/// A phony target: a named, ordering-only group of dependencies.
#[derive(Clone, Debug)]
pub struct Phony {
    pub name: String,
    pub deps: Vec<Vec<u8>>,
}

/// Checks that a reference is `@name` or a workspace path.
pub fn check_reference(s: &[u8]) -> Result<()> {
    let ok = match s.strip_prefix(b"@") {
        Some(rest) => is_ident_shaped(rest),
        None => is_workspace_path(s),
    };
    if ok {
        Ok(())
    } else {
        Err(Error::new(ErrorKind::BadPath, s))
    }
}

fn step_field(reason: &str) -> Error {
    Error::new(ErrorKind::StepField, reason)
}

/// Accumulates the fields of a `step` block.
#[derive(Default)]
pub struct StepBuilder {
    pub outputs: Vec<Vec<u8>>,
    pub inputs: Vec<Vec<u8>>,
    pub after: Vec<Vec<u8>>,
    pub cost: Option<i64>,
    pub depfile: Option<Vec<u8>>,
    pub command: Option<Command>,
}

impl StepBuilder {
    /// Validates the completed block and produces the step.
    pub fn finish(self, serial: usize) -> Result<Step> {
        let command = self.command.ok_or_else(|| step_field("missing cmd"))?;
        if self.outputs.is_empty() {
            return Err(step_field("missing out"));
        }
        for p in self.outputs.iter().chain(self.depfile.iter()) {
            if !is_workspace_path(p) {
                return Err(Error::new(ErrorKind::BadPath, p.clone()));
            }
            if !is_generated(p) {
                return Err(Error::new(ErrorKind::OutputPath, p.clone()));
            }
        }
        for p in self.inputs.iter().chain(self.after.iter()) {
            check_reference(p)?;
        }
        let spec = command.spec;
        let file_inputs: Vec<Vec<u8>> = self.inputs.iter().filter(|p| !p.starts_with(b"@")).cloned().collect();
        let m = file_inputs.len();
        if m < spec.min_inputs || m > spec.max_inputs {
            let range = if spec.max_inputs == usize::MAX {
                format!("{}-N", spec.min_inputs)
            } else {
                format!("{}-{}", spec.min_inputs, spec.max_inputs)
            };
            return Err(Error::new(ErrorKind::CmdShape, format!("{}: expected inputs {range}, got {m}", spec.name)));
        }
        if self.outputs.len() != 1 {
            return Err(Error::new(
                ErrorKind::CmdShape,
                format!("{}: expected outputs 1, got {}", spec.name, self.outputs.len()),
            ));
        }
        if spec.uses_depfile && self.depfile.is_none() {
            return Err(Error::new(ErrorKind::CmdShape, format!("{}: depfile required", spec.name)));
        }
        if !spec.uses_depfile && self.depfile.is_some() {
            return Err(Error::new(ErrorKind::CmdShape, format!("{}: depfile not allowed", spec.name)));
        }
        match (spec.name, command.args.as_slice()) {
            ("replace", [Value::Str(from), _]) if from.is_empty() => {
                return Err(Error::arg("cmd", "replace", "empty pattern"));
            }
            ("indent", [Value::Int(n)]) if *n < 0 => {
                return Err(Error::arg("cmd", "indent", "negative"));
            }
            _ => {}
        }
        let mut full_outputs = self.outputs.clone();
        full_outputs.extend(self.depfile.iter().cloned());
        let command_text = command.canonical();
        let cost = match self.cost {
            Some(c) => c as u64,
            None => spec.default_cost,
        };
        Ok(Step {
            serial,
            outputs: self.outputs,
            depfile: self.depfile,
            inputs: self.inputs,
            after: self.after,
            file_inputs,
            full_outputs,
            command,
            command_text,
            cost,
        })
    }
}
