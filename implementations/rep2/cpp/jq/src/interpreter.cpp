// The tree-walking evaluator.
//
// Evaluation is in continuation-passing style: eval(node, input, env, out)
// calls `out` once per output, in order, and returns false as soon as an
// error has been raised or `out` returned false. Streams are therefore lazy
// and cost O(1) memory per generator regardless of how many values they yield.
#include <algorithm>
#include <type_traits>

#include "jq/filter.hpp"
#include "ops.hpp"
#include "parser.hpp"

namespace jq {

namespace detail {
namespace {

/// Non-owning reference to a callable `bool(const Value&)`.
class Sink {
 public:
  template <class F, class = std::enable_if_t<!std::is_same_v<std::remove_cv_t<F>, Sink>>>
  Sink(F& f) : obj_(const_cast<void*>(static_cast<const void*>(&f))), fn_([](void* o, const Value& v) {
    return (*static_cast<F*>(o))(v);
  }) {}
  bool operator()(const Value& v) const { return fn_(obj_, v); }

 private:
  void* obj_;
  bool (*fn_)(void*, const Value&);
};

/// A variable binding; lives on the C++ stack for the extent of its scope.
struct Env {
  const std::string* name;
  Value value;
  const Env* parent;
};

class Evaluator {
 public:
  bool eval(const Node& n, const Value& in, const Env* env, Sink out);

  std::string error;

