#include "tessera/query.hpp"

#include <algorithm>

namespace tessera {
namespace {

bool compare(const Value& x, CmpOp op, const Value& v) {
  switch (op) {
    case CmpOp::Eq: return x == v;
    case CmpOp::Ne: return !(x == v);
    default: break;
  }
  if (x.rank() != v.rank()) return false;
  if (x.kind() == Value::Kind::List || x.kind() == Value::Kind::Object) return false;
  int c = x.kind() == Value::Kind::Null ? 0 : compare_scalars(x, v);
  switch (op) {
    case CmpOp::Lt: return c < 0;
    case CmpOp::Le: return c <= 0;
    case CmpOp::Gt: return c > 0;
    default: return c >= 0;
  }
}

void flatten(const Predicate& p, std::vector<const Predicate*>& out) {
  if (p.type == Predicate::Type::And) {
    flatten(*p.lhs, out);
    flatten(*p.rhs, out);
  } else {
    out.push_back(&p);
  }
}

}  // namespace

bool evaluate(const Predicate& p, const Value& doc) {
  switch (p.type) {
    case Predicate::Type::And: return evaluate(*p.lhs, doc) && evaluate(*p.rhs, doc);
    case Predicate::Type::Or: return evaluate(*p.lhs, doc) || evaluate(*p.rhs, doc);
    case Predicate::Type::Not: return !evaluate(*p.lhs, doc);
    case Predicate::Type::Exists: return resolve_path(doc, p.path) != nullptr;
    case Predicate::Type::Missing: return resolve_path(doc, p.path) == nullptr;
    case Predicate::Type::Cmp: {
      const Value* x = resolve_path(doc, p.path);
      return x != nullptr && compare(*x, p.op, p.value);
    }
  }
  return false;
}

std::string Plan::describe() const { return use_index ? "index " + path : "scan"; }

Plan choose_plan(const Predicate& pred, const std::vector<std::string>& live) {
  std::vector<const Predicate*> leaves;
  flatten(pred, leaves);
  const Predicate* best = nullptr;
  std::string best_text;
  for (const Predicate* leaf : leaves) {
    if (leaf->type != Predicate::Type::Cmp || leaf->op == CmpOp::Ne) continue;
    Value::Kind k = leaf->value.kind();
    if (k == Value::Kind::List || k == Value::Kind::Object) continue;
    std::string text = path_text(leaf->path);
    if (std::find(live.begin(), live.end(), text) == live.end()) continue;
    bool better = false;
    if (!best) {
      better = true;
    } else {
      bool leaf_eq = leaf->op == CmpOp::Eq, best_eq = best->op == CmpOp::Eq;
      if (leaf_eq != best_eq) better = leaf_eq;
      else if (text != best_text) better = text < best_text;
      // otherwise the earlier leaf (already `best`) wins
    }
    if (better) {
      best = leaf;
      best_text = std::move(text);
    }
  }
  Plan plan;
  if (best) {
    plan.use_index = true;
    plan.path = best_text;
    plan.op = best->op;
    plan.value = best->value;
  }
  return plan;
}

}  // namespace tessera
