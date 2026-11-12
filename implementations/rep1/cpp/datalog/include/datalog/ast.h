// Abstract syntax of Datalog programs.
#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace datalog {

/// A constant: an integer or a symbol (an identifier such as `alice`).
/// Constants are totally ordered: every integer is less than every symbol;
/// integers compare numerically and symbols by byte value (`strcmp` order).
class Constant {
 public:
  static Constant integer(std::int64_t value);
  static Constant symbol(std::string name);

  bool is_integer() const { return is_integer_; }
  std::int64_t integer_value() const { return integer_; }
  const std::string& symbol_value() const { return symbol_; }

  /// Canonical text form: decimal for integers, the name for symbols.
  std::string to_string() const;

  friend bool operator==(const Constant& a, const Constant& b);
  friend bool operator!=(const Constant& a, const Constant& b) { return !(a == b); }
  friend bool operator<(const Constant& a, const Constant& b);

 private:
  bool is_integer_ = true;
  std::int64_t integer_ = 0;
  std::string symbol_;
};

/// A term: a constant, a named variable, or the anonymous variable `_`.
class Term {
 public:
  enum class Kind { Constant, Variable, Anonymous };

  static Term constant(Constant c);
  static Term variable(std::string name);
  static Term anonymous();

  Kind kind() const { return kind_; }
  bool is_constant() const { return kind_ == Kind::Constant; }
  bool is_variable() const { return kind_ == Kind::Variable; }
  bool is_anonymous() const { return kind_ == Kind::Anonymous; }
  const Constant& constant_value() const { return constant_; }
  const std::string& variable_name() const { return name_; }

 private:
  Kind kind_ = Kind::Anonymous;
  Constant constant_;
  std::string name_;
};

/// A predicate applied to terms: `edge(X, 3)`.
struct Atom {
  std::string predicate;
  std::vector<Term> args;
  std::size_t arity() const { return args.size(); }
};

enum class CompareOp { Lt, Le, Gt, Ge, Eq, Ne };

/// Text of a comparison operator (`<`, `<=`, ...).
const char* to_string(CompareOp op);

/// A body literal: a positive atom, a negated atom, or a comparison.
struct Literal {
  enum class Kind { Positive, Negative, Comparison };

  Kind kind = Kind::Positive;
  Atom atom;          // Positive / Negative
  CompareOp op = CompareOp::Eq;  // Comparison
  Term lhs, rhs;      // Comparison

  static Literal positive(Atom a);
  static Literal negative(Atom a);
  static Literal comparison(Term lhs, CompareOp op, Term rhs);
};

/// `head :- body.`  A fact is a rule with an empty body.
struct Rule {
  Atom head;
  std::vector<Literal> body;
  bool is_fact() const { return body.empty(); }
};

/// A parsed program: its facts and rules (in source order) and its queries
/// (in source order).
struct Program {
  std::vector<Rule> rules;
  std::vector<Atom> queries;
};

/// Source text of an atom, for diagnostics.
std::string to_string(const Atom& atom);
std::string to_string(const Term& term);

}  // namespace datalog
