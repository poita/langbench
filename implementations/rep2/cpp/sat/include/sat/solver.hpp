// A MiniSat-style conflict-driven clause-learning (CDCL) SAT solver.
#pragma once

#include <cstdint>
#include <memory>
#include <vector>

#include "sat/heap.hpp"
#include "sat/types.hpp"

namespace sat {

/// Counters describing a solver run.
struct Stats {
    std::uint64_t conflicts = 0;
    std::uint64_t decisions = 0;
    std::uint64_t propagations = 0;
    std::uint64_t restarts = 0;
    std::uint64_t learnt_literals = 0;  ///< literals in learnt clauses after minimisation
    std::uint64_t reductions = 0;       ///< learnt-clause database reductions
    std::uint64_t deleted_clauses = 0;  ///< learnt clauses removed by reductions
};

/// The i-th (0-based) element of the Luby sequence 1,1,2,1,1,2,4,1,1,2,...
/// scaled with base 2, i.e. luby(2, i) in the usual notation.
std::uint64_t luby(std::uint64_t i);

/// A CDCL SAT solver.
///
/// Algorithm: two-watched-literal unit propagation, first-UIP conflict
/// analysis with local clause minimisation, VSIDS branching (activities
/// decay by 1/0.95 per conflict) with phase saving, Luby restarts (unit of
/// 100 conflicts) and activity-based learnt-clause deletion after restarts.
///
/// Typical use:
/// @code
///   sat::Solver s;
///   sat::Var a = s.new_var(), b = s.new_var();
///   s.add_clause({sat::Lit(a), sat::Lit(b, true)});   // a  OR  NOT b
///   if (s.solve() == sat::Result::Sat) bool av = s.model_value(a);
/// @endcode
///
/// The solver is single-use for solve(): call it once after adding all
/// clauses. A Solver is not thread-safe and not copyable.
class Solver {
public:
    Solver();
    ~Solver();
    Solver(const Solver&) = delete;
    Solver& operator=(const Solver&) = delete;

    /// Creates a new variable and returns its index (0, 1, 2, ...).
    Var new_var();
    int num_vars() const { return static_cast<int>(assigns_.size()); }

    /// Adds a clause (a disjunction of literals over existing variables).
    ///
    /// The clause is simplified against the root-level assignment: duplicate
    /// literals are merged, tautologies and satisfied clauses are dropped,
    /// false literals removed, and a resulting unit is assigned and propagated.
    /// An empty clause makes the formula unsatisfiable. Returns false iff the
    /// formula is now known to be unsatisfiable (further calls are no-ops).
    bool add_clause(std::vector<Lit> lits);

    /// Convenience overload using DIMACS integers (non-zero, 1-based).
    bool add_clause_dimacs(const std::vector<int>& lits);

    /// False once the formula is known to be unsatisfiable at the root.
    bool okay() const { return ok_; }

    /// Decides satisfiability of the clauses added so far.
    Result solve();

    /// Value of `v` in the model found by the last Sat result.
    bool model_value(Var v) const { return model_[v]; }
    /// The whole model, indexed by variable (valid after a Sat result).
    const std::vector<bool>& model() const { return model_; }

    const Stats& stats() const { return stats_; }

private:
    struct Clause;
    struct Watcher {
        Clause* clause;
        Lit blocker;  ///< some literal of the clause; if true the clause is satisfied
    };

    LBool value(Var v) const { return assigns_[v]; }
    LBool value(Lit l) const {
        LBool a = assigns_[l.var()];
        if (a == LBool::Undef) return a;
        return (a == LBool::True) != l.negative() ? LBool::True : LBool::False;
    }
    int decision_level() const { return static_cast<int>(trail_lim_.size()); }

    void attach(Clause* c);
    void enqueue(Lit p, Clause* reason);
    Clause* propagate();
    void analyze(Clause* conflict, std::vector<Lit>& learnt, int& backtrack_level);
    void cancel_until(int level);
    Lit pick_branch_lit();
    bool locked(const Clause* c) const;
    void reduce_db();
    LBool search(std::uint64_t conflict_budget);

    void bump_var(Var v);
    void decay_var_activity() { var_inc_ /= kVarDecay; }
    void bump_clause(Clause* c);
    void decay_clause_activity() { cla_inc_ /= kClauseDecay; }

    static constexpr double kVarDecay = 0.95;
    static constexpr double kClauseDecay = 0.999;
    static constexpr int kRestartBase = 100;

    bool ok_ = true;
    std::vector<std::unique_ptr<Clause>> clauses_;  ///< stored input clauses (size >= 2)
    std::vector<std::unique_ptr<Clause>> learnts_;
    std::vector<std::vector<Watcher>> watches_;  ///< indexed by literal: clauses to visit when it becomes true

    std::vector<LBool> assigns_;
    std::vector<int> level_;
    std::vector<Clause*> reason_;
    std::vector<char> polarity_;  ///< saved phase: 1 = last value was false
    std::vector<Lit> trail_;
    std::vector<int> trail_lim_;
    std::size_t qhead_ = 0;

    std::vector<double> activity_;
    VarHeap order_;
    double var_inc_ = 1.0;
    double cla_inc_ = 1.0;
    double max_learnts_ = 0;

    std::vector<char> seen_;  ///< scratch space for analyze()
    std::vector<bool> model_;
    Stats stats_;
};

}  // namespace sat
