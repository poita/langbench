/// \file analyzer.hpp
/// Turns datums into evaluable node trees (one pass per top-level form).
#pragma once

#include <memory>
#include <vector>

#include "scheme/ast.hpp"

namespace scheme {

/// Analyses datums. Owns every node it creates, so the returned pointers (and
/// closures referring to lambda nodes) remain valid for the analyzer's lifetime.
class Analyzer {
 public:
  explicit Analyzer(SymbolTable& symbols);

  /// Analyse one top-level datum. Throws SchemeError(SyntaxError) for
  /// malformed special forms.
  const Node* analyze(const Value& datum);

 private:
  template <class T, class... A>
  T* make(A&&... args) {
    T* n = new T(std::forward<A>(args)...);
    arena_.emplace_back(n);
    return n;
  }

  const Node* analyze_pair(const Value& datum);
  const Node* analyze_body(const std::vector<Value>& forms, size_t from);
  const LambdaNode* analyze_lambda(const Value& params, const std::vector<Value>& forms, size_t body_from);
  const Node* analyze_let(const std::vector<Value>& f);
  const Node* analyze_let_star(const std::vector<Value>& f);
  const Node* analyze_letrec(const std::vector<Value>& f);
  const Node* analyze_cond(const std::vector<Value>& f);
  const Node* analyze_define(const std::vector<Value>& f);
  void parse_bindings(const Value& list, std::vector<Symbol*>& names, std::vector<const Node*>& inits);

  std::vector<std::unique_ptr<Node>> arena_;
  Symbol *s_quote_, *s_if_, *s_define_, *s_set_, *s_lambda_, *s_let_, *s_letstar_, *s_letrec_,
      *s_begin_, *s_cond_, *s_and_, *s_or_, *s_else_;
};

}  // namespace scheme
