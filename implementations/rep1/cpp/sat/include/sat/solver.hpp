// A MiniSat-style conflict-driven clause-learning (CDCL) SAT solver.
//
//   * two watched literals per clause for unit propagation
//   * first-UIP conflict analysis with local clause minimisation
//   * VSIDS branching (double-precision activities) with phase saving
//   * Luby restarts (unit 100 conflicts)
//   * periodic deletion of low-activity learnt clauses
//
// Typical use:
//
//   sat::Solver s;
//   s.reserveVars(3);
//   s.addClause({1, -2});        // DIMACS-style integers
//   s.addClause({2, 3});
//   if (s.solve() == sat::Result::Sat) { bool x1 = s.modelValue(0); ... }
#pragma once

#include <cstdint>
#include <initializer_list>
#include <memory>
#include <vector>

#include "sat/heap.hpp"
#include "sat/types.hpp"

namespace sat {

enum class Result { Sat, Unsat };

class Solver {
 public:
  Solver();
  ~Solver();
  Solver(const Solver&) = delete;
  Solver& operator=(const Solver&) = delete;

  /// Create a new variable and return it (variables are numbered from 0).
  Var newVar();

  /// Ensure at least `n` variables exist.
  void reserveVars(int n);

  int numVars() const { return static_cast<int>(assigns_.size()); }

  /// Add an input clause. Duplicate literals, tautologies, root-satisfied
  /// clauses and root-false literals are simplified away; units are assigned
  /// and propagated at once. Variables are created on demand. Must be called
  /// before solve(). Returns false if the formula is already known to be
  /// unsatisfiable.
  bool addClause(std::vector<Lit> lits);

  /// Convenience overload taking DIMACS integers (non-zero, 1-based, sign =
  /// polarity).
  bool addClause(std::initializer_list<int> dimacsLits);

  /// Decide satisfiability of the clauses added so far.
  Result solve();

  /// After solve() returned Sat: the truth value of variable `v` in the model.
  bool modelValue(Var v) const { return model_[v]; }
  /// The full model, indexed by variable.
  const std::vector<bool>& model() const { return model_; }

  struct Stats {
    std::uint64_t conflicts = 0;
    std::uint64_t decisions = 0;
    std::uint64_t propagations = 0;
    std::uint64_t restarts = 0;
    std::uint64_t reductions = 0;
  };
  const Stats& stats() const { return stats_; }

  /// Number of learnt clauses currently stored.
  int numLearnts() const { return static_cast<int>(learnts_.size()); }

 private:
  struct Clause {
    bool learnt = false;
    bool deleted = false;
    double activity = 0.0;
    std::vector<Lit> lits;
  };

  struct Watcher {
    Clause* clause;
    Lit blocker;  // some literal of the clause; if true the clause is satisfied
  };

  LBool value(Var v) const { return assigns_[v]; }
  LBool value(Lit l) const { return flipIf(assigns_[l.var()], l.negated()); }
  int decisionLevel() const { return static_cast<int>(trailLim_.size()); }

  void attach(Clause* c);
  void enqueue(Lit p, Clause* from);
  Clause* propagate();
  void analyze(Clause* conflict, std::vector<Lit>& learnt, int& backtrackLevel);
  void cancelUntil(int level);
  Lit pickBranchLit();
  Result search(std::int64_t maxConflicts, bool& restart);
  void reduceDB();
  bool locked(const Clause* c) const;

  void bumpVar(Var v);
  void bumpClause(Clause* c);
  void decayActivities();

  bool ok_ = true;  // false once unsatisfiability has been established

  std::vector<std::unique_ptr<Clause>> clauses_;  // stored input clauses (>= 2 lits)
  std::vector<std::unique_ptr<Clause>> learnts_;
  std::vector<std::vector<Watcher>> watches_;  // by literal: clauses watching it

  std::vector<LBool> assigns_;
  std::vector<int> level_;
  std::vector<Clause*> reason_;
  std::vector<Lit> trail_;
  std::vector<int> trailLim_;
  std::size_t qhead_ = 0;

  std::vector<double> activity_;
  std::vector<char> polarity_;  // saved phase: 1 = true
  VarHeap order_;
  double varInc_ = 1.0;
  double claInc_ = 1.0;
  double maxLearnts_ = 0.0;

  std::vector<char> seen_;  // scratch for analyze()
  std::vector<bool> model_;
  Stats stats_;
};

}  // namespace sat
