#include "sat/solver.hpp"

#include <algorithm>
#include <cmath>
#include <utility>

namespace sat {

std::uint64_t luby(std::uint64_t i) {
    // Find the finite subsequence (of length 2^k - 1) that contains index i,
    // then descend into it.
    std::uint64_t size = 1;
    int seq = 0;
    while (size < i + 1) {
        ++seq;
        size = 2 * size + 1;
    }
    while (size - 1 != i) {
        size = (size - 1) >> 1;
        --seq;
        i %= size;
    }
    return std::uint64_t{1} << seq;
}

struct Solver::Clause {
    std::vector<Lit> lits;
    double activity = 0;
    bool learnt = false;
    bool deleted = false;
};

Solver::Solver() : order_(activity_) {}
Solver::~Solver() = default;

Var Solver::new_var() {
    Var v = num_vars();
    assigns_.push_back(LBool::Undef);
    level_.push_back(0);
    reason_.push_back(nullptr);
    polarity_.push_back(1);  // initial phase: false
    activity_.push_back(0.0);
    seen_.push_back(0);
    watches_.emplace_back();
    watches_.emplace_back();
    order_.insert(v);
    return v;
}

bool Solver::add_clause_dimacs(const std::vector<int>& lits) {
    std::vector<Lit> out;
    out.reserve(lits.size());
    for (int d : lits) out.push_back(Lit::from_dimacs(d));
    return add_clause(std::move(out));
}

bool Solver::add_clause(std::vector<Lit> lits) {
    if (!ok_) return false;
    // Clauses are added at the root level.
    cancel_until(0);

    std::sort(lits.begin(), lits.end());
    std::size_t j = 0;
    Lit prev;
    for (std::size_t i = 0; i < lits.size(); ++i) {
        Lit l = lits[i];
        if (value(l) == LBool::True || (prev.defined() && l == ~prev)) return true;  // satisfied / tautology
        if (value(l) != LBool::False && l != prev) {
            lits[j++] = l;
            prev = l;
        }
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
    watches_[(~c->lits[0]).index()].push_back({c, c->lits[1]});
    watches_[(~c->lits[1]).index()].push_back({c, c->lits[0]});
}

void Solver::enqueue(Lit p, Clause* reason) {
    assigns_[p.var()] = p.negative() ? LBool::False : LBool::True;
    level_[p.var()] = decision_level();
    reason_[p.var()] = reason;
    trail_.push_back(p);
}

// Unit propagation with two watched literals. Invariant: the first two
// literals of every clause are its watched literals, and for a reason clause
// the implied literal is first. Returns a conflicting clause or nullptr.
Solver::Clause* Solver::propagate() {
    Clause* conflict = nullptr;
    while (qhead_ < trail_.size()) {
        Lit p = trail_[qhead_++];  // p just became true
        ++stats_.propagations;
        std::vector<Watcher>& ws = watches_[p.index()];
        Lit false_lit = ~p;
        std::size_t i = 0, j = 0;
        const std::size_t n = ws.size();
        while (i < n) {
            Watcher w = ws[i++];
            if (value(w.blocker) == LBool::True) {
                ws[j++] = w;
                continue;
            }
            Clause& c = *w.clause;
            if (c.lits[0] == false_lit) std::swap(c.lits[0], c.lits[1]);
            Lit first = c.lits[0];
            Watcher nw{w.clause, first};
            if (first != w.blocker && value(first) == LBool::True) {
                ws[j++] = nw;
                continue;
            }
            bool moved = false;
            for (std::size_t k = 2; k < c.lits.size(); ++k) {
                if (value(c.lits[k]) != LBool::False) {
                    std::swap(c.lits[1], c.lits[k]);
                    watches_[(~c.lits[1]).index()].push_back(nw);
                    moved = true;
                    break;
                }
            }
            if (moved) continue;
            // Clause is unit or conflicting under the current assignment.
            ws[j++] = nw;
            if (value(first) == LBool::False) {
                conflict = w.clause;
                qhead_ = trail_.size();
                while (i < n) ws[j++] = ws[i++];
            } else {
                enqueue(first, w.clause);
            }
        }
        ws.resize(j);
    }
    return conflict;
}

void Solver::bump_var(Var v) {
    if ((activity_[v] += var_inc_) > 1e100) {
        for (double& a : activity_) a *= 1e-100;
        var_inc_ *= 1e-100;
    }
    order_.increased(v);
}

void Solver::bump_clause(Clause* c) {
    if ((c->activity += cla_inc_) > 1e20) {
        for (auto& l : learnts_) l->activity *= 1e-20;
        cla_inc_ *= 1e-20;
    }
}

// First-UIP conflict analysis. Fills `learnt` (asserting literal first, then
// a literal of the backtrack level second) and the backtrack level.
void Solver::analyze(Clause* confl, std::vector<Lit>& learnt, int& backtrack_level) {
    int path = 0;
    Lit p;
    learnt.clear();
    learnt.push_back(Lit());  // placeholder for the asserting literal
    std::size_t index = trail_.size();

    do {
        if (confl->learnt) bump_clause(confl);
        for (std::size_t k = p.defined() ? 1 : 0; k < confl->lits.size(); ++k) {
            Lit q = confl->lits[k];
            Var v = q.var();
            if (!seen_[v] && level_[v] > 0) {
                bump_var(v);
                seen_[v] = 1;
                if (level_[v] >= decision_level())
                    ++path;
                else
                    learnt.push_back(q);
            }
        }
        while (!seen_[trail_[--index].var()]) {}
        p = trail_[index];
        confl = reason_[p.var()];
        seen_[p.var()] = 0;
        --path;
    } while (path > 0);
    learnt[0] = ~p;

    // Local (non-recursive) minimisation: drop a literal when every other
    // literal of its reason is already in the clause or fixed at level 0.
    std::vector<Lit> to_clear(learnt.begin(), learnt.end());
    std::size_t j = 1;
    for (std::size_t i = 1; i < learnt.size(); ++i) {
        Clause* r = reason_[learnt[i].var()];
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
    for (Lit l : to_clear) seen_[l.var()] = 0;

    if (learnt.size() == 1) {
        backtrack_level = 0;
    } else {
        std::size_t max_i = 1;
        for (std::size_t i = 2; i < learnt.size(); ++i)
            if (level_[learnt[i].var()] > level_[learnt[max_i].var()]) max_i = i;
        std::swap(learnt[1], learnt[max_i]);
        backtrack_level = level_[learnt[1].var()];
    }
}

void Solver::cancel_until(int level) {
    if (decision_level() <= level) return;
    for (std::size_t c = trail_.size(); c-- > static_cast<std::size_t>(trail_lim_[level]);) {
        Var v = trail_[c].var();
        polarity_[v] = trail_[c].negative();
        assigns_[v] = LBool::Undef;
        reason_[v] = nullptr;
        order_.insert(v);
    }
    trail_.resize(trail_lim_[level]);
    trail_lim_.resize(level);
    qhead_ = trail_.size();
}

Lit Solver::pick_branch_lit() {
    while (!order_.empty()) {
        Var v = order_.pop_max();
        if (value(v) == LBool::Undef) return Lit(v, polarity_[v] != 0);
    }
    return Lit();
}

bool Solver::locked(const Clause* c) const {
    Lit l = c->lits[0];
    return value(l) == LBool::True && reason_[l.var()] == c;
}

// Deletes the lower-activity half of the learnt clauses; binary and locked
// (currently a reason) clauses are always kept.
void Solver::reduce_db() {
    ++stats_.reductions;
    const std::size_t target = learnts_.size() / 2;
    std::vector<Clause*> candidates;
    for (auto& c : learnts_)
        if (c->lits.size() > 2) candidates.push_back(c.get());
    std::sort(candidates.begin(), candidates.end(),
              [](const Clause* a, const Clause* b) { return a->activity < b->activity; });

    std::size_t removed = 0;
    for (std::size_t i = 0; i < candidates.size() && removed < target; ++i) {
        if (locked(candidates[i])) continue;
        candidates[i]->deleted = true;
        ++removed;
    }
    if (removed == 0) return;

    for (auto& ws : watches_)
        ws.erase(std::remove_if(ws.begin(), ws.end(), [](const Watcher& w) { return w.clause->deleted; }), ws.end());
    learnts_.erase(std::remove_if(learnts_.begin(), learnts_.end(), [](const std::unique_ptr<Clause>& c) { return c->deleted; }),
                   learnts_.end());
    stats_.deleted_clauses += removed;
}

// Runs CDCL until a model is found (True), the formula is refuted (False), or
// the conflict budget is spent (Undef, after backtracking to the root).
LBool Solver::search(std::uint64_t conflict_budget) {
    std::uint64_t conflicts_here = 0;
    std::vector<Lit> learnt;
    for (;;) {
        Clause* confl = propagate();
        if (confl != nullptr) {
            ++stats_.conflicts;
            ++conflicts_here;
            if (decision_level() == 0) return LBool::False;

            int bt;
            analyze(confl, learnt, bt);
            cancel_until(bt);
            stats_.learnt_literals += learnt.size();
            if (learnt.size() == 1) {
                enqueue(learnt[0], nullptr);
            } else {
                auto c = std::make_unique<Clause>();
                c->lits = learnt;
                c->learnt = true;
                attach(c.get());
                bump_clause(c.get());
                enqueue(learnt[0], c.get());
                learnts_.push_back(std::move(c));
            }
            decay_var_activity();
            decay_clause_activity();
        } else {
            if (conflicts_here >= conflict_budget) {
                cancel_until(0);
                return LBool::Undef;
            }
            Lit next = pick_branch_lit();
            if (!next.defined()) return LBool::True;
            ++stats_.decisions;
            trail_lim_.push_back(static_cast<int>(trail_.size()));
            enqueue(next, nullptr);
        }
    }
}

Result Solver::solve() {
    if (!ok_) return Result::Unsat;
    cancel_until(0);
    if (propagate() != nullptr) {
        ok_ = false;
        return Result::Unsat;
    }
    max_learnts_ = std::max(static_cast<double>(clauses_.size()) / 3.0, 2000.0);
    max_learnts_ = std::floor(max_learnts_);

    LBool status = LBool::Undef;
    for (std::uint64_t i = 0; status == LBool::Undef; ++i) {
        status = search(kRestartBase * luby(i));
        if (status != LBool::Undef) break;
        ++stats_.restarts;
        if (static_cast<double>(learnts_.size()) >= max_learnts_) {
            reduce_db();
            max_learnts_ *= 1.1;
        }
    }

    if (status == LBool::False) {
        ok_ = false;
        return Result::Unsat;
    }
    model_.assign(num_vars(), false);
    for (Var v = 0; v < num_vars(); ++v) model_[v] = assigns_[v] == LBool::True;
    cancel_until(0);
    return Result::Sat;
}

}  // namespace sat
