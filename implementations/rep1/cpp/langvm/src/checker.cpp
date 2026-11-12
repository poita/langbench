#include "checker.h"

#include "langvm/diagnostic.h"
#include "traits.h"

namespace langvm {

void Checker::err(ErrorKind k, Pos p) const { throw CompileError(k, p.line, p.col); }

// ------------------------------------------------------------------ scopes

void Checker::popScope() {
  size_t mark = marks_.back();
  marks_.pop_back();
  while (undo_.size() > mark) {
    auto it = vars_.find(undo_.back());
    it->second.pop_back();
    if (it->second.empty()) vars_.erase(it);
    undo_.pop_back();
  }
}

LocalVar* Checker::declare(const std::string& name, Type* t, bool isMut) {
  LocalVar* v = m_.newLocal(name, t, isMut, fnStack_.back()->id);
  vars_[name].push_back(v);
  undo_.push_back(name);
  return v;
}

LocalVar* Checker::lookupVar(const std::string& name) {
  auto it = vars_.find(name);
  if (it == vars_.end()) return nullptr;
  LocalVar* v = it->second.back();
  // Record captures through every enclosing lambda up to the variable's owner.
  for (size_t i = fnStack_.size(); i-- > 0;) {
    FnCtx* c = fnStack_[i];
    if (c->id == v->ownerFn) break;
    bool have = false;
    for (LocalVar* x : c->captures)
      if (x == v) have = true;
    if (!have) c->captures.push_back(v);
  }
  return v;
}

Type* Checker::freshVar() {
  Type* v = A_.fresh();
  if (!varScopes_.empty()) varScopes_.back()->push_back(v);
  return v;
}

// -------------------------------------------------------------- divergence

bool Checker::exprDiverges(Expr& e) {
  if (e.divergesCache >= 0) return e.divergesCache != 0;
  bool d = false;
  if (e.kind == EK::If) {
    if (e.elseB) d = blockDiverges(*e.thenB) && blockDiverges(*e.elseB);
    else if (e.elseIf) d = blockDiverges(*e.thenB) && exprDiverges(*e.elseIf);
  } else if (e.kind == EK::Match) {
    d = !e.arms.empty();
    for (Arm& a : e.arms)
      if (d && !blockDiverges(*a.body)) d = false;
  }
  e.divergesCache = d ? 1 : 0;
  return d;
}

bool Checker::stmtDiverges(Stmt& s) {
  switch (s.kind) {
    case Stmt::K::Return: case Stmt::K::Break: case Stmt::K::Continue: return true;
    case Stmt::K::Let: case Stmt::K::Var: case Stmt::K::Expr: return exprDiverges(*s.expr);
    case Stmt::K::Assign: return exprDiverges(*s.expr2);
    default: return false;
  }
}

bool Checker::blockDiverges(Block& b) {
  if (b.divergesCache >= 0) return b.divergesCache != 0;
  bool d = false;
  for (auto& s : b.stmts)
    if (stmtDiverges(*s)) d = true;
  if (!d && b.tail && exprDiverges(*b.tail)) d = true;
  b.divergesCache = d ? 1 : 0;
  return d;
}

// ------------------------------------------------------------------- items

void Checker::checkAll() {
  for (size_t mi = 0; mi < m_.modules.size(); ++mi) {
    ModuleInfo& mod = m_.modules[mi];
    for (const Item& it : mod.ast.items) {
      switch (it.kind) {
        case ItemKind::Fn: checkFunction(mod.ast.fns[it.index]->funcId); break;
        case ItemKind::Trait:
          for (FnDecl& f : mod.ast.traits[it.index]->methods)
            if (f.body) checkFunction(f.funcId);
          break;
        case ItemKind::Impl:
          for (FnDecl& f : mod.ast.impls[it.index]->methods) checkFunction(f.funcId);
          break;
        default: break;
      }
    }
  }
}

void Checker::checkFunction(int funcId) {
  FuncInfo& fi = m_.funcs[static_cast<size_t>(funcId)];
  FnDecl& f = *fi.ast;
  curModule_ = fi.module;
  tscope_ = TypeScope{fi.module, fi.scopeParams, fi.selfType};
  FnCtx ctx;
  ctx.id = nextFnId_++;
  ctx.ret = fi.ret;
  fnStack_.assign(1, &ctx);
  vars_.clear();
  undo_.clear();
  marks_.clear();
  varScopes_.clear();
  pushScope();
  if (f.hasSelf) f.selfVar = declare("self", fi.selfType, false);
  for (size_t i = 0; i < f.params.size(); ++i) f.params[i].var = declare(f.params[i].name, fi.params[i], false);
  checkFnBody(*f.body, fi.ret, f.pos);
  popScope();
}

// SPEC 11.6: statements, then the trailing expression against the return type.
void Checker::checkFnBody(Block& body, Type* ret, Pos missingReturnPos) {
  checkBlockStmts(body);
  if (body.tail) {
    check(*body.tail, ret);
  } else if (prune(ret)->kind != TK::Unit && !blockDiverges(body)) {
    err(ErrorKind::MissingReturn, missingReturnPos);
  }
}

// ------------------------------------------------------------------ blocks

void Checker::checkBlockStmts(Block& b) {
  for (auto& s : b.stmts) checkStmt(*s);
}

Type* Checker::inferBlock(Block& b) {
  pushScope();
  checkBlockStmts(b);
  Type* t = b.tail ? infer(*b.tail) : A_.unitT();
  popScope();
  return t;
}

void Checker::checkBlock(Block& b, Type* expected) {
  pushScope();
  checkBlockStmts(b);
  if (b.tail) {
    check(*b.tail, expected);
  } else if (!blockDiverges(b)) {
    if (!unify(expected, A_.unitT())) err(ErrorKind::TypeMismatch, b.pos);
  }
  popScope();
}

void Checker::checkStmtBlock(Block& b) {
  pushScope();
  checkBlockStmts(b);
  if (b.tail) infer(*b.tail);
  popScope();
}

// -------------------------------------------------------------- statements

void Checker::checkStmt(Stmt& s) {
  switch (s.kind) {
    case Stmt::K::Let: checkLet(s); break;
    case Stmt::K::Var: {
      Type* t;
      if (s.type) {
        t = R_.resolveType(*s.type, tscope_);
        check(*s.expr, t);
      } else {
        t = infer(*s.expr);
      }
      s.var = declare(s.name, t, true);
      break;
    }
    case Stmt::K::Assign: checkAssign(s); break;
    case Stmt::K::Expr: infer(*s.expr); break;
    case Stmt::K::Return: checkReturn(s); break;
    case Stmt::K::While:
      check(*s.expr, A_.boolT());
      ++fnStack_.back()->loopDepth;
      checkStmtBlock(*s.body);
      --fnStack_.back()->loopDepth;
      break;
    case Stmt::K::For: checkFor(s); break;
    case Stmt::K::Break: case Stmt::K::Continue:
      if (fnStack_.back()->loopDepth == 0) err(ErrorKind::BreakOutside, s.pos);
      break;
  }
}

void Checker::checkLet(Stmt& s) {
  Type* t;
  if (s.type) {
    t = R_.resolveType(*s.type, tscope_);
    check(*s.expr, t);
  } else {
    t = infer(*s.expr);
  }
  checkPatternTop(*s.pat, t);
  if (!irrefutable(*s.pat)) err(ErrorKind::RefutablePattern, s.pat->pos);
}

void Checker::checkFor(Stmt& s) {
  Type* elem;
  if (s.isRange) {
    check(*s.expr, A_.intT());
    check(*s.expr2, A_.intT());
    elem = A_.intT();
  } else {
    Type* st = prune(infer(*s.expr));
    if (st->kind == TK::List) elem = st->args[0];
    else if (st->kind == TK::Str) elem = A_.charT();
    else err(ErrorKind::NotIterable, s.expr->pos);
  }
  pushScope();
  checkPatternTop(*s.pat, elem);
  if (!irrefutable(*s.pat)) err(ErrorKind::RefutablePattern, s.pat->pos);
  ++fnStack_.back()->loopDepth;
  checkStmtBlock(*s.body);
  --fnStack_.back()->loopDepth;
  popScope();
}

void Checker::checkAssign(Stmt& s) {
  Expr& target = *s.expr;
  if (target.kind == EK::Path && target.qual.empty()) {
    auto it = vars_.find(target.name);
    if (it == vars_.end()) err(ErrorKind::UnknownName, target.namePos);
    LocalVar* v = it->second.back();
    if (!v->isMut) err(ErrorKind::AssignImmutable, target.pos);
    if (v->ownerFn != fnStack_.back()->id) err(ErrorKind::AssignCaptured, target.pos);
    target.pathKind = PathKind::Local;
    target.var = v;
    check(*s.expr2, v->type);
  } else if (target.kind == EK::Index) {
    Type* a = prune(infer(*target.lhs));
    if (a->kind == TK::List) {
      check(*target.rhs, A_.intT());
      check(*s.expr2, a->args[0]);
    } else if (a->kind == TK::Map) {
      check(*target.rhs, a->args[0]);
      check(*s.expr2, a->args[1]);
    } else {
      err(ErrorKind::BadTarget, target.lhs->pos);
    }
  } else {
    err(ErrorKind::BadTarget, target.pos);
  }
}

void Checker::checkReturn(Stmt& s) {
  FnCtx* ctx = fnStack_.back();
  if (s.expr) {
    if (!ctx->ret) err(ErrorKind::CannotInfer, s.pos);
    if (prune(ctx->ret)->kind == TK::Unit) {
      Type* t = infer(*s.expr);
      if (prune(t)->kind != TK::Unit) err(ErrorKind::TypeMismatch, s.pos);
    } else {
      check(*s.expr, ctx->ret);
    }
  } else {
    if (!ctx->ret) err(ErrorKind::CannotInfer, s.pos);
    if (!unify(ctx->ret, A_.unitT())) err(ErrorKind::TypeMismatch, s.pos);
  }
}

}  // namespace langvm
