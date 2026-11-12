#include "traits.h"

#include <algorithm>
#include <set>

namespace langvm {
namespace {

bool hasBound(const TypeParam* p, int trait) {
  return std::find(p->bounds.begin(), p->bounds.end(), trait) != p->bounds.end();
}

bool eqRec(Model& m, Type* t, std::set<int>& assumed) {
  t = prune(t);
  switch (t->kind) {
    case TK::Int: case TK::Float: case TK::Bool: case TK::Char: case TK::Str: case TK::Unit: return true;
    case TK::List: return eqRec(m, t->args[0], assumed);
    case TK::Map: return eqRec(m, t->args[1], assumed);
    case TK::Tuple:
      for (Type* a : t->args)
        if (!eqRec(m, a, assumed)) return false;
      return true;
    case TK::Fn: case TK::Var: return false;
    case TK::Param: return hasBound(t->param, kTraitEq) || hasBound(t->param, kTraitKey);
    case TK::Named: {
      if (assumed.count(t->decl)) return true;
      assumed.insert(t->decl);
      const TypeDeclInfo& d = m.decls[static_cast<size_t>(t->decl)];
      bool ok = true;
      if (d.isEnum) {
        for (const VariantInfo& v : d.variants)
          for (Type* p : v.payload)
            if (ok && !eqRec(m, m.types.subst(p, d.params, t->args), assumed)) ok = false;
      } else {
        for (const FieldInfo& f : d.fields)
          if (ok && !eqRec(m, m.types.subst(f.type, d.params, t->args), assumed)) ok = false;
      }
      assumed.erase(t->decl);
      return ok;
    }
  }
  return false;
}

}  // namespace

bool hasEq(Model& m, Type* t) {
  std::set<int> assumed;
  return eqRec(m, t, assumed);
}

bool hasOrd(Model&, Type* t) {
  t = prune(t);
  switch (t->kind) {
    case TK::Int: case TK::Float: case TK::Bool: case TK::Char: case TK::Str: return true;
    case TK::Param: return hasBound(t->param, kTraitOrd);
    default: return false;
  }
}

bool hasKey(Model&, Type* t) {
  t = prune(t);
  switch (t->kind) {
    case TK::Int: case TK::Bool: case TK::Char: case TK::Str: return true;
    case TK::Param: return hasBound(t->param, kTraitKey);
    default: return false;
  }
}

bool satisfies(Model& m, Type* t, int trait) {
  if (trait == kTraitEq) return hasEq(m, t);
  if (trait == kTraitOrd) return hasOrd(m, t);
  if (trait == kTraitKey) return hasKey(m, t);
  t = prune(t);
  if (t->kind == TK::Param) return hasBound(t->param, trait);
  int ctor = headCtor(t);
  if (ctor < 0) return false;
  const ImplInfo* impl = m.findImpl(trait, ctor);
  if (!impl) return false;
  Type* head = prune(impl->head);
  for (size_t i = 0; i < head->args.size(); ++i) {
    TypeParam* p = prune(head->args[i])->param;
    for (int b : p->bounds)
      if (!satisfies(m, t->args[i], b)) return false;
  }
  return true;
}

}  // namespace langvm
