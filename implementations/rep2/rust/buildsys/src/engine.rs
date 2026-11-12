//! One `build`: evaluation, validation, scheduling and state persistence.

use crate::error::{Error, ErrorKind, Result};
use crate::eval::evaluate;
use crate::graph::Graph;
use crate::scheduler::{self, Event};
use crate::state::State;
use crate::workspace::{Workspace, STATE_PATH};

/// The build file every build starts from.
pub const MAIN_FILE: &str = "main.kiln";

/// Summary of a successful build.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Summary {
    /// Commands that executed successfully.
    pub ran: usize,
    /// Cache hits.
    pub hits: usize,
    /// Completion time of the simulated build.
    pub time: u64,
}

/// The full record of one build.
#[derive(Debug)]
pub struct BuildReport {
    /// Events in log order (by start time, then step serial).
    pub events: Vec<Event>,
    /// Success summary, or the single error that stopped the build.
    pub outcome: std::result::Result<Summary, Error>,
}

/// Runs a build of `targets` (or the default targets if empty) on `workers`
/// simulated workers, mutating `ws` (outputs and `.kiln-state`).
///
/// Configuration errors leave the workspace untouched; execution errors still
/// persist the state file.
pub fn build(ws: &mut Workspace, targets: &[String], workers: usize) -> BuildReport {
    match configure(ws, targets) {
        Err(e) => BuildReport {
            events: Vec::new(),
            outcome: Err(e),
        },
        Ok((evaluation, graph, reachable)) => {
            let mut state = State::load(ws);
            let out = scheduler::execute(
                &graph,
                &evaluation.steps,
                &reachable,
                &mut state,
                ws,
                workers.max(1),
            );
            ws.write(STATE_PATH, state.serialize());
            BuildReport {
                events: out.events,
                outcome: match out.error {
                    Some(e) => Err(e),
                    None => Ok(Summary {
                        ran: out.ran,
                        hits: out.hits,
                        time: out.time,
                    }),
                },
            }
        }
    }
}

/// Phases 1–5: everything up to (and including) cycle detection.
fn configure(
    ws: &Workspace,
    targets: &[String],
) -> Result<(crate::eval::Evaluation, Graph, Vec<bool>)> {
    if !ws.contains(MAIN_FILE) {
        return Err(Error::new(ErrorKind::NoBuildFile, MAIN_FILE));
    }
    let evaluation = evaluate(ws, MAIN_FILE)?;
    let mut graph = Graph::build(&evaluation.steps, &evaluation.phonies, ws)?;
    for d in &evaluation.defaults {
        if graph.resolve(d, ws).is_none() {
            return Err(Error::new(ErrorKind::UnknownTarget, d.as_slice()));
        }
    }
    let mut requested: Vec<Vec<u8>> = Vec::new();
    let source: Vec<Vec<u8>> = if targets.is_empty() {
        evaluation.defaults.clone()
    } else {
        targets.iter().map(|t| t.as_bytes().to_vec()).collect()
    };
    for t in source {
        if !requested.contains(&t) {
            requested.push(t);
        }
    }
    if requested.is_empty() {
        return Err(Error::bare(ErrorKind::NoDefault));
    }
    let mut roots = Vec::new();
    for t in &requested {
        match graph.resolve(t, ws) {
            Some(n) => roots.push(n),
            None => return Err(Error::new(ErrorKind::UnknownTarget, t.as_slice())),
        }
    }
    let reachable = graph.reachable(&roots)?;
    Ok((evaluation, graph, reachable))
}