 private:
  bool fail(std::string msg) {
    error = std::move(msg);
    return false;
  }
  bool eval_call(const Node& n, const Value& in, const Env* env, Sink out);
  bool eval_object(const Node& n, std::size_t i, std::vector<Member>& acc, const Value& in, const Env* env, Sink out);
  bool eval_iterate_value(const Node& n, const Value& t, Sink out);
  bool eval_keyed(const Node& n, const Env* env, std::vector<Value>& keys, const Value& source);
  bool eval_sort_group(const Node& n, const Value& in, const Env* env, Sink out, bool group);
  bool eval_slice(const Node& n, const Value& in, const Env* env, Sink out);
};

bool Evaluator::eval_iterate_value(const Node& n, const Value& t, Sink out) {
  if (t.is_array()) {
    for (const Value& e : t.as_array())
      if (!out(e)) return false;
    return true;
  }
  if (t.is_object()) {
    for (const Member& m : t.as_object().members())
      if (!out(m.value)) return false;
    return true;
  }
  if (n.opt) return true;
  return fail(std::string("Cannot iterate over ") + t.type_name());
}

bool Evaluator::eval_slice(const Node& n, const Value& in, const Env* env, Sink out) {
  // for each from, for each to, for each target
  auto with_from = [&](const Value* from) {
    auto with_to = [&](const Value* to) {
      auto on_target = [&](const Value& t) {
        Value r;
        std::string err;
        if (!slice_value(t, from, to, r, n.opt ? nullptr : &err)) return n.opt ? true : fail(std::move(err));
        return out(r);
      };
      return eval(*n.a, in, env, on_target);
    };
    if (!n.c) return with_to(nullptr);
    auto each_to = [&](const Value& v) { return with_to(&v); };
    return eval(*n.c, in, env, each_to);
  };
  if (!n.b) return with_from(nullptr);
  auto each_from = [&](const Value& v) { return with_from(&v); };
  return eval(*n.b, in, env, each_from);
}

bool Evaluator::eval_object(const Node& n, std::size_t i, std::vector<Member>& acc, const Value& in, const Env* env,
                            Sink out) {
  if (i == n.entries.size()) {
    ObjectBuilder b;
    b.reserve(acc.size());
    for (const Member& m : acc) b.set(m.key, m.value);
    return out(b.build());
  }
  const ObjEntry& e = n.entries[i];
  auto on_key = [&](const Value& k) {
    if (!k.is_string()) return fail(std::string("Object keys must be strings, not ") + k.type_name());
    auto on_value = [&](const Value& v) {
      acc.push_back(Member{k.as_string(), v});
      bool r = eval_object(n, i + 1, acc, in, env, out);
      acc.pop_back();
      return r;
    };
    return eval(*e.value, in, env, on_value);
  };
  return eval(*e.key, in, env, on_key);
}

// Evaluates the key expression `n.args[0]` once per element of the array
// `source`, storing the key `[f]` of each element in `keys`.
bool Evaluator::eval_keyed(const Node& n, const Env* env, std::vector<Value>& keys, const Value& source) {
  const Node& f = *n.args[0];
  keys.reserve(source.as_array().size());
  for (const Value& el : source.as_array()) {
    std::vector<Value> k;
    auto collect = [&](const Value& v) {
      k.push_back(v);
      return true;
    };
    if (!eval(f, el, env, collect)) return false;
    keys.push_back(Value::array(std::move(k)));
  }
  return true;
}

bool Evaluator::eval_sort_group(const Node& n, const Value& in, const Env* env, Sink out, bool group) {
  if (!in.is_array()) return fail(std::string(in.type_name()) + " cannot be sorted, as it is not an array");
  std::vector<Value> keys;
  if (!eval_keyed(n, env, keys, in)) return false;
  std::vector<std::size_t> order = stable_order(keys);
  const auto& items = in.as_array();
  if (!group) {
    std::vector<Value> sorted;
    sorted.reserve(order.size());
    for (std::size_t i : order) sorted.push_back(items[i]);
    return out(Value::array(std::move(sorted)));
  }
  std::vector<Value> groups;
  std::vector<Value> cur;
  for (std::size_t j = 0; j < order.size(); ++j) {
    if (j > 0 && compare(keys[order[j - 1]], keys[order[j]]) != 0) {
      groups.push_back(Value::array(std::move(cur)));
      cur.clear();
    }
    cur.push_back(items[order[j]]);
  }
  if (!cur.empty()) groups.push_back(Value::array(std::move(cur)));
  return out(Value::array(std::move(groups)));
}

bool Evaluator::eval_call(const Node& n, const Value& in, const Env* env, Sink out) {
  std::string err;
  Value r;
  switch (n.builtin) {
    case Builtin::Empty: return true;
    case Builtin::Error: {
      if (n.args.empty()) return fail("error: " + to_json(in));
      auto first = [&](const Value& v) {
        error = "error: " + to_json(v);
        return false;
      };
      return eval(*n.args[0], in, env, first);
    }
    case Builtin::Not: return out(Value::boolean(!in.truthy()));
    case Builtin::Length:
      if (!value_length(in, r, &err)) return fail(std::move(err));
      return out(r);
    case Builtin::Keys:
      if (!value_keys(in, r, &err)) return fail(std::move(err));
      return out(r);
    case Builtin::Has: {
      auto on_key = [&](const Value& k) {
        bool b = false;
        std::string e;
        if (!value_has(in, k, b, &e)) return fail(std::move(e));
        return out(Value::boolean(b));
      };
      return eval(*n.args[0], in, env, on_key);
    }
    case Builtin::Type: return out(Value::string(in.type_name()));
    case Builtin::Add:
      if (!value_add(in, r, &err)) return fail(std::move(err));
      return out(r);
    case Builtin::Select: {
      auto on_cond = [&](const Value& c) { return c.truthy() ? out(in) : true; };
      return eval(*n.args[0], in, env, on_cond);
    }
    case Builtin::Map: {
      std::vector<Value> res;
      auto collect = [&](const Value& v) {
        res.push_back(v);
        return true;
      };
      auto each = [&](const Value& el) { return eval(*n.args[0], el, env, collect); };
      if (!in.is_array() && !in.is_object()) return fail(std::string("Cannot iterate over ") + in.type_name());
      if (!eval_iterate_value(n, in, each)) return false;
      return out(Value::array(std::move(res)));
    }
    case Builtin::Sort:
      if (!value_sort(in, r, &err)) return fail(std::move(err));
      return out(r);
    case Builtin::SortBy: return eval_sort_group(n, in, env, out, false);
    case Builtin::GroupBy: return eval_sort_group(n, in, env, out, true);
    case Builtin::Unique:
      if (!value_unique(in, r, &err)) return fail(std::move(err));
      return out(r);
    case Builtin::Reverse:
      if (!value_reverse(in, r, &err)) return fail(std::move(err));
      return out(r);
    case Builtin::Min:
    case Builtin::Max:
      if (!value_min_max(in, n.builtin == Builtin::Max, r, &err)) return fail(std::move(err));
      return out(r);
    case Builtin::ToString: return out(value_tostring(in));
    case Builtin::ToNumber:
      if (!value_tonumber(in, r, &err)) return fail(std::move(err));
      return out(r);
  }
  return fail("unknown builtin");
}

bool Evaluator::eval(const Node& n, const Value& in, const Env* env, Sink out) {
  switch (n.kind) {
    case Kind::Identity: return out(in);
    case Kind::Literal: return out(n.lit);
    case Kind::Var: {
      for (const Env* e = env; e; e = e->parent)
        if (*e->name == n.name) return out(e->value);
      return fail("$" + n.name + " is not defined");
    }
    case Kind::Neg: {
      auto on = [&](const Value& v) {
        if (!v.is_number()) return fail(std::string(v.type_name()) + " cannot be negated");
        return out(Value::number(-v.as_number()));
      };
      return eval(*n.a, in, env, on);
    }
    case Kind::Pipe: {
      auto next = [&](const Value& v) { return eval(*n.b, v, env, out); };
      return eval(*n.a, in, env, next);
    }
    case Kind::Comma: return eval(*n.a, in, env, out) && eval(*n.b, in, env, out);
    case Kind::Binary: {
      auto on_right = [&](const Value& r) {
        auto on_left = [&](const Value& l) {
          Value res;
          std::string err;
          if (!binary_op(n.op, l, r, res, &err)) return fail(std::move(err));
          return out(res);
        };
        return eval(*n.a, in, env, on_left);
      };
      return eval(*n.b, in, env, on_right);
    }
    case Kind::And:
    case Kind::Or: {
      const bool is_and = n.kind == Kind::And;
      auto on_left = [&](const Value& a) {
        if (a.truthy() != is_and) return out(Value::boolean(!is_and));
        auto on_right = [&](const Value& b) { return out(Value::boolean(b.truthy())); };
        return eval(*n.b, in, env, on_right);
      };
      return eval(*n.a, in, env, on_left);
    }
    case Kind::Index: {
      auto with_key = [&](const Value& k) {
        auto on_target = [&](const Value& t) {
          Value r;
          std::string err;
          if (!index_value(t, k, r, n.opt ? nullptr : &err)) return n.opt ? true : fail(std::move(err));
          return out(r);
        };
        return n.a->kind == Kind::Identity ? on_target(in) : eval(*n.a, in, env, on_target);
      };
      if (n.b->kind == Kind::Literal) return with_key(n.b->lit);
      return eval(*n.b, in, env, with_key);
    }
    case Kind::Slice: return eval_slice(n, in, env, out);
    case Kind::Iterate: {
      auto on_target = [&](const Value& t) { return eval_iterate_value(n, t, out); };
      return n.a->kind == Kind::Identity ? on_target(in) : eval(*n.a, in, env, on_target);
    }
    case Kind::Try: {
      bool downstream = false;
      auto guarded = [&](const Value& v) {
        if (out(v)) return true;
        downstream = true;  // the failure belongs to the consumer, not to the try body
        return false;
      };
      if (eval(*n.a, in, env, guarded)) return true;
      return !downstream;  // swallow errors raised inside the body; the term just ends
    }
    case Kind::Array: {
      std::vector<Value> items;
      if (n.a) {
        auto collect = [&](const Value& v) {
          items.push_back(v);
          return true;
        };
        if (!eval(*n.a, in, env, collect)) return false;
      }
      return out(Value::array(std::move(items)));
    }
    case Kind::Object: {
      std::vector<Member> acc;
      acc.reserve(n.entries.size());
      return eval_object(n, 0, acc, in, env, out);
    }
    case Kind::If: {
      auto on_cond = [&](const Value& c) {
        if (c.truthy()) return eval(*n.b, in, env, out);
        if (n.c) return eval(*n.c, in, env, out);
        return out(in);
      };
      return eval(*n.a, in, env, on_cond);
    }
    case Kind::As: {
      auto bind = [&](const Value& v) {
        Env e{&n.name, v, env};
        return eval(*n.b, in, &e, out);
      };
      return eval(*n.a, in, env, bind);
    }
    case Kind::Reduce: {
      auto on_init = [&](const Value& init) {
        Value acc = init;
        auto step = [&](const Value& v) {
          Env e{&n.name, v, env};
          Value last;
          auto keep = [&](const Value& u) {
            last = u;
            return true;
          };
          if (!eval(*n.c, acc, &e, keep)) return false;
          acc = std::move(last);
          return true;
        };
        if (!eval(*n.a, in, env, step)) return false;
        return out(acc);
      };
      return eval(*n.b, in, env, on_init);
    }
    case Kind::Call: return eval_call(n, in, env, out);
  }
  return fail("bad node");
}

}  // namespace
}  // namespace detail

Filter Filter::compile(std::string_view program) {
  return Filter(std::shared_ptr<const detail::Node>(detail::parse_program(program)));
}

RunStatus Filter::run(const Value& input, const Sink& sink) const {
  detail::Evaluator ev;
  bool stopped = false;
  auto out = [&](const Value& v) {
    if (sink(v)) return true;
    stopped = true;
    return false;
  };
  RunStatus st;
  if (!ev.eval(*root_, input, nullptr, out) && !stopped) {
    st.ok = false;
    st.error = std::move(ev.error);
  }
  return st;
}

std::vector<Value> Filter::run_all(const Value& input) const {
  std::vector<Value> results;
  RunStatus st = run(input, [&](const Value& v) {
    results.push_back(v);
    return true;
  });
  if (!st.ok) throw EvalError(st.error);
  return results;
}

std::string run_to_text(std::string_view program, std::string_view document) {
  Filter f = Filter::compile(program);
  Value doc = parse_json(document);
  std::string text;
  RunStatus st = f.run(doc, [&](const Value& v) {
    write_json(v, text);
    text += '\n';
    return true;
  });
  if (!st.ok) text += "error\n";
  return text;
}

}  // namespace jq
