#include "kiln/engine.hpp"

#include <algorithm>
#include <functional>
#include <queue>

#include "kiln/commands.hpp"
#include "kiln/graph.hpp"
#include "kiln/interp.hpp"
#include "kiln/state.hpp"

namespace kiln {

namespace {

using MinHeap = std::priority_queue<int, std::vector<int>, std::greater<int>>;

/// A dispatched command: its result is computed at dispatch (all reads happen
/// at the start time) and applied at its end time.
struct Running {
  bool active = false;
  int serial = 0;
  std::int64_t start = 0, end = 0;
  std::size_t eventIndex = 0;
  std::optional<Error> error;
  CommandResult result;
  StateEntry entry;  // inputs and discovered deps, hashed at start time
};

class Scheduler {
 public:
  Scheduler(const BuildPlan& plan, const Graph& graph, const std::vector<char>& reachable,
            int jobs, Vfs& vfs, BuildState& state, BuildReport& report)
      : plan_(plan), graph_(graph), vfs_(vfs), state_(state), report_(report),
        workers_(static_cast<std::size_t>(jobs < 1 ? 1 : jobs)) {
    const std::size_t N = graph.size();
    pending_.assign(N, 0);
    dependents_.assign(N, {});
    for (std::size_t n = 0; n < N; ++n) {
      if (!reachable[n]) continue;
      for (int m : graph.node(static_cast<int>(n)).succ) {
        ++pending_[n];
        dependents_[static_cast<std::size_t>(m)].push_back(static_cast<int>(n));
      }
    }
    std::vector<int> instant;
    for (std::size_t n = 0; n < N; ++n) {
      if (!reachable[n] || pending_[n] != 0) continue;
      if (graph.node(static_cast<int>(n)).kind == Node::StepNode) undecided_.push(static_cast<int>(n));
      else instant.push_back(static_cast<int>(n));
    }
    for (int n : instant) complete(n);
  }

  void run() {
    std::int64_t time = 0;
    std::int64_t maxTime = 0;
    while (true) {
      // (A) settle cache hits at the current time.
      while (!undecided_.empty()) {
        int n = undecided_.top();
        undecided_.pop();
        const Step& st = plan_.steps[static_cast<std::size_t>(n)];
        if (isFresh(st, state_, vfs_)) {
          ++report_.hits;
          Event ev;
          ev.kind = Event::Hit;
          ev.serial = n;
          ev.start = ev.end = time;
          ev.target = st.primary();
          ev.command = st.canonical;
          report_.events.push_back(std::move(ev));
          maxTime = std::max(maxTime, time);
          complete(n);
        } else {
          stale_.push(n);
        }
      }
      // (B) dispatch.
      while (!stale_.empty()) {
        std::size_t w = 0;
        while (w < workers_.size() && workers_[w].active) ++w;
        if (w == workers_.size()) break;
        int n = stale_.top();
        stale_.pop();
        dispatch(n, w, time);
        maxTime = std::max(maxTime, workers_[w].end);
      }
      // (C) advance the clock.
      std::int64_t next = -1;
      for (const auto& r : workers_)
        if (r.active && (next < 0 || r.end < next)) next = r.end;
      if (next < 0) break;
      time = next;
      std::vector<int> failed;
      std::vector<int> done;
      for (std::size_t w = 0; w < workers_.size(); ++w) {
        Running& r = workers_[w];
        if (!r.active || r.end != time) continue;
        r.active = false;
        const Step& st = plan_.steps[static_cast<std::size_t>(r.serial)];
        if (r.error) {
          report_.events[r.eventIndex].kind = Event::Fail;
          failed.push_back(r.serial);
        } else {
          finishStep(st, r);
          ++report_.ran;
          done.push_back(r.serial);
        }
      }
      if (!failed.empty()) {
        int first = *std::min_element(failed.begin(), failed.end());
        for (std::size_t w = 0; w < workers_.size(); ++w) {
          Running& r = workers_[w];
          if (!r.active) continue;
          report_.events[r.eventIndex].kind = Event::Cancel;
          state_.erase(plan_.steps[static_cast<std::size_t>(r.serial)].primary());
          r.active = false;
        }
        for (int n : failed) state_.erase(plan_.steps[static_cast<std::size_t>(n)].primary());
        // The error of the lowest-serial failing step.
        report_.error = errorOf_.at(first);
        break;
      }
      // Completions happen in ascending worker order, which `done` preserves.
      for (int n : done) complete(n);
    }
    report_.time = maxTime;
    std::stable_sort(report_.events.begin(), report_.events.end(),
                     [](const Event& a, const Event& b) {
                       if (a.start != b.start) return a.start < b.start;
                       return a.serial < b.serial;
                     });
  }

