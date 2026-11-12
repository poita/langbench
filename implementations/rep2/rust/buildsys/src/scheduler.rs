//! The deterministic event-driven scheduler: freshness settling, worker
//! dispatch, clock advance, failure and cancellation.

use std::cmp::Reverse;
use std::collections::BinaryHeap;

use crate::command::{self, Execution};
use crate::error::{Error, Result};
use crate::graph::{Graph, NodeKind};
use crate::state::{is_fresh, Entry, State};
use crate::step::Step;
use crate::workspace::Workspace;

/// What happened to a step in a build.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EventKind {
    /// Found fresh; nothing ran.
    Hit,
    /// Executed successfully.
    Run,
    /// Executed and failed.
    Fail,
    /// Dispatched but still running when the build aborted.
    Cancel,
}

/// One line of a build's event log.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Event {
    /// What happened.
    pub kind: EventKind,
    /// Start time (for a hit, the time of the hit).
    pub start: u64,
    /// End time (for a hit, the time of the hit).
    pub end: u64,
    /// Worker id (0 for hits, which use no worker).
    pub worker: usize,
    /// The step's primary output.
    pub target: String,
    /// The canonical command string.
    pub command: Vec<u8>,
    serial: usize,
}

/// The outcome of the scheduling phase.
pub struct Outcome {
    pub events: Vec<Event>,
    pub ran: usize,
    pub hits: usize,
    pub time: u64,
    pub error: Option<Error>,
}

struct Running {
    serial: usize,
    end: u64,
    event: usize,
    result: Result<Execution>,
}

struct Sched<'a> {
    graph: &'a Graph,
    pending: Vec<usize>,
    dependents: Vec<Vec<usize>>,
    undecided: BinaryHeap<Reverse<usize>>,
    stale: BinaryHeap<Reverse<usize>>,
}

impl Sched<'_> {
    /// Completes node `n`, cascading through source and phony nodes.
    fn complete(&mut self, n: usize) {
        let mut work = vec![n];
        while let Some(x) = work.pop() {
            for k in 0..self.dependents[x].len() {
                let d = self.dependents[x][k];
                self.pending[d] -= 1;
                if self.pending[d] == 0 {
                    match self.graph.nodes()[d].kind {
                        NodeKind::Step(serial) => self.undecided.push(Reverse(serial)),
                        _ => work.push(d),
                    }
                }
            }
        }
    }
}

/// Runs the reachable steps on `workers` simulated workers.
pub fn execute(
    graph: &Graph,
    steps: &[Step],
    reachable: &[bool],
    state: &mut State,
    ws: &mut Workspace,
    workers: usize,
) -> Outcome {
    let n_nodes = graph.nodes().len();
    let mut s = Sched {
        graph,
        pending: vec![0; n_nodes],
        dependents: vec![Vec::new(); n_nodes],
        undecided: BinaryHeap::new(),
        stale: BinaryHeap::new(),
    };
    for (n, node) in graph.nodes().iter().enumerate() {
        if !reachable[n] {
            continue;
        }
        s.pending[n] = node.succ.len();
        for &m in &node.succ {
            s.dependents[m].push(n);
        }
    }
    // Initialisation: steps with nothing to wait for are ready; sources and
    // childless phonies complete at time 0, cascading.
    let mut instant = Vec::new();
    for (n, node) in graph.nodes().iter().enumerate() {
        if !reachable[n] || s.pending[n] != 0 {
            continue;
        }
        match node.kind {
            NodeKind::Step(serial) => s.undecided.push(Reverse(serial)),
            _ => instant.push(n),
        }
    }
    for n in instant {
        s.complete(n);
    }

    let mut events: Vec<Event> = Vec::new();
    let mut running: Vec<Option<Running>> = (0..workers).map(|_| None).collect();
    let mut time = 0u64;
    let (mut ran, mut hits) = (0usize, 0usize);
    let mut error = None;

    loop {
        // (A) settle cache hits at the current time.
        while let Some(Reverse(serial)) = s.undecided.pop() {
            let step = &steps[serial];
            if is_fresh(step, state.get(step.primary()), ws) {
                hits += 1;
                events.push(Event {
                    kind: EventKind::Hit,
                    start: time,
                    end: time,
                    worker: 0,
                    target: step.primary().to_string(),
                    command: step.canonical.clone(),
                    serial,
                });
                s.complete(serial);
            } else {
                s.stale.push(Reverse(serial));
            }
        }
        // (B) dispatch.
        while !s.stale.is_empty() {
            let Some(w) = running.iter().position(Option::is_none) else {
                break;
            };
            let Reverse(serial) = s.stale.pop().expect("checked non-empty");
            let step = &steps[serial];
            let end = time + step.cost;
            events.push(Event {
                kind: EventKind::Run,
                start: time,
                end,
                worker: w,
                target: step.primary().to_string(),
                command: step.canonical.clone(),
                serial,
            });
            let result = command::execute(
                &step.command,
                &step.file_inputs,
                &step.outputs,
                step.depfile.as_deref(),
                ws,
            );
            running[w] = Some(Running {
                serial,
                end,
                event: events.len() - 1,
                result,
            });
        }
        // (C) advance the clock.
        let Some(next) = running.iter().flatten().map(|r| r.end).min() else {
            break;
        };
        time = next;
        let mut failed: Vec<(usize, Error)> = Vec::new();
        let mut completed = Vec::new();
        for slot in running.iter_mut() {
            if slot.as_ref().is_none_or(|r| r.end != time) {
                continue;
            }
            let r = slot.take().expect("checked above");
            let step = &steps[r.serial];
            match r.result {
                Err(e) => {
                    events[r.event].kind = EventKind::Fail;
                    failed.push((r.serial, e));
                }
                Ok(exec) => {
                    let mut outs = Vec::new();
                    for (path, data) in exec.outputs {
                        ws.write(&path, data);
                        outs.push((path.clone(), ws.hash(&path).unwrap_or(0)));
                    }
                    state.insert(
                        step.primary().to_string(),
                        Entry {
                            cmd: step.canonical.clone(),
                            ins: exec.inputs,
                            deps: exec.deps,
                            outs,
                        },
                    );
                    ran += 1;
                    completed.push(r.serial);
                }
            }
        }
        if !failed.is_empty() {
            for r in running.iter().flatten() {
                events[r.event].kind = EventKind::Cancel;
                state.remove(steps[r.serial].primary());
            }
            for (serial, _) in &failed {
                state.remove(steps[*serial].primary());
            }
            let (_, e) = failed
                .into_iter()
                .min_by_key(|(serial, _)| *serial)
                .expect("non-empty");
            error = Some(e);
            break;
        }
        for serial in completed {
            s.complete(serial);
        }
    }

    let total = events.iter().map(|e| e.end).max().unwrap_or(0);
    events.sort_by_key(|e| (e.start, e.serial));
    Outcome {
        events,
        ran,
        hits,
        time: total,
        error,
    }
}
