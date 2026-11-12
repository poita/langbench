#include "types.h"

namespace langvm {

TypeArena::TypeArena() {
  for (int i = 0; i < 6; ++i) prims_[i] = make(static_cast<TK>(i));
}

Type* TypeArena::make(TK k) {
  store_.emplace_back();
  store_.back().kind = k;
  return &store_.back();
}

Type* TypeArena::list(Type* elem) {
  Type* t = make(TK::List);
  t->args = {elem};
  return t;
}
Type* TypeArena::map(Type* k, Type* v) {
  Type* t = make(TK::Map);
  t->args = {k, v};
  return t;
}
Type* TypeArena::tuple(std::vector<Type*> comps) {
  Type* t = make(TK::Tuple);
  t->args = std::move(comps);
  return t;
}
Type* TypeArena::fn(std::vector<Type*> params, Type* ret) {
  Type* t = make(TK::Fn);
  t->args = std::move(params);
  t->args.push_back(ret);
  return t;
}
Type* TypeArena::named(int decl, std::vector<Type*> args) {
  Type* t = make(TK::Named);
  t->decl = decl;
  t->args = std::move(args);
  return t;
}
Type* TypeArena::param(TypeParam* p) {
  Type* t = make(TK::Param);
  t->param = p;
  return t;
}
Type* TypeArena::fresh() { return make(TK::Var); }

Type* TypeArena::subst(Type* t, const std::vector<TypeParam*>& params, const std::vector<Type*>& args) {
  t = prune(t);
  switch (t->kind) {
    case TK::Param:
      for (size_t i = 0; i < params.size(); ++i)
        if (params[i] == t->param) return args[i];
      return t;
    case TK::List: case TK::Map: case TK::Tuple: case TK::Fn: case TK::Named: {
      if (t->args.empty()) return t;
      std::vector<Type*> na;
      na.reserve(t->args.size());
      bool changed = false;
      for (Type* a : t->args) {
        Type* s = subst(a, params, args);
        changed |= s != a;
        na.push_back(s);
      }
      if (!changed) return t;
      Type* r = make(t->kind);
      r->decl = t->decl;
      r->args = std::move(na);
      return r;
    }
    default: return t;
  }
}

Type* prune(Type* t) {
  if (t->kind != TK::Var || !t->ref) return t;
  Type* r = t->ref;
  while (r->kind == TK::Var && r->ref) r = r->ref;
  t->ref = r;
  return r;
}

static bool occurs(Type* v, Type* t) {
  t = prune(t);
  if (t == v) return true;
  for (Type* a : t->args)
    if (occurs(v, a)) return true;
  return false;
}

bool unify(Type* a, Type* b) {
  a = prune(a);
  b = prune(b);
  if (a == b) return true;
  if (a->kind == TK::Var) {
    if (occurs(a, b)) return false;
    a->ref = b;
    return true;
  }
  if (b->kind == TK::Var) {
    if (occurs(b, a)) return false;
    b->ref = a;
    return true;
  }
  if (a->kind != b->kind) return false;
  switch (a->kind) {
    case TK::Param: return a->param == b->param;
    case TK::Named:
      if (a->decl != b->decl) return false;
      break;
    case TK::List: case TK::Map: case TK::Tuple: case TK::Fn: break;
    default: return true;  // identical primitives
  }
  if (a->args.size() != b->args.size()) return false;
  for (size_t i = 0; i < a->args.size(); ++i)
    if (!unify(a->args[i], b->args[i])) return false;
  return true;
}

bool isGround(Type* t) {
  t = prune(t);
  if (t->kind == TK::Var) return false;
  for (Type* a : t->args)
    if (!isGround(a)) return false;
  return true;
}

std::string typeToString(Type* t) {
  t = prune(t);
  auto join = [](const std::vector<Type*>& v, size_t n) {
    std::string s;
    for (size_t i = 0; i < n; ++i) s += (i ? ", " : "") + typeToString(v[i]);
    return s;
  };
  switch (t->kind) {
    case TK::Int: return "Int";
    case TK::Float: return "Float";
    case TK::Bool: return "Bool";
    case TK::Char: return "Char";
    case TK::Str: return "Str";
    case TK::Unit: return "Unit";
    case TK::List: return "[" + typeToString(t->args[0]) + "]";
    case TK::Map: return "#[" + typeToString(t->args[0]) + ": " + typeToString(t->args[1]) + "]";
    case TK::Tuple: return "(" + join(t->args, t->args.size()) + ")";
    case TK::Fn: return "fn(" + join(t->args, t->args.size() - 1) + ") -> " + typeToString(t->args.back());
    case TK::Named: return "#" + std::to_string(t->decl) + "<" + join(t->args, t->args.size()) + ">";
    case TK::Param: return t->param->name;
    case TK::Var: return "?";
  }
  return "?";
}

}  // namespace langvm