 private:
  void complete(int start) {
    std::vector<int> work{start};
    while (!work.empty()) {
      int n = work.back();
      work.pop_back();
      for (int d : dependents_[static_cast<std::size_t>(n)]) {
        if (--pending_[static_cast<std::size_t>(d)] != 0) continue;
        if (graph_.node(d).kind == Node::StepNode) undecided_.push(d);
        else work.push_back(d);
      }
    }
  }

  void dispatch(int n, std::size_t w, std::int64_t time) {
    const Step& st = plan_.steps[static_cast<std::size_t>(n)];
    Running& r = workers_[w];
    r = Running{};
    r.active = true;
    r.serial = n;
    r.start = time;
    r.end = time + st.cost;

    std::vector<std::string> files = st.fileInputs();
    std::vector<Content> inputs;
    static const Content empty = std::make_shared<const std::string>();
    for (const auto& p : files) {
      Content c = vfs_.read(p);
      inputs.push_back(c ? c : empty);
      r.entry.ins.emplace_back(p, vfs_.exists(p) ? vfs_.hash(p) : 0xcbf29ce484222325ULL);
    }
    try {
      r.result = runCommand(st, inputs, vfs_);
      for (const auto& d : r.result.discovered) r.entry.deps.emplace_back(d, vfs_.hash(d));
    } catch (const Error& e) {
      r.error = e;
      errorOf_.emplace(n, e);
    }
    Event ev;
    ev.kind = Event::Run;
    ev.serial = n;
    ev.start = r.start;
    ev.end = r.end;
    ev.worker = static_cast<int>(w);
    ev.target = st.primary();
    ev.command = st.canonical;
    r.eventIndex = report_.events.size();
    report_.events.push_back(std::move(ev));
  }

  void finishStep(const Step& st, Running& r) {
    vfs_.write(st.primary(), std::move(r.result.output));
    if (st.depfile && r.result.depfile) vfs_.write(*st.depfile, std::move(*r.result.depfile));
    StateEntry e = std::move(r.entry);
    e.cmd = st.canonical;
    for (const auto& p : st.fullOutputs()) e.outs.emplace_back(p, vfs_.hash(p));
    state_.replace(st.primary(), std::move(e));
  }

  const BuildPlan& plan_;
  const Graph& graph_;
  Vfs& vfs_;
  BuildState& state_;
  BuildReport& report_;
  std::vector<Running> workers_;
  std::vector<int> pending_;
  std::vector<std::vector<int>> dependents_;
  MinHeap undecided_, stale_;
  std::unordered_map<int, Error> errorOf_;
};

}  // namespace

BuildReport runBuild(Vfs& vfs, const std::vector<std::string>& targets, int jobs) {
  BuildReport report;
  BuildPlan plan;
  std::optional<Graph> graph;
  std::vector<char> reachable;
  try {
    Evaluator evaluator(vfs);
    plan = evaluator.evaluate();
    graph.emplace(Graph::build(plan, vfs));
    std::vector<int> roots = graph->requestedRoots(plan, targets);
    reachable = graph->reachableFrom(roots);
  } catch (const Error& e) {
    report.error = e;
    return report;
  }
  report.executed = true;
  BuildState state = BuildState::load(vfs);
  Scheduler scheduler(plan, *graph, reachable, jobs, vfs, state, report);
  scheduler.run();
  state.save(vfs);
  return report;
}

}  // namespace kiln
