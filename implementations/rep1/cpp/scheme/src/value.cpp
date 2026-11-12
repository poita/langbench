#include "scheme/value.hpp"

#include "scheme/errors.hpp"
#include "scheme/numeric.hpp"

namespace scheme {

const char* error_name(ErrorKind kind) {
  switch (kind) {
    case ErrorKind::UnboundVariable: return "unbound-variable";
    case ErrorKind::TypeError: return "type-error";
    case ErrorKind::ArityError: return "arity-error";
    case ErrorKind::DivisionByZero: return "division-by-zero";
    case ErrorKind::UserError: return "user-error";
    case ErrorKind::SyntaxError: return "syntax-error";
  }
  return "unknown";
}

void Object::dispose(Object* o) {
  thread_local std::vector<Object*> pending;
  thread_local bool draining = false;
  pending.push_back(o);
  if (draining) return;
  draining = true;
  while (!pending.empty()) {
    Object* x = pending.back();
    pending.pop_back();
    delete x;  // children released by destructors are queued above
  }
  draining = false;
}

SymbolTable::~SymbolTable() {
  // Drop global bindings first: they may reference other symbols.
  for (auto& kv : table_) kv.second->global = Value();
  for (auto& kv : table_) kv.second->release();
}

Symbol* SymbolTable::intern(std::string_view name) {
  auto it = table_.find(std::string(name));
  if (it != table_.end()) return it->second;
  Symbol* s = new Symbol(std::string(name));
  s->retain();  // reference held by the table
  table_.emplace(s->name, s);
  return s;
}

Value make_list(std::vector<Value> items) {
  Value result = Value::null();
  for (size_t i = items.size(); i-- > 0;) result = make_pair(std::move(items[i]), std::move(result));
  return result;
}

bool list_to_vector(const Value& list, std::vector<Value>& out) {
  const Value* cur = &list;
  while (cur->is_pair()) {
    Pair* p = cur->as<Pair>();
    out.push_back(p->car);
    cur = &p->cdr;
  }
  return cur->is_null();
}

bool is_eq(const Value& a, const Value& b) {
  if (a.is_integer() && b.is_integer()) return num::compare(a, b) == 0;
  if (a.tag() != b.tag()) return false;
  if (a.is_object()) return a.object() == b.object();
  return true;  // void, (), #t, #f
}

bool is_equal(const Value& a, const Value& b) {
  const Value* x = &a;
  const Value* y = &b;
  for (;;) {
    if (x->is_pair() && y->is_pair()) {
      Pair* p = x->as<Pair>();
      Pair* q = y->as<Pair>();
      if (!is_equal(p->car, q->car)) return false;
      x = &p->cdr;
      y = &q->cdr;
      continue;
    }
    if (x->is_string() && y->is_string()) return x->as<String>()->value == y->as<String>()->value;
    return is_eq(*x, *y);
  }
}

}  // namespace scheme
