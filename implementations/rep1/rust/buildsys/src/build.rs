//! One build: configuration phases, the scheduling simulation and the state
//! file update.

use crate::command::{self, Input};
use crate::error::{Error, Result};
use crate::eval::{evaluate, Config};
use crate::hash::fnv1a;
use crate::graph::{Graph, NodeKind};
use crate::state::{Entry, State};
use crate::workspace::{Workspace, STATE_FILE};
use std::cmp::Reverse;
use std::collections::BinaryHeap;
use std::rc::Rc;

/// What happened to a step in the log.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EventKind {
    Hit,
    Run,
    Fail,
    Cancel,
}

/// One line of build output (other than the result line).
#[derive(Clone, Debug)]
pub struct Event {
    pub kind: EventKind,
    pub serial: usize,
    pub start: u64,
    pub end: u64,
    pub worker: usize,
    /// The step's primary output.
    pub target: Vec<u8>,
    /// The step's canonical command.
    pub command: Vec<u8>,
}

/// Totals of a successful build.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Summary {
    pub ran: usize,
    pub hits: usize,
    pub time: u64,
}

/// The outcome of a build: events in log order and the result.
#[derive(Debug)]
pub struct BuildReport {
    pub events: Vec<Event>,
    pub result: Result<Summary>,
}

/// Runs a build of `targets` (the defaults when empty) on `jobs` workers.
///
/// Configuration errors leave the workspace untouched; once execution
/// begins, `.kiln-state` is always rewritten.
pub fn build(ws: &mut Workspace, targets: &[Vec<u8>], jobs: usize) -> BuildReport {
    let config = match evaluate(ws) {
        Ok(c) => c,
        Err(e) => return BuildReport { events: Vec::new(), result: Err(e) },
    };
    let (graph, reachable) = match plan(&config, ws, targets) {
        Ok(p) => p,
        Err(e) => return BuildReport { events: Vec::new(), result: Err(e) },
    };
    let mut state = match ws.get(STATE_FILE) {
        Some(f) => State::parse(&f.content),
        None => State::default(),
    };
    let mut sched = Scheduler::new(&config, &graph, &reachable, jobs.max(1));
    let result = sched.run(ws, &mut state);
    ws.write(STATE_FILE, state.serialize());
    let mut events = sched.events;
    events.sort_by_key(|e| (e.start, e.serial));
    BuildReport { events, result }
}

fn plan(config: &Config, ws: &Workspace, targets: &[Vec<u8>]) -> Result<(Graph, Vec<bool>)> {
    let mut graph = Graph::new(config, ws)?;
    let roots = graph.requested(ws, config, targets)?;
    let reachable = graph.reachable(config, &roots)?;
    Ok((graph, reachable))
}

struct Running {
    serial: usize,
    end: u64,
    event: usize,
    inputs: Vec<Input>,
}

struct Scheduler<'a> {
    config: &'a Config,
    graph: &'a Graph,
    reachable: &'a [bool],
    jobs: usize,
    pending: Vec<usize>,
    dependents: Vec<Vec<usize>>,
    /// Ready steps without a freshness decision yet.
    undecided: BinaryHeap<Reverse<usize>>,
    /// Ready steps decided stale.
    stale: BinaryHeap<Reverse<usize>>,
    workers: Vec<Option<Running>>,
    events: Vec<Event>,
    time: u64,
}

