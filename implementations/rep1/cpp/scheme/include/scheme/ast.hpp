/// \file ast.hpp
/// The analysed program: a tree of nodes produced once per top-level form by
/// the Analyzer and walked by the Interpreter.
#pragma once

#include <vector>

#include "scheme/value.hpp"

namespace scheme {

enum class NodeKind : uint8_t {
  Const, Var, If, Define, Set, Lambda, Seq, Let, NamedLet, Letrec, Cond, And, Or, App
};

struct Node {
  explicit Node(NodeKind k) : kind(k) {}
  virtual ~Node() = default;
  Node(const Node&) = delete;
  Node& operator=(const Node&) = delete;
  const NodeKind kind;
};

/// A literal or quoted datum.
struct ConstNode : Node {
  explicit ConstNode(Value v) : Node(NodeKind::Const), value(std::move(v)) {}
  Value value;
};

struct VarNode : Node {
  explicit VarNode(Symbol* s) : Node(NodeKind::Var), name(s) {}
  Symbol* name;
};

struct IfNode : Node {
  IfNode(const Node* t, const Node* c, const Node* a) : Node(NodeKind::If), test(t), then(c), otherwise(a) {}
  const Node* test;
  const Node* then;
  const Node* otherwise;  // may be null: the value is void
};

struct DefineNode : Node {
  DefineNode(Symbol* n, const Node* e) : Node(NodeKind::Define), name(n), expr(e) {}
  Symbol* name;
  const Node* expr;
};

struct SetNode : Node {
  SetNode(Symbol* n, const Node* e) : Node(NodeKind::Set), name(n), expr(e) {}
  Symbol* name;
  const Node* expr;
};

struct LambdaNode : Node {
  LambdaNode() : Node(NodeKind::Lambda) {}
  std::vector<Symbol*> params;
  Symbol* rest = nullptr;  // collects extra arguments, or null
  const Node* body = nullptr;
};

/// `begin`, and any multi-form body. The last form is in tail position.
struct SeqNode : Node {
  SeqNode() : Node(NodeKind::Seq) {}
  std::vector<const Node*> forms;
};

/// `let` (and each step of `let*`): inits in the current frame, body in a new one.
struct LetNode : Node {
  LetNode() : Node(NodeKind::Let) {}
  std::vector<Symbol*> names;
  std::vector<const Node*> inits;
  const Node* body = nullptr;
};

struct NamedLetNode : Node {
  NamedLetNode() : Node(NodeKind::NamedLet) {}
  Symbol* name = nullptr;
  const LambdaNode* lambda = nullptr;
  std::vector<const Node*> inits;
};

struct LetrecNode : Node {
  LetrecNode() : Node(NodeKind::Letrec) {}
  std::vector<Symbol*> names;
  std::vector<const Node*> inits;
  const Node* body = nullptr;
};

struct CondClause {
  const Node* test;  // null for `else`
  const Node* body;  // null: the value of the test
};

struct CondNode : Node {
  CondNode() : Node(NodeKind::Cond) {}
  std::vector<CondClause> clauses;
};

/// `and` / `or` with at least two forms.
struct AndOrNode : Node {
  explicit AndOrNode(NodeKind k) : Node(k) {}
  std::vector<const Node*> forms;
};

struct AppNode : Node {
  AppNode() : Node(NodeKind::App) {}
  const Node* fn = nullptr;
  std::vector<const Node*> args;
};

}  // namespace scheme
