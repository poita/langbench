// Expression typing: the bidirectional rules of SPEC.md sections 9 and 10.
#include <algorithm>

#include "checker.h"
#include "langvm/diagnostic.h"
#include "traits.h"

namespace langvm {

Type* Checker::conform(Expr& e, Type* actual, Type* expected) {
  if (expected && !unify(expected, actual)) err(ErrorKind::TypeMismatch, e.pos);
  return actual;
}

// ------------------------------------------------------------- dispatch

Type* Checker::infer(Expr& e) {
  switch (e.kind) {
    case EK::Int: return A_.intT();
    case EK::Float: return A_.floatT();
    case EK::Str: return A_.strT();
    case EK::Char: return A_.charT();
    case EK::Bool: return A_.boolT();
    case EK::SelfRef: {
      LocalVar* v = lookupVar("self");
      if (!v) err(ErrorKind::SelfOutside, e.pos);
      e.pathKind = PathKind::Local;
      e.var = v;
      return v->type;
    }
    case EK::Path: return typePath(e, nullptr);
    case EK::StructLit: return typeStructLit(e, nullptr);
    case EK::List: return typeList(e, nullptr);
    case EK::Map: return typeMap(e, nullptr);
    case EK::Tuple: return typeTuple(e, nullptr);
    case EK::Lambda: return typeLambda(e, nullptr);
    case EK::If: return typeIf(e, nullptr);
    case EK::Match: return typeMatch(e, nullptr);
    case EK::Unary: return typeUnary(e);
    case EK::Binary: return typeBinary(e);
    case EK::Call: case EK::MethodCall: return typeCall(e, nullptr);
    case EK::Index: return typeIndex(e);
    case EK::Field: return typeField(e);
  }
  return A_.unitT();
}

void Checker::check(Expr& e, Type* expected) {
  switch (e.kind) {
    case EK::Path: typePath(e, expected); return;
    case EK::StructLit: typeStructLit(e, expected); return;
    case EK::List: typeList(e, expected); return;
    case EK::Map: typeMap(e, expected); return;
    case EK::Tuple: typeTuple(e, expected); return;
    case EK::Lambda: typeLambda(e, expected); return;
    case EK::If: typeIf(e, expected); return;
    case EK::Match: typeMatch(e, expected); return;
    case EK::Call: case EK::MethodCall: typeCall(e, expected); return;
    default: conform(e, infer(e), expected); return;
  }
}

// ---------------------------------------------------------- name lookup

const ValueEntry* Checker::findValueEntry(const std::string& name) {
  ModuleInfo& cur = m_.mod(curModule_);
  auto it = cur.values.find(name);
  if (it != cur.values.end()) return &it->second;
  if (curModule_ >= 0) {
    auto p = m_.prelude.values.find(name);
    if (p != m_.prelude.values.end()) return &p->second;
  }
  return nullptr;
}

bool Checker::resolveValue(const std::string& qual, Pos qualPos, const std::string& name, Pos namePos, bool locals,
                           ValueRes& out, bool failOnUnknown) {
  ModuleInfo& cur = m_.mod(curModule_);
  auto fill = [&](const ValueEntry& ve) {
    out.kind = ve.kind == ValueEntry::K::Func ? ValueRes::K::Func : ValueRes::K::Variant;
    out.id = ve.id;
    out.variant = ve.variant;
  };
  if (qual.empty()) {
    if (locals) {
      if (LocalVar* v = lookupVar(name)) {
        out.kind = ValueRes::K::Local;
        out.var = v;
        return true;
      }
    }
    if (const ValueEntry* ve = findValueEntry(name)) {
      fill(*ve);
      return true;
    }
    if (locals) {
      static const char* const prims[] = {"Int", "Float", "Bool", "Char", "Str", "Unit", "Self", "Option", "Result"};
      bool isType = cur.types.count(name) != 0;
      for (const char* p : prims)
        if (name == p) isType = true;
      if (isType) err(ErrorKind::BadValueRef, namePos);
    }
    if (failOnUnknown) err(ErrorKind::UnknownName, namePos);
    return false;
  }
  auto im = cur.imports.find(qual);
  if (im != cur.imports.end()) {
    ModuleInfo& other = m_.mod(im->second);
    auto it = other.values.find(name);
    if (it == other.values.end()) err(ErrorKind::UnknownName, namePos);
    if (!it->second.pub && im->second != curModule_) err(ErrorKind::NotPublic, namePos);
    fill(it->second);
    return true;
  }
  // `Tr::m`: a trait visible in the current module.
  int trait = -1;
  for (int t : cur.visibleTraits)
    if (m_.traits[static_cast<size_t>(t)].name == qual) {
      trait = t;
      break;
    }
  if (trait < 0) {
    auto p = m_.prelude.traits.find(qual);
    if (p != m_.prelude.traits.end()) trait = p->second;
  }
  if (trait < 0) err(ErrorKind::UnknownModule, qualPos);
  const TraitInfo& ti = m_.traits[static_cast<size_t>(trait)];
  for (size_t k = 0; k < ti.methods.size(); ++k)
    if (ti.methods[k].name == name) {
      out.kind = ValueRes::K::TraitMethod;
      out.id = trait;
      out.variant = static_cast<int>(k);
      return true;
    }
  err(ErrorKind::UnknownName, namePos);
}

Checker::CallSig Checker::sigOfFunc(int funcId) {
  const FuncInfo& fi = m_.funcs[static_cast<size_t>(funcId)];
  CallSig s;
  s.tparams = fi.tparams;
  s.params = fi.params;
  s.ret = fi.ret;
  return s;
}

Checker::CallSig Checker::sigOfVariant(int decl, int variant) {
  const TypeDeclInfo& d = m_.decls[static_cast<size_t>(decl)];
  CallSig s;
  s.tparams = d.params;
  s.params = d.variants[static_cast<size_t>(variant)].payload;
  std::vector<Type*> as;
  for (TypeParam* p : d.params) as.push_back(A_.param(p));
  s.ret = A_.named(decl, std::move(as));
  return s;
}

// SPEC 9.4
Type* Checker::callGeneric(Expr& e, const CallSig& sig, Type* expected) {
  if (e.args.size() != sig.params.size()) err(ErrorKind::Arity, e.pos);
  std::vector<Type*> scopeVars;
  varScopes_.push_back(&scopeVars);
  std::vector<Type*> vars;
  for (size_t i = 0; i < sig.tparams.size(); ++i) vars.push_back(freshVar());
  for (size_t i = 0; i < e.args.size(); ++i) check(*e.args[i], A_.subst(sig.params[i], sig.tparams, vars));
  Type* ret = A_.subst(sig.ret, sig.tparams, vars);
  if (expected && !unify(ret, expected)) err(ErrorKind::TypeMismatch, e.pos);
  for (Type* v : scopeVars)
    if (prune(v)->kind == TK::Var) err(ErrorKind::CannotInfer, e.pos);
  for (size_t i = 0; i < sig.tparams.size(); ++i)
    for (int b : sig.tparams[i]->bounds)
      if (!satisfies(m_, vars[i], b)) err(ErrorKind::UnsatisfiedBound, e.pos);
  varScopes_.pop_back();
  return ret;
}

// ----------------------------------------------------------------- paths

Type* Checker::typePath(Expr& e, Type* expected) {
  ValueRes r;
  resolveValue(e.qual, e.qualPos, e.name, e.namePos, true, r);
  switch (r.kind) {
    case ValueRes::K::Local:
      e.pathKind = PathKind::Local;
      e.var = r.var;
      return conform(e, r.var->type, expected);
    case ValueRes::K::Variant: {
      const TypeDeclInfo& d = m_.decls[static_cast<size_t>(r.id)];
      if (!d.variants[static_cast<size_t>(r.variant)].payload.empty()) err(ErrorKind::BadValueRef, e.namePos);
      e.pathKind = PathKind::Variant0;
      e.id = r.id;
      e.id2 = r.variant;
      return callGeneric(e, sigOfVariant(r.id, r.variant), expected);
    }
    default: err(ErrorKind::BadValueRef, e.namePos);
  }
}

// ----------------------------------------------------------------- calls

Type* Checker::typeCall(Expr& e, Type* expected) {
  if (e.kind == EK::MethodCall) {
    if (e.args.size() > 16) err(ErrorKind::BadArity, e.namePos);
    return typeMethodCall(e, expected);
  }
  if (e.args.size() > 16) err(ErrorKind::BadArity, e.pos);
  Expr& callee = *e.lhs;
  if (callee.kind == EK::Path) {
    ValueRes r;
    resolveValue(callee.qual, callee.qualPos, callee.name, callee.namePos, true, r);
    switch (r.kind) {
      case ValueRes::K::Local: break;  // indirect call below
      case ValueRes::K::Func: {
        const FuncInfo& fi = m_.funcs[static_cast<size_t>(r.id)];
        callee.pathKind = PathKind::Func;
        if (fi.kind == FuncInfo::Kind::Builtin) {
          e.callKind = CallKind::Builtin;
          e.id = fi.builtin;
        } else {
          e.callKind = CallKind::Func;
          e.id = r.id;
        }
        return callGeneric(e, sigOfFunc(r.id), expected);
      }
      case ValueRes::K::Variant:
        callee.pathKind = PathKind::VariantCtor;
        e.callKind = CallKind::Variant;
        e.id = r.id;
        e.id2 = r.variant;
        return callGeneric(e, sigOfVariant(r.id, r.variant), expected);
      case ValueRes::K::TraitMethod: return typeTraitMethodCall(e, r.id, r.variant, expected);
    }
  }
  Type* f = prune(infer(callee));
  if (f->kind != TK::Fn) err(ErrorKind::NotCallable, callee.pos);
  if (e.args.size() != fnArity(f)) err(ErrorKind::Arity, callee.pos);
  for (size_t i = 0; i < e.args.size(); ++i) check(*e.args[i], f->args[i]);
  e.callKind = CallKind::Indirect;
  return conform(e, fnRet(f), expected);
}

Type* Checker::typeMethodCall(Expr& e, Type* expected) {
  Type* recv = infer(*e.lhs);
  int trait = -1, method = -1, count = 0;
  const ModuleInfo& cur = m_.mod(curModule_);
  std::vector<int> seen;
  for (int t : cur.visibleTraits) {
    if (std::find(seen.begin(), seen.end(), t) != seen.end()) continue;
    seen.push_back(t);
    const TraitInfo& ti = m_.traits[static_cast<size_t>(t)];
    for (size_t k = 0; k < ti.methods.size(); ++k)
      if (ti.methods[k].name == e.name) {
        ++count;
        trait = t;
        method = static_cast<int>(k);
      }
  }
  if (count == 0) err(ErrorKind::NoMethod, e.namePos);
  if (count > 1) err(ErrorKind::AmbigMethod, e.namePos);
  const TraitInfo& ti = m_.traits[static_cast<size_t>(trait)];
  const TraitMethodInfo& sig = ti.methods[static_cast<size_t>(method)];
  if (e.args.size() != sig.params.size()) err(ErrorKind::Arity, e.namePos);
  if (!satisfies(m_, recv, trait)) err(ErrorKind::UnsatisfiedBound, e.namePos);
  std::vector<TypeParam*> from = {ti.selfParam};
  std::vector<Type*> to = {recv};
  for (size_t i = 0; i < e.args.size(); ++i) check(*e.args[i], A_.subst(sig.params[i], from, to));
  e.callKind = CallKind::Method;
  e.id = trait;
  e.id2 = method;
  return conform(e, A_.subst(sig.ret, from, to), expected);
}

Type* Checker::typeTraitMethodCall(Expr& e, int trait, int method, Type* expected) {
  const TraitInfo& ti = m_.traits[static_cast<size_t>(trait)];
  const TraitMethodInfo& sig = ti.methods[static_cast<size_t>(method)];
  Pos mpos = e.lhs->namePos;
  if (e.args.empty()) err(ErrorKind::Arity, mpos);
  Type* recv = infer(*e.args[0]);
  if (e.args.size() - 1 != sig.params.size()) err(ErrorKind::Arity, mpos);
  if (!satisfies(m_, recv, trait)) err(ErrorKind::UnsatisfiedBound, mpos);
  std::vector<TypeParam*> from = {ti.selfParam};
  std::vector<Type*> to = {recv};
  for (size_t i = 1; i < e.args.size(); ++i) check(*e.args[i], A_.subst(sig.params[i - 1], from, to));
  e.lhs->pathKind = PathKind::TraitMethod;
  e.callKind = CallKind::Method;
  e.id = trait;
  e.id2 = method;
  return conform(e, A_.subst(sig.ret, from, to), expected);
}

// -------------------------------------------------------------- operators

Type* Checker::typeUnary(Expr& e) {
  switch (e.op) {
    case Op::Neg: {
      Type* t = prune(infer(*e.lhs));
      if (t->kind != TK::Int && t->kind != TK::Float) err(ErrorKind::TypeMismatch, e.lhs->pos);
      e.isFloat = t->kind == TK::Float;
      return t;
    }
    case Op::Not: check(*e.lhs, A_.boolT()); return A_.boolT();
    default: check(*e.lhs, A_.intT()); return A_.intT();
  }
}

Type* Checker::typeBinary(Expr& e) {
  Expr& l = *e.lhs;
  Expr& r = *e.rhs;
  switch (e.op) {
    case Op::Add: case Op::Sub: case Op::Mul: case Op::Div: case Op::Mod: {
      Type* t = prune(infer(l));
      if (t->kind != TK::Int && t->kind != TK::Float) err(ErrorKind::TypeMismatch, l.pos);
      if (e.op == Op::Mod && t->kind == TK::Float) err(ErrorKind::TypeMismatch, l.pos);
      check(r, t);
      e.isFloat = t->kind == TK::Float;
      return t;
    }
    case Op::Concat: {
      Type* t = prune(infer(l));
      if (t->kind != TK::Str && t->kind != TK::List) err(ErrorKind::TypeMismatch, l.pos);
      check(r, t);
      return t;
    }
    case Op::BitAnd: case Op::BitOr: case Op::BitXor: case Op::Shl: case Op::Shr:
      check(l, A_.intT());
      check(r, A_.intT());
      return A_.intT();
    case Op::Lt: case Op::Le: case Op::Gt: case Op::Ge: {
      Type* t = infer(l);
      if (!hasOrd(m_, t)) err(ErrorKind::NotOrd, l.pos);
      check(r, t);
      return A_.boolT();
    }
    case Op::Eq: case Op::Ne: {
      Type* t = infer(l);
      if (!hasEq(m_, t)) err(ErrorKind::NotEq, l.pos);
      check(r, t);
      return A_.boolT();
    }
    case Op::And: case Op::Or:
      check(l, A_.boolT());
      check(r, A_.boolT());
      return A_.boolT();
    default: break;
  }
  return A_.unitT();
}

Type* Checker::typeIndex(Expr& e) {
  Type* a = prune(infer(*e.lhs));
  switch (a->kind) {
    case TK::List: check(*e.rhs, A_.intT()); return a->args[0];
    case TK::Str: check(*e.rhs, A_.intT()); return A_.charT();
    case TK::Map: check(*e.rhs, a->args[0]); return a->args[1];
    default: err(ErrorKind::NotIndexable, e.lhs->pos);
  }
}

Type* Checker::typeField(Expr& e) {
  Type* t = prune(infer(*e.lhs));
  if (t->kind != TK::Named || m_.decls[static_cast<size_t>(t->decl)].isEnum) err(ErrorKind::NotStruct, e.lhs->pos);
  const TypeDeclInfo& d = m_.decls[static_cast<size_t>(t->decl)];
  for (size_t i = 0; i < d.fields.size(); ++i)
    if (d.fields[i].name == e.name) {
      e.id2 = static_cast<int>(i);
      return A_.subst(d.fields[i].type, d.params, t->args);
    }
  err(ErrorKind::UnknownField, e.namePos);
}

// ------------------------------------------------------------- aggregates

Type* Checker::typeList(Expr& e, Type* expected) {
  if (!expected) {
    if (e.args.empty()) err(ErrorKind::CannotInfer, e.pos);
    Type* t = infer(*e.args[0]);
    for (size_t i = 1; i < e.args.size(); ++i) check(*e.args[i], t);
    return A_.list(t);
  }
  Type* t = prune(expected);
  if (t->kind == TK::Var) {
    unify(t, A_.list(freshVar()));
    t = prune(t);
  } else if (t->kind != TK::List) {
    err(ErrorKind::TypeMismatch, e.pos);
  }
  for (auto& a : e.args) check(*a, t->args[0]);
  return t;
}

Type* Checker::typeMap(Expr& e, Type* expected) {
  if (!expected) {
    if (e.args.empty()) err(ErrorKind::CannotInfer, e.pos);
    Type* k = infer(*e.args[0]);
    if (!hasKey(m_, k)) err(ErrorKind::BadKeyType, e.args[0]->pos);
    Type* v = infer(*e.args2[0]);
    for (size_t i = 1; i < e.args.size(); ++i) {
      check(*e.args[i], k);
      check(*e.args2[i], v);
    }
    return A_.map(k, v);
  }
  Type* t = prune(expected);
  bool expanded = false;
  if (t->kind == TK::Var) {
    unify(t, A_.map(freshVar(), freshVar()));
    t = prune(t);
    expanded = true;
  } else if (t->kind != TK::Map) {
    err(ErrorKind::TypeMismatch, e.pos);
  }
  for (size_t i = 0; i < e.args.size(); ++i) {
    check(*e.args[i], t->args[0]);
    check(*e.args2[i], t->args[1]);
  }
  if (expanded && isGround(t->args[0]) && !hasKey(m_, t->args[0])) err(ErrorKind::BadKeyType, e.pos);
  return t;
}

Type* Checker::typeTuple(Expr& e, Type* expected) {
  if (e.args.size() > 8) err(ErrorKind::BadArity, e.pos);
  if (!expected) {
    std::vector<Type*> cs;
    for (auto& a : e.args) cs.push_back(infer(*a));
    return A_.tuple(std::move(cs));
  }
  Type* t = prune(expected);
  if (t->kind == TK::Var) {
    std::vector<Type*> cs;
    for (size_t i = 0; i < e.args.size(); ++i) cs.push_back(freshVar());
    unify(t, A_.tuple(std::move(cs)));
    t = prune(t);
  } else if (t->kind != TK::Tuple || t->args.size() != e.args.size()) {
    err(ErrorKind::TypeMismatch, e.pos);
  }
  for (size_t i = 0; i < e.args.size(); ++i) check(*e.args[i], t->args[i]);
  return t;
}

int Checker::resolveStructDecl(const std::string& qual, Pos qualPos, const std::string& name, Pos namePos, Pos at,
                               Type** selfOut) {
  *selfOut = nullptr;
  ModuleInfo& cur = m_.mod(curModule_);
  int decl = -1;
  if (!qual.empty()) {
    auto im = cur.imports.find(qual);
    if (im == cur.imports.end()) err(ErrorKind::UnknownModule, qualPos);
    ModuleInfo& other = m_.mod(im->second);
    auto it = other.types.find(name);
    if (it == other.types.end()) err(ErrorKind::UnknownType, namePos);
    if (!m_.decls[static_cast<size_t>(it->second)].pub && im->second != curModule_) err(ErrorKind::NotPublic, namePos);
    decl = it->second;
  } else {
    for (TypeParam* p : tscope_.params)
      if (p->name == name) err(ErrorKind::NotStruct, at);
    if (name == "Self") {
      if (!tscope_.self) err(ErrorKind::SelfOutside, at);
      Type* s = prune(tscope_.self);
      if (s->kind != TK::Named) err(ErrorKind::NotStruct, at);
      decl = s->decl;
      *selfOut = s;
    } else if (name == "Int" || name == "Float" || name == "Bool" || name == "Char" || name == "Str" ||
               name == "Unit") {
      err(ErrorKind::NotStruct, at);
    } else if (auto it = cur.types.find(name); it != cur.types.end()) {
      decl = it->second;
    } else if (name == "Option") {
      decl = m_.optionDecl;
    } else if (name == "Result") {
      decl = m_.resultDecl;
    } else {
      err(ErrorKind::UnknownType, namePos);
    }
  }
  if (m_.decls[static_cast<size_t>(decl)].isEnum) err(ErrorKind::NotStruct, at);
  return decl;
}

Type* Checker::typeStructLit(Expr& e, Type* expected) {
  Type* selfT;
  int decl = resolveStructDecl(e.qual, e.qualPos, e.name, e.namePos, e.pos, &selfT);
  const TypeDeclInfo& d = m_.decls[static_cast<size_t>(decl)];
  std::vector<Type*> scopeVars;
  varScopes_.push_back(&scopeVars);
  std::vector<Type*> targs;
  for (size_t i = 0; i < d.params.size(); ++i) targs.push_back(freshVar());
  Type* st = A_.named(decl, targs);
  if (selfT) unify(st, selfT);
  if (expected && !unify(st, expected)) err(ErrorKind::TypeMismatch, e.pos);
  for (size_t i = 0; i < e.fields.size(); ++i) {
    FieldInit& f = e.fields[i];
    for (size_t j = 0; j < i; ++j)
      if (e.fields[j].name == f.name) err(ErrorKind::DupField, f.pos);
    int idx = -1;
    for (size_t k = 0; k < d.fields.size(); ++k)
      if (d.fields[k].name == f.name) idx = static_cast<int>(k);
    if (idx < 0) err(ErrorKind::UnknownField, f.pos);
    f.fieldIdx = idx;
  }
  for (size_t k = 0; k < d.fields.size(); ++k) {
    FieldInit* given = nullptr;
    for (FieldInit& f : e.fields)
      if (f.fieldIdx == static_cast<int>(k)) given = &f;
    if (!given) err(ErrorKind::MissingField, e.pos);
    check(*given->value, A_.subst(d.fields[k].type, d.params, targs));
  }
  for (Type* v : scopeVars)
    if (prune(v)->kind == TK::Var) err(ErrorKind::CannotInfer, e.pos);
  varScopes_.pop_back();
  e.id = decl;
  return st;
}

// ---------------------------------------------------------------- lambdas

Type* Checker::typeLambda(Expr& e, Type* expected) {
  size_t n = e.lparams.size();
  std::vector<Type*> ptypes;
  Type* ret = nullptr;
  Type* result = nullptr;
  if (expected) {
    Type* t = prune(expected);
    if (t->kind == TK::Var) {
      std::vector<Type*> ps;
      for (size_t i = 0; i < n; ++i) ps.push_back(freshVar());
      unify(t, A_.fn(std::move(ps), freshVar()));
      t = prune(t);
    } else if (t->kind != TK::Fn || fnArity(t) != n) {
      err(ErrorKind::TypeMismatch, e.pos);
    }
    for (size_t i = 0; i < n; ++i) {
      LParam& p = e.lparams[i];
      Type* ai = t->args[i];
      if (p.type) {
        Type* ann = R_.resolveType(*p.type, tscope_);
        if (!unify(ai, ann)) err(ErrorKind::TypeMismatch, p.type->pos);
      } else if (prune(ai)->kind == TK::Var) {
        err(ErrorKind::CannotInfer, p.pos);
      }
      ptypes.push_back(ai);
    }
    ret = fnRet(t);
    if (e.lret) {
      Type* rt = R_.resolveType(*e.lret, tscope_);
      if (!unify(ret, rt)) err(ErrorKind::TypeMismatch, e.lret->pos);
    }
    result = t;
  } else {
    for (LParam& p : e.lparams) {
      if (!p.type) err(ErrorKind::CannotInfer, p.pos);
      ptypes.push_back(R_.resolveType(*p.type, tscope_));
    }
    if (e.lret) ret = R_.resolveType(*e.lret, tscope_);
  }
  for (size_t i = 0; i < n; ++i)
    for (size_t j = 0; j < i; ++j)
      if (e.lparams[j].name == e.lparams[i].name) err(ErrorKind::DupName, e.lparams[i].pos);

  FnCtx ctx;
  ctx.id = nextFnId_++;
  ctx.ret = ret;
  fnStack_.push_back(&ctx);
  pushScope();
  for (size_t i = 0; i < n; ++i) e.lparams[i].var = declare(e.lparams[i].name, ptypes[i], false);
  Block& body = *e.body;
  if (ret) {
    checkFnBody(body, ret, e.pos);
  } else {
    checkBlockStmts(body);
    ret = body.tail ? infer(*body.tail) : A_.unitT();
  }
  popScope();
  fnStack_.pop_back();
  e.captures = ctx.captures;
  // A lambda that captures a variable of an outer function makes that outer
  // lambda capture it too (handled in lookupVar); nothing more to do here.
  if (!result) result = A_.fn(std::move(ptypes), ret);
  return result;
}

// -------------------------------------------------------------- if / match

Type* Checker::typeIf(Expr& e, Type* expected) {
  check(*e.cond, A_.boolT());
  bool hasElse = e.elseB || e.elseIf;
  if (!hasElse) {
    if (expected && !unify(expected, A_.unitT())) err(ErrorKind::TypeMismatch, e.pos);
    checkBlock(*e.thenB, A_.unitT());
    return A_.unitT();
  }
  auto elseDiverges = [&]() { return e.elseB ? blockDiverges(*e.elseB) : exprDiverges(*e.elseIf); };
  if (expected) {
    checkBlock(*e.thenB, expected);
    if (e.elseB) checkBlock(*e.elseB, expected);
    else check(*e.elseIf, expected);
    return expected;
  }
  if (!blockDiverges(*e.thenB)) {
    Type* t = inferBlock(*e.thenB);
    if (e.elseB) checkBlock(*e.elseB, t);
    else check(*e.elseIf, t);
    return t;
  }
  inferBlock(*e.thenB);
  bool d2 = elseDiverges();
  Type* r = e.elseB ? inferBlock(*e.elseB) : infer(*e.elseIf);
  return d2 ? A_.unitT() : r;
}

Type* Checker::typeMatch(Expr& e, Type* expected) {
  Type* s = infer(*e.scrut);
  if (e.arms.empty()) err(ErrorKind::NonExhaustive, e.pos);
  Type* r = expected;
  for (Arm& arm : e.arms) {
    pushScope();
    checkPatternTop(*arm.pat, s);
    if (arm.guard) check(*arm.guard, A_.boolT());
    if (expected) {
      checkBlock(*arm.body, expected);
    } else if (!r) {
      if (!blockDiverges(*arm.body)) r = inferBlock(*arm.body);
      else inferBlock(*arm.body);
    } else {
      checkBlock(*arm.body, r);
    }
    popScope();
  }
  checkMatchCoverage(e, s);
  return r ? r : A_.unitT();
}

}  // namespace langvm
