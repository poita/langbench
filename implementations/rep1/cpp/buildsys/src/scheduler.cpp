#include "kiln/scheduler.hpp"

#include <algorithm>
#include <functional>
#include <queue>

#include "kiln/commands.hpp"

namespace kiln {

namespace {

using MinHeap = std::priority_queue<std::size_t, std::vector<std::size_t>, std::greater<>>;

struct Running {
  std::size_t serial = 0;
  std::int64_t start = 0;
  std::int64_t end = 0;
  std::size_t event = 0;           // index into the event list
  CommandResult result;
  std::optional<Error> error;
  StateEntry entry;                // what to record on success
};

class Scheduler {
 public:
  Scheduler(const BuildDescription& desc, const Graph& graph, const std::vector<bool>& reachable,
            Vfs& vfs, BuildState& state, int workers)
      : desc_(desc), graph_(graph), vfs_(vfs), state_(state), workers_(static_cast<std::size_t>(workers)) {
    const std::size_t N = graph.node_count();
    pending_.assign(N, 0);
    dependents_.assign(N, {});
    for (std::size_t n = 0; n < N; ++n) {
      if (!reachable[n]) continue;
      pending_[n] = graph.node(n).succ.size();
      for (std::size_t s : graph.node(n).succ) dependents_[s].push_back(n);
    }
    reachable_ = reachable;
  }

  ScheduleResult run() {
    // Sources complete at time 0; phony nodes with no dependencies do too.
    for (std::size_t n = 0; n < graph_.node_count(); ++n) {
      if (!reachable_[n] || pending_[n] != 0) continue;
      if (graph_.node(n).kind == NodeKind::Step) undecided_.push(n);
      else complete(n);
    }

    std::vector<std::optional<Running>> running(workers_);
    std::int64_t time = 0;
    std::int64_t last = 0;

    while (true) {
      // (A) settle cache hits at the current time.
      while (!undecided_.empty()) {
        std::size_t n = undecided_.top();
        undecided_.pop();
        const StepDef& step = desc_.steps[n];
        if (is_fresh(step, state_, vfs_)) {
          ++res_.hits;
          res_.events.push_back(BuildEvent{BuildEvent::Kind::Hit, time, time, 0, n, step.primary(), step.canonical()});
          last = std::max(last, time);
          complete(n);
        } else {
          stale_.push(n);
        }
      }

      // (B) dispatch.
      while (!stale_.empty()) {
        auto free_w = std::find_if(running.begin(), running.end(), [](const auto& r) { return !r; });
        if (free_w == running.end()) break;
        std::size_t n = stale_.top();
        stale_.pop();
        *free_w = dispatch(n, time, static_cast<int>(free_w - running.begin()));
        last = std::max(last, (*free_w)->end);
      }

      // (C) advance the clock.
      std::int64_t next = -1;
      for (const auto& r : running) {
        if (r && (next < 0 || r->end < next)) next = r->end;
      }
      if (next < 0) break;
      time = next;
      std::vector<std::size_t> failed;
      std::vector<std::size_t> finished;
      for (std::size_t w = 0; w < running.size(); ++w) {
        if (!running[w] || running[w]->end != time) continue;
        Running r = std::move(*running[w]);
        running[w].reset();
        if (r.error) {
          res_.events[r.event].kind = BuildEvent::Kind::Fail;
          failed.push_back(r.serial);
          errors_.emplace_back(r.serial, *r.error);
        } else {
          commit(r);
          ++res_.ran;
          finished.push_back(r.serial);
        }
      }
      if (!failed.empty()) {
        auto best = std::min_element(errors_.begin(), errors_.end(),
                                     [](const auto& a, const auto& b) { return a.first < b.first; });
        res_.error = best->second;
        for (auto& r : running) {
          if (!r) continue;
          res_.events[r->event].kind = BuildEvent::Kind::Cancel;
          state_.erase(desc_.steps[r->serial].primary());
        }
        for (std::size_t n : failed) state_.erase(desc_.steps[n].primary());
        break;
      }
      for (std::size_t n : finished) complete(n);
    }

    res_.time = last;
    std::stable_sort(res_.events.begin(), res_.events.end(), [](const BuildEvent& a, const BuildEvent& b) {
      return a.start != b.start ? a.start < b.start : a.serial < b.serial;
    });
    return std::move(res_);
  }

 private:
  /// Marks a node complete and cascades through nodes that become ready.
  void complete(std::size_t first) {
    std::vector<std::size_t> work{first};
    while (!work.empty()) {
      std::size_t n = work.back();
      work.pop_back();
      for (std::size_t d : dependents_[n]) {
        if (--pending_[d] != 0) continue;
        if (graph_.node(d).kind == NodeKind::Step) undecided_.push(d);
        else work.push_back(d);
      }
    }
  }

  Running dispatch(std::size_t n, std::int64_t time, int worker) {
    const StepDef& step = desc_.steps[n];
    Running r;
    r.serial = n;
    r.start = time;
    r.end = time + step.cost;
    res_.events.push_back(BuildEvent{BuildEvent::Kind::Run, time, r.end, worker, n, step.primary(), step.canonical()});
    r.event = res_.events.size() - 1;

    // The command reads everything it needs now.
    std::vector<CommandInput> inputs;
    r.entry.command = step.canonical();
    for (const auto& path : step.file_inputs()) {
      Vfs::Content c = vfs_.read(path);
      if (!c) c = std::make_shared<const std::string>();
      inputs.push_back(CommandInput{path, c});
      r.entry.inputs.emplace_back(path, vfs_.exists(path) ? vfs_.hash(path) : fnv_empty());
    }
    try {
      r.result = run_command(*step.command, step.args, inputs, vfs_);
      for (const auto& d : r.result.discovered) r.entry.deps.emplace_back(d, vfs_.hash(d));
    } catch (const Error& e) {
      r.error = e;
    }
    return r;
  }

  static std::uint64_t fnv_empty() { return 0xcbf29ce484222325ULL; }

  void commit(Running& r) {
    const StepDef& step = desc_.steps[r.serial];
    vfs_.write(step.primary(), std::move(r.result.output));
    r.entry.outputs.emplace_back(step.primary(), vfs_.hash(step.primary()));
    if (!step.depfile.empty()) {
      vfs_.write(step.depfile, std::move(r.result.depfile));
      r.entry.outputs.emplace_back(step.depfile, vfs_.hash(step.depfile));
    }
    state_.put(step.primary(), std::move(r.entry));
  }

  const BuildDescription& desc_;
  const Graph& graph_;
  Vfs& vfs_;
  BuildState& state_;
  std::size_t workers_;
  std::vector<bool> reachable_;
  std::vector<std::size_t> pending_;
  std::vector<std::vector<std::size_t>> dependents_;
  MinHeap undecided_, stale_;
  ScheduleResult res_;
  std::vector<std::pair<std::size_t, Error>> errors_;
};

}  // namespace

ScheduleResult run_schedule(const BuildDescription& desc, const Graph& graph,
                            const std::vector<bool>& reachable, Vfs& vfs, BuildState& state,
                            int workers) {
  return Scheduler(desc, graph, reachable, vfs, state, workers).run();
}

}  // namespace kiln