impl<'a> Scheduler<'a> {
    fn new(config: &'a Config, graph: &'a Graph, reachable: &'a [bool], jobs: usize) -> Scheduler<'a> {
        let n = graph.kinds.len();
        let mut pending = vec![0; n];
        let mut dependents: Vec<Vec<usize>> = vec![Vec::new(); n];
        for node in 0..n {
            if !reachable[node] {
                continue;
            }
            pending[node] = graph.succ[node].len();
            for &m in &graph.succ[node] {
                dependents[m].push(node);
            }
        }
        Scheduler {
            config,
            graph,
            reachable,
            jobs,
            pending,
            dependents,
            undecided: BinaryHeap::new(),
            stale: BinaryHeap::new(),
            workers: (0..jobs).map(|_| None).collect(),
            events: Vec::new(),
            time: 0,
        }
    }

    /// Marks `node` complete and releases whatever was waiting on it;
    /// source and phony nodes that become ready complete at once.
    fn complete(&mut self, node: usize) {
        let mut work = vec![node];
        while let Some(n) = work.pop() {
            for k in 0..self.dependents[n].len() {
                let d = self.dependents[n][k];
                self.pending[d] -= 1;
                if self.pending[d] == 0 {
                    match self.graph.kinds[d] {
                        NodeKind::Step(i) => self.undecided.push(Reverse(i)),
                        _ => work.push(d),
                    }
                }
            }
        }
    }

    fn run(&mut self, ws: &mut Workspace, state: &mut State) -> Result<Summary> {
        let (mut ran, mut hits) = (0usize, 0usize);
        let mut max_time = 0u64;
        // Initialisation: sources complete at time 0; phonies with no
        // dependencies likewise; steps with none are ready.
        let initial: Vec<usize> =
            (0..self.graph.kinds.len()).filter(|&n| self.reachable[n] && self.pending[n] == 0).collect();
        for node in initial {
            match self.graph.kinds[node] {
                NodeKind::Step(i) => self.undecided.push(Reverse(i)),
                _ => self.complete(node),
            }
        }
        loop {
            // (A) settle cache hits at the current time.
            while let Some(Reverse(serial)) = self.undecided.pop() {
                let step = &self.config.steps[serial];
                if state.is_fresh(step, ws) {
                    hits += 1;
                    max_time = max_time.max(self.time);
                    self.events.push(Event {
                        kind: EventKind::Hit,
                        serial,
                        start: self.time,
                        end: self.time,
                        worker: 0,
                        target: step.primary().to_vec(),
                        command: step.command_text.clone(),
                    });
                    self.complete(serial);
                } else {
                    self.stale.push(Reverse(serial));
                }
            }
            // (B) dispatch.
            while !self.stale.is_empty() {
                let Some(w) = self.workers.iter().position(Option::is_none) else {
                    break;
                };
                let Reverse(serial) = self.stale.pop().expect("checked non-empty");
                let step = &self.config.steps[serial];
                let end = self.time + step.cost;
                max_time = max_time.max(end);
                let inputs = step
                    .file_inputs
                    .iter()
                    .map(|p| {
                        let f = ws.get(p).expect("file inputs exist once their producers complete");
                        Input { path: p.clone(), content: f.content.clone(), hash: f.hash }
                    })
                    .collect();
                self.events.push(Event {
                    kind: EventKind::Run,
                    serial,
                    start: self.time,
                    end,
                    worker: w,
                    target: step.primary().to_vec(),
                    command: step.command_text.clone(),
                });
                self.workers[w] = Some(Running { serial, end, event: self.events.len() - 1, inputs });
            }
            // (C) advance the clock.
            let Some(next) = self.workers.iter().flatten().map(|r| r.end).min() else {
                break;
            };
            self.time = next;
            let mut failures: Vec<(usize, Error)> = Vec::new();
            let mut finished: Vec<usize> = Vec::new();
            for w in 0..self.jobs {
                if self.workers[w].as_ref().is_none_or(|r| r.end != next) {
                    continue;
                }
                let run = self.workers[w].take().expect("checked");
                let step = &self.config.steps[run.serial];
                match command::execute(&step.command, &run.inputs, ws) {
                    Err(e) => {
                        self.events[run.event].kind = EventKind::Fail;
                        failures.push((run.serial, e));
                    }
                    Ok(out) => {
                        let written = write_outputs(step, out, ws);
                        state.entries.insert(step.primary().to_vec(), record(step, &run.inputs, written));
                        ran += 1;
                        finished.push(run.serial);
                    }
                }
            }
            if !failures.is_empty() {
                let error = failures.iter().min_by_key(|(s, _)| *s).map(|(_, e)| e.clone()).expect("non-empty");
                for run in self.workers.iter_mut().filter_map(Option::take) {
                    self.events[run.event].kind = EventKind::Cancel;
                    state.entries.remove(self.config.steps[run.serial].primary());
                }
                for (s, _) in &failures {
                    state.entries.remove(self.config.steps[*s].primary());
                }
                return Err(error);
            }
            for serial in finished {
                self.complete(serial);
            }
        }
        Ok(Summary { ran, hits, time: max_time })
    }
}

/// Outputs written by a step, with the hashes of what was written and the
/// discovered dependencies with the hashes of what was read.
struct Written {
    outs: Vec<(Vec<u8>, u64)>,
    deps: Vec<(Vec<u8>, u64)>,
}

/// Writes a step's outputs into the workspace, hashing each content once.
fn write_outputs(step: &crate::step::Step, out: command::Output, ws: &mut Workspace) -> Written {
    // Dependency hashes come from the workspace, which holds what the
    // command read (build steps only ever write `out/` paths).
    let deps = out
        .discovered
        .iter()
        .map(|p| (p.clone(), ws.get(p).map(|f| f.hash).expect("discovered files exist")))
        .collect();
    let mut outs = Vec::with_capacity(2);
    let mut put = |path: &[u8], content: Vec<u8>| {
        let h = fnv1a(&content);
        ws.write_hashed(path, Rc::new(content), h);
        outs.push((path.to_vec(), h));
    };
    put(step.primary(), out.content);
    if let (Some(path), Some(content)) = (&step.depfile, out.depfile) {
        put(path, content);
    }
    Written { outs, deps }
}

/// The state entry for a step that just executed successfully.
fn record(step: &crate::step::Step, inputs: &[Input], written: Written) -> Entry {
    Entry {
        cmd: step.command_text.clone(),
        ins: inputs.iter().map(|i| (i.path.clone(), i.hash)).collect(),
        deps: written.deps,
        outs: written.outs,
    }
}
