#include "sat/solver.hpp"

#include <algorithm>
#include <cassert>

#include "sat/luby.hpp"

namespace sat {

namespace {
constexpr double kVarDecay = 1.0 / 0.95;
constexpr double kClaDecay = 1.0 / 0.999;
constexpr double kVarRescaleLimit = 1e100;
constexpr double kVarRescale = 1e-100;
constexpr double kClaRescaleLimit = 1e20;
constexpr double kClaRescale = 1e-20;
constexpr std::int64_t kRestartUnit = 100;
constexpr double kLearntGrowth = 1.1;
constexpr int kMinMaxLearnts = 2000;
}  // namespace

Solver::Solver() : order_(activity_) {}
Solver::~Solver() = default;

Var Solver::newVar() {
  Var v = numVars();
  assigns_.push_back(LBool::Undef);
  level_.push_back(0);
  reason_.push_back(nullptr);
  activity_.push_back(0.0);
  polarity_.push_back(0);  // phase saving starts at "false"
  seen_.push_back(0);
  watches_.emplace_back();
  watches_.emplace_back();
  order_.insert(v);
  return v;
}

void Solver::reserveVars(int n) {
  while (numVars() < n) newVar();
}

bool Solver::addClause(std::initializer_list<int> dimacsLits) {
  std::vector<Lit> lits;
  lits.reserve(dimacsLits.size());
  for (int d : dimacsLits) lits.push_back(Lit::fromDimacs(d));
  return addClause(std::move(lits));
}

bool Solver::addClause(std::vector<Lit> lits) {
  assert(decisionLevel() == 0);
  if (!ok_) return false;
  for (Lit l : lits) reserveVars(l.var() + 1);

  std::sort(lits.begin(), lits.end());
  std::size_t j = 0;
  Lit prev;  // undefined; never equals a real literal
  for (std::size_t i = 0; i < lits.size(); ++i) {
    Lit l = lits[i];
    if (value(l) == LBool::True || l == ~prev) return true;  // satisfied / tautology
    if (value(l) != LBool::False && l != prev) lits[j++] = prev = l;
  }
  lits.resize(j);

  if (lits.empty()) return ok_ = false;
  if (lits.size() == 1) {
    enqueue(lits[0], nullptr);
    return ok_ = (propagate() == nullptr);
  }
  auto c = std::make_unique<Clause>();
  c->lits = std::move(lits);
  attach(c.get());
  clauses_.push_back(std::move(c));
  return true;
}

void Solver::attach(Clause* c) {
  assert(c->lits.size() >= 2);
  watches_[c->lits[0].index()].push_back({c, c->lits[1]});
  watches_[c->lits[1].index()].push_back({c, c->lits[0]});
}

void Solver::enqueue(Lit p, Clause* from) {
  assert(value(p) == LBool::Undef);
  assigns_[p.var()] = p.negated() ? LBool::False : LBool::True;
  level_[p.var()] = decisionLevel();
  reason_[p.var()] = from;
  trail_.push_back(p);
}

Solver::Clause* Solver::propagate() {
  Clause* conflict = nullptr;
  while (qhead_ < trail_.size()) {
    Lit p = trail_[qhead_++];
    Lit falseLit = ~p;
    ++stats_.propagations;
    std::vector<Watcher>& ws = watches_[falseLit.index()];
    std::size_t i = 0, j = 0;
    while (i < ws.size()) {
      Watcher w = ws[i];
      if (value(w.blocker) == LBool::True) {
        ws[j++] = ws[i++];
        continue;
      }
      Clause& c = *w.clause;
      if (c.lits[0] == falseLit) std::swap(c.lits[0], c.lits[1]);
      assert(c.lits[1] == falseLit);
      ++i;
      Lit first = c.lits[0];
      Watcher nw{&c, first};
      if (first != w.blocker && value(first) == LBool::True) {
        ws[j++] = nw;
        continue;
      }
      bool moved = false;
      for (std::size_t k = 2; k < c.lits.size(); ++k) {
        if (value(c.lits[k]) != LBool::False) {
          std::swap(c.lits[1], c.lits[k]);
          watches_[c.lits[1].index()].push_back(nw);
          moved = true;
          break;
        }
      }
      if (moved) continue;
      ws[j++] = nw;
      if (value(first) == LBool::False) {
        conflict = &c;
        qhead_ = trail_.size();
        while (i < ws.size()) ws[j++] = ws[i++];
      } else {
        enqueue(first, &c);
      }
    }
    ws.resize(j);
  }
  return conflict;
}

void Solver::analyze(Clause* conflict, std::vector<Lit>& learnt, int& backtrackLevel) {
  learnt.clear();
  learnt.push_back(Lit());  // placeholder for the asserting literal
  int pathCount = 0;
  Lit p;
  bool first = true;
  int idx = static_cast<int>(trail_.size()) - 1;
  Clause* c = conflict;

  do {
    assert(c != nullptr);
    if (c->learnt) bumpClause(c);
    for (std::size_t k = first ? 0 : 1; k < c->lits.size(); ++k) {
      Lit q = c->lits[k];
      Var v = q.var();
      if (seen_[v] || level_[v] == 0) continue;
      bumpVar(v);
      seen_[v] = 1;
      if (level_[v] >= decisionLevel())
        ++pathCount;
      else
        learnt.push_back(q);
    }
    while (!seen_[trail_[idx--].var()]) {}
    p = trail_[idx + 1];
    c = reason_[p.var()];
    seen_[p.var()] = 0;
    --pathCount;
    first = false;
  } while (pathCount > 0);
  learnt[0] = ~p;

  // Local (one-level) minimisation: drop a literal when every other literal
  // of its reason clause is already in the learnt clause (or at level 0).
  std::vector<Lit> toClear(learnt.begin(), learnt.end());
  std::size_t j = 1;
  for (std::size_t i = 1; i < learnt.size(); ++i) {
    const Clause* r = reason_[learnt[i].var()];
    bool keep = (r == nullptr);
    if (!keep) {
      for (std::size_t k = 1; k < r->lits.size(); ++k) {
        Var v = r->lits[k].var();
        if (!seen_[v] && level_[v] > 0) {
          keep = true;
          break;
        }
      }
    }
    if (keep) learnt[j++] = learnt[i];
  }
  learnt.resize(j);

  if (learnt.size() == 1) {
    backtrackLevel = 0;
  } else {
    std::size_t best = 1;
    for (std::size_t i = 2; i < learnt.size(); ++i)
      if (level_[learnt[i].var()] > level_[learnt[best].var()]) best = i;
    std::swap(learnt[1], learnt[best]);
    backtrackLevel = level_[learnt[1].var()];
  }
  for (Lit l : toClear) seen_[l.var()] = 0;
}

void Solver::cancelUntil(int level) {
  if (decisionLevel() <= level) return;
  for (int i = static_cast<int>(trail_.size()) - 1; i >= trailLim_[level]; --i) {
    Var v = trail_[i].var();
    polarity_[v] = assigns_[v] == LBool::True;
    assigns_[v] = LBool::Undef;
    reason_[v] = nullptr;
    order_.insert(v);
  }
  qhead_ = trailLim_[level];
  trail_.resize(trailLim_[level]);
  trailLim_.resize(level);
}

Lit Solver::pickBranchLit() {
  while (!order_.empty()) {
    Var v = order_.removeMax();
    if (value(v) == LBool::Undef) return Lit(v, !polarity_[v]);
  }
  return Lit();
}

void Solver::bumpVar(Var v) {
  if ((activity_[v] += varInc_) > kVarRescaleLimit) {
    for (double& a : activity_) a *= kVarRescale;
    varInc_ *= kVarRescale;
  }
  order_.increased(v);
}

void Solver::bumpClause(Clause* c) {
  if ((c->activity += claInc_) > kClaRescaleLimit) {
    for (auto& l : learnts_) l->activity *= kClaRescale;
    claInc_ *= kClaRescale;
  }
}

void Solver::decayActivities() {
  varInc_ *= kVarDecay;
  claInc_ *= kClaDecay;
}

bool Solver::locked(const Clause* c) const {
  Var v = c->lits[0].var();
  return reason_[v] == c && value(c->lits[0]) == LBool::True;
}

void Solver::reduceDB() {
  ++stats_.reductions;
  std::vector<Clause*> order;
  order.reserve(learnts_.size());
  for (auto& c : learnts_) order.push_back(c.get());
  std::sort(order.begin(), order.end(),
            [](const Clause* a, const Clause* b) { return a->activity < b->activity; });
  const std::size_t half = order.size() / 2;
  for (std::size_t i = 0; i < half; ++i)
    if (order[i]->lits.size() > 2 && !locked(order[i])) order[i]->deleted = true;

  // Drop watchers of deleted clauses, then free them.
  for (auto& ws : watches_)
    ws.erase(std::remove_if(ws.begin(), ws.end(),
                            [](const Watcher& w) { return w.clause->deleted; }),
             ws.end());
  learnts_.erase(std::remove_if(learnts_.begin(), learnts_.end(),
                                [](const std::unique_ptr<Clause>& c) { return c->deleted; }),
                 learnts_.end());
}

Result Solver::search(std::int64_t maxConflicts, bool& restart) {
  restart = false;
  std::int64_t conflicts = 0;
  std::vector<Lit> learnt;
  for (;;) {
    Clause* confl = propagate();
    if (confl != nullptr) {
      ++stats_.conflicts;
      ++conflicts;
      if (decisionLevel() == 0) return Result::Unsat;
      int bt = 0;
      analyze(confl, learnt, bt);
      cancelUntil(bt);
      if (learnt.size() == 1) {
        enqueue(learnt[0], nullptr);
      } else {
        auto c = std::make_unique<Clause>();
        c->learnt = true;
        c->lits = learnt;
        attach(c.get());
        bumpClause(c.get());
        enqueue(learnt[0], c.get());
        learnts_.push_back(std::move(c));
      }
      decayActivities();
    } else {
      if (conflicts >= maxConflicts) {
        restart = true;
        return Result::Unsat;  // value ignored when restart is set
      }
      Lit next = pickBranchLit();
      if (next == Lit()) return Result::Sat;
      ++stats_.decisions;
      trailLim_.push_back(static_cast<int>(trail_.size()));
      enqueue(next, nullptr);
    }
  }
}

Result Solver::solve() {
  model_.clear();
  if (!ok_) return Result::Unsat;
  if (propagate() != nullptr) {
    ok_ = false;
    return Result::Unsat;
  }
  maxLearnts_ = std::max(static_cast<double>(clauses_.size() / 3),
                         static_cast<double>(kMinMaxLearnts));
  Result result = Result::Unsat;
  for (int i = 0;; ++i) {
    bool restart = false;
    result = search(static_cast<std::int64_t>(kRestartUnit * luby(2.0, i)), restart);
    if (!restart) break;
    ++stats_.restarts;
    cancelUntil(0);
    if (static_cast<double>(learnts_.size()) >= maxLearnts_) {
      reduceDB();
      maxLearnts_ *= kLearntGrowth;
    }
  }
  if (result == Result::Sat) {
    model_.assign(numVars(), false);
    for (Var v = 0; v < numVars(); ++v) model_[v] = assigns_[v] == LBool::True;
  } else {
    ok_ = false;
  }
  cancelUntil(0);
  return result;
}

}  // namespace sat
