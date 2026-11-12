#include "interpreter.hpp"

#include <algorithm>

#include "jq/error.hpp"
#include "jq/json.hpp"
#include "ops.hpp"

namespace jq::detail {

namespace {

/// Persistent variable environment: an immutable linked list living on the
/// C++ stack of the evaluation that bound the variable.
struct Env {
  const Env* parent;
  int var;
  const Value* value;
};

class Evaluator {
 public:
  void eval(const Node& n, const Value& in, const Env* env, Emit out) const;

 private:
  // Calls f(target) for every output of `target` evaluated on `in`.
  template <class F>
  void each(const Node& target, const Value& in, const Env* env, F&& f) const {
    if (target.kind == NodeKind::Identity)
      f(in);
    else
      eval(target, in, env, [&](const Value& v) { f(v); });
  }

  // Calls f(ptr) for every output of the optional node `n` (nullptr when absent).
  template <class F>
  void each_opt(const Node* n, const Value& in, const Env* env, F&& f) const {
    if (!n)
      f(static_cast<const Value*>(nullptr));
    else
      eval(*n, in, env, [&](const Value& v) { f(&v); });
  }

  void eval_index(const Node& n, const Value& in, const Env* env, Emit out) const;
  void eval_iterate(const Node& n, const Value& in, const Env* env, Emit out) const;
  void eval_slice(const Node& n, const Value& in, const Env* env, Emit out) const;
  void eval_try(const Node& n, const Value& in, const Env* env, Emit out) const;
  void eval_object(const Node& n, std::size_t i, std::vector<std::pair<std::string, Value>>& acc,
                   const Value& in, const Env* env, Emit out) const;
  void eval_reduce(const Node& n, const Value& in, const Env* env, Emit out) const;
  void eval_call(const Node& n, const Value& in, const Env* env, Emit out) const;
  Value collect(const Node& n, const Value& in, const Env* env) const;
};

[[noreturn]] void throw_value_error(const Value& v) {
  throw RuntimeError(v.is_string() ? v.string() : to_json(v) + " (not a string)");
}

Value Evaluator::collect(const Node& n, const Value& in, const Env* env) const {
  Value::Array items;
  eval(n, in, env, [&](const Value& v) { items.push_back(v); });
  return Value::array(std::move(items));
}

void Evaluator::eval_index(const Node& n, const Value& in, const Env* env, Emit out) const {
  std::string err;
  auto apply = [&](const Value& t, const Value& k) {
    const Value* r = index_value(t, k, n.optional ? nullptr : &err);
    if (r)
      out(*r);
    else if (!n.optional)
      throw RuntimeError(err);
  };
  if (n.b->kind == NodeKind::Literal) {
    const Value& k = n.b->literal;
    each(*n.a, in, env, [&](const Value& t) { apply(t, k); });
    return;
  }
  eval(*n.b, in, env, [&](const Value& k) {
    each(*n.a, in, env, [&](const Value& t) { apply(t, k); });
  });
}

void Evaluator::eval_iterate(const Node& n, const Value& in, const Env* env, Emit out) const {
  each(*n.a, in, env, [&](const Value& t) {
    if (t.is_array()) {
      for (const Value& e : t.array()) out(e);
    } else if (t.is_object()) {
      for (const auto& e : t.object()) out(e.value);
    } else if (!n.optional) {
      throw RuntimeError(std::string("Cannot iterate over ") + t.type_name());
    }
  });
}

void Evaluator::eval_slice(const Node& n, const Value& in, const Env* env, Emit out) const {
  each_opt(n.b.get(), in, env, [&](const Value* from) {
    each_opt(n.c.get(), in, env, [&](const Value* to) {
      each(*n.a, in, env, [&](const Value& t) {
        std::string err;
        Value r;
        if (slice_value(t, from, to, r, n.optional ? nullptr : &err))
          out(r);
        else if (!n.optional)
          throw RuntimeError(err);
      });
    });
  });
}

// `try`: outputs of the body up to its first error, which is swallowed. Errors
// raised by the consumer (`out`) are not the body's and must propagate.
void Evaluator::eval_try(const Node& n, const Value& in, const Env* env, Emit out) const {
  bool downstream_failed = false;
  try {
    eval(*n.a, in, env, [&](const Value& v) {
      try {
        out(v);
      } catch (...) {
        downstream_failed = true;
        throw;
      }
    });
  } catch (const RuntimeError&) {
    if (downstream_failed) throw;
  }
}

void Evaluator::eval_object(const Node& n, std::size_t i,
                            std::vector<std::pair<std::string, Value>>& acc, const Value& in,
                            const Env* env, Emit out) const {
  if (i == n.entries.size()) {
    ObjectBuilder b;
    b.reserve(acc.size());
    for (auto& kv : acc) b.set(kv.first, kv.second);
    out(b.build_value());
    return;
  }
  const ObjEntry& e = n.entries[i];
  auto with_key = [&](const std::string& key) {
    eval(*e.value, in, env, [&](const Value& v) {
      acc.emplace_back(key, v);
      try {
        eval_object(n, i + 1, acc, in, env, out);
      } catch (...) {
        acc.pop_back();
        throw;
      }
      acc.pop_back();
    });
  };
  if (!e.key) {
    with_key(e.literal_key);
  } else {
    eval(*e.key, in, env, [&](const Value& k) {
      if (!k.is_string())
        throw RuntimeError(std::string("Object keys must be strings, not ") + k.type_name());
      with_key(k.string());
    });
  }
}

void Evaluator::eval_reduce(const Node& n, const Value& in, const Env* env, Emit out) const {
  eval(*n.b, in, env, [&](const Value& init) {
    Value acc = init;
    eval(*n.a, in, env, [&](const Value& item) {
      Env e{env, n.var, &item};
      Value last;
      eval(*n.c, acc, &e, [&](const Value& r) { last = r; });
      acc = std::move(last);
    });
    out(acc);
  });
}

void Evaluator::eval_call(const Node& n, const Value& in, const Env* env, Emit out) const {
  switch (n.builtin) {
    case Builtin::Empty: return;
    case Builtin::Error0: throw_value_error(in);
    case Builtin::Error1:
      eval(*n.args[0], in, env, [&](const Value& v) { throw_value_error(v); });
      return;
    case Builtin::Not: out(Value::boolean(!in.truthy())); return;
    case Builtin::Length: out(builtin_length(in)); return;
    case Builtin::Keys: out(builtin_keys(in)); return;
    case Builtin::Type: out(Value::string(in.type_name())); return;
    case Builtin::Add: {
      if (in.is_array()) {
        out(builtin_add(in.array()));
      } else if (in.is_object()) {
        Value::Array vals;
        for (const auto& e : in.object()) vals.push_back(e.value);
        out(builtin_add(vals));
      } else {
        throw RuntimeError(std::string("Cannot iterate over ") + in.type_name());
      }
      return;
    }
    case Builtin::Reverse: out(builtin_reverse(in)); return;
    case Builtin::Min: out(builtin_min_max(in, false)); return;
    case Builtin::Max: out(builtin_min_max(in, true)); return;
    case Builtin::ToString: out(builtin_tostring(in)); return;
    case Builtin::ToNumber: out(builtin_tonumber(in)); return;
    case Builtin::Sort: out(builtin_sort(in)); return;
    case Builtin::Unique: out(builtin_unique(in)); return;
    case Builtin::Has:
      eval(*n.args[0], in, env, [&](const Value& k) { out(Value::boolean(builtin_has(in, k))); });
      return;
    case Builtin::Select:
      eval(*n.args[0], in, env, [&](const Value& c) {
        if (c.truthy()) out(in);
      });
      return;
    case Builtin::Map: {
      Value::Array items;
      auto each_elem = [&](const Value& e) {
        eval(*n.args[0], e, env, [&](const Value& v) { items.push_back(v); });
      };
      if (in.is_array()) {
        for (const Value& e : in.array()) each_elem(e);
      } else if (in.is_object()) {
        for (const auto& e : in.object()) each_elem(e.value);
      } else {
        throw RuntimeError(std::string("Cannot iterate over ") + in.type_name());
      }
      out(Value::array(std::move(items)));
      return;
    }
    case Builtin::SortBy:
    case Builtin::GroupBy: {
      if (!in.is_array())
        throw RuntimeError(std::string(in.type_name()) + " cannot be sorted, as it is not an array");
      const auto& elems = in.array();
      std::vector<Value> keys;
      keys.reserve(elems.size());
      for (const Value& e : elems) keys.push_back(collect(*n.args[0], e, env));
      std::vector<std::size_t> perm = sorted_permutation(keys);
      Value::Array result;
      if (n.builtin == Builtin::SortBy) {
        result.reserve(elems.size());
        for (std::size_t i : perm) result.push_back(elems[i]);
      } else {
        Value::Array group;
        for (std::size_t j = 0; j < perm.size(); ++j) {
          if (j > 0 && compare(keys[perm[j - 1]], keys[perm[j]]) != 0) {
            result.push_back(Value::array(std::move(group)));
            group.clear();
          }
          group.push_back(elems[perm[j]]);
        }
        if (!group.empty()) result.push_back(Value::array(std::move(group)));
      }
      out(Value::array(std::move(result)));
      return;
    }
  }
}

void Evaluator::eval(const Node& n, const Value& in, const Env* env, Emit out) const {
  switch (n.kind) {
    case NodeKind::Identity: out(in); return;
    case NodeKind::Literal: out(n.literal); return;
    case NodeKind::Var: {
      for (const Env* e = env; e; e = e->parent)
        if (e->var == n.var) {
          out(*e->value);
          return;
        }
      throw RuntimeError("variable is not defined");
    }
    case NodeKind::Neg:
      eval(*n.a, in, env, [&](const Value& v) { out(negate(v)); });
      return;
    case NodeKind::Pipe:
      eval(*n.a, in, env, [&](const Value& v) { eval(*n.b, v, env, out); });
      return;
    case NodeKind::Comma:
      eval(*n.a, in, env, out);
      eval(*n.b, in, env, out);
      return;
    case NodeKind::Binary:
      // The right operand is the outer loop.
      eval(*n.b, in, env, [&](const Value& b) {
        eval(*n.a, in, env, [&](const Value& a) { out(binary_op(n.op, a, b)); });
      });
      return;
    case NodeKind::And:
      eval(*n.a, in, env, [&](const Value& a) {
        if (!a.truthy())
          out(Value::boolean(false));
        else
          eval(*n.b, in, env, [&](const Value& b) { out(Value::boolean(b.truthy())); });
      });
      return;
    case NodeKind::Or:
      eval(*n.a, in, env, [&](const Value& a) {
        if (a.truthy())
          out(Value::boolean(true));
        else
          eval(*n.b, in, env, [&](const Value& b) { out(Value::boolean(b.truthy())); });
      });
      return;
    case NodeKind::Index: eval_index(n, in, env, out); return;
    case NodeKind::Iterate: eval_iterate(n, in, env, out); return;
    case NodeKind::Slice: eval_slice(n, in, env, out); return;
    case NodeKind::Try: eval_try(n, in, env, out); return;
    case NodeKind::Array:
      if (!n.a)
        out(Value::array({}));
      else
        out(collect(*n.a, in, env));
      return;
    case NodeKind::Object: {
      std::vector<std::pair<std::string, Value>> acc;
      eval_object(n, 0, acc, in, env, out);
      return;
    }
    case NodeKind::If:
      eval(*n.a, in, env, [&](const Value& c) {
        if (c.truthy())
          eval(*n.b, in, env, out);
        else if (n.c)
          eval(*n.c, in, env, out);
        else
          out(in);
      });
      return;
    case NodeKind::As:
      eval(*n.a, in, env, [&](const Value& v) {
        Env e{env, n.var, &v};
        eval(*n.b, in, &e, out);
      });
      return;
    case NodeKind::Reduce: eval_reduce(n, in, env, out); return;
    case NodeKind::Call: eval_call(n, in, env, out); return;
  }
}

}  // namespace

void evaluate(const Node& root, const Value& input, Emit out) {
  Evaluator().eval(root, input, nullptr, out);
}

}  // namespace jq::detail
