// Abstract syntax of a Datalog program.
#pragma once

#include <compare>
#include <cstdint>
#include <string>
#include <utility>
#include <vector>

namespace datalog {

/// A constant: an integer or a symbol (an identifier such as `alice`).
///
/// Constants are totally ordered: every integer is smaller than every symbol,
/// integers compare numerically, symbols compare bytewise (a proper prefix
/// sorts first).
class Constant {
 public:
  Constant() = default;
  static Constant integer(std::int64_t value);
  static Constant symbol(std::string name);

  bool is_integer() const { return is_integer_; }
  /// Value of an integer constant (0 for symbols).
  std::int64_t integer_value() const { return number_; }
  /// Name of a symbol constant (empty for integers).
  const std::string& symbol_name() const { return text_; }

  /// Canonical textual form: `-5`, `0`, `alice`.
  std::string to_string() const;

  friend bool operator==(const Constant& a, const Constant& b);
  friend std::strong_ordering operator<=>(const Constant& a, const Constant& b);

 private:
  bool is_integer_ = true;
  std::int64_t number_ = 0;
  std::string text_;
};

/// An argument of an atom or comparison: a constant, a named variable, or the
/// anonymous variable `_` (each occurrence of which is distinct).
struct Term {
  enum class Kind { Constant, Variable, Anonymous };

  Kind kind = Kind::Anonymous;
  Constant constant;     // valid when kind == Constant
  std::string variable;  // valid when kind == Variable

  static Term make_constant(Constant c);
  static Term make_variable(std::string name);
  static Term make_anonymous();
};

/// `predicate(arg, ...)`. A predicate is identified by name *and* arity.
struct Atom {
  std::string predicate;
  std::vector<Term> args;
};

enum class CompareOp { Lt, Le, Gt, Ge, Eq, Ne };

/// Evaluates `a op b` under the constant ordering.
bool compare_holds(CompareOp op, const Constant& a, const Constant& b);

/// A body literal: a positive atom, a negated atom, or a comparison.
struct Literal {
  enum class Kind { Positive, Negative, Comparison };

  Kind kind = Kind::Positive;
  Atom atom;  // Positive / Negative
  CompareOp op = CompareOp::Eq;
  Term lhs, rhs;  // Comparison
};

/// `head :- body.`; a fact is a rule with an empty body.
struct Rule {
  Atom head;
  std::vector<Literal> body;
};

/// `?- atom.`
struct Query {
  Atom atom;
};

/// A parsed program. Queries are kept in input order.
struct Program {
  std::vector<Rule> rules;
  std::vector<Query> queries;
};

}  // namespace datalog
