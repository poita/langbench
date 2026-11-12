// Pass 4: body checking (SPEC.md sections 9-12). Annotates the syntax tree
// with everything the bytecode compiler needs.
#pragma once

#include <set>
#include <string>
#include <unordered_map>
#include <vector>

#include "langvm/diagnostic.h"
#include "model.h"
#include "resolver.h"

namespace langvm {

class Checker {
 public:
  Checker(Model& m, Resolver& r) : m_(m), R_(r), A_(m.types) {}

  // Checks every body of every module in order; throws CompileError.
  void checkAll();

 private:
  Model& m_;
  Resolver& R_;
  TypeArena& A_;

  // ----- per-function context
  struct FnCtx {
    int id = 0;
    Type* ret = nullptr;  // null: not yet known (lambda in synthesis mode)
    int loopDepth = 0;
    std::vector<LocalVar*> captures;
  };
  std::vector<FnCtx*> fnStack_;
  int nextFnId_ = 1;
  int curModule_ = 0;
  TypeScope tscope_;

  // ----- local variable scopes
  std::unordered_map<std::string, std::vector<LocalVar*>> vars_;
  std::vector<std::string> undo_;
  std::vector<size_t> marks_;
  void pushScope() { marks_.push_back(undo_.size()); }
  void popScope();
  LocalVar* declare(const std::string& name, Type* t, bool isMut);
  LocalVar* lookupVar(const std::string& name);

  // ----- inference variable scopes (SPEC 9.2)
  std::vector<std::vector<Type*>*> varScopes_;
  Type* freshVar();

  [[noreturn]] void err(ErrorKind k, Pos p) const;

  // ----- items (checker.cpp)
  void checkFunction(int funcId);
  void checkFnBody(Block& body, Type* ret, Pos missingReturnPos);

  // ----- statements and blocks (checker.cpp)
  void checkStmt(Stmt& s);
  void checkBlockStmts(Block& b);
  Type* inferBlock(Block& b);
  void checkBlock(Block& b, Type* expected);
  void checkStmtBlock(Block& b);
  void checkAssign(Stmt& s);
  void checkReturn(Stmt& s);
  void checkLet(Stmt& s);
  void checkFor(Stmt& s);

  bool blockDiverges(Block& b);
  bool stmtDiverges(Stmt& s);
  bool exprDiverges(Expr& e);

  // ----- expressions (check_expr.cpp)
  Type* infer(Expr& e);
  void check(Expr& e, Type* expected);
  Type* typePath(Expr& e, Type* expected);
  Type* typeStructLit(Expr& e, Type* expected);
  Type* typeLambda(Expr& e, Type* expected);
  Type* typeIf(Expr& e, Type* expected);
  Type* typeMatch(Expr& e, Type* expected);
  Type* typeBinary(Expr& e);
  Type* typeUnary(Expr& e);
  Type* typeList(Expr& e, Type* expected);
  Type* typeMap(Expr& e, Type* expected);
  Type* typeTuple(Expr& e, Type* expected);
  Type* typeCall(Expr& e, Type* expected);
  Type* typeMethodCall(Expr& e, Type* expected);
  Type* typeTraitMethodCall(Expr& e, int trait, int method, Type* expected);
  Type* typeIndex(Expr& e);
  Type* typeField(Expr& e);
  Type* conform(Expr& e, Type* actual, Type* expected);

  struct CallSig {
    std::vector<TypeParam*> tparams;
    std::vector<Type*> params;
    Type* ret = nullptr;
  };
  Type* callGeneric(Expr& e, const CallSig& sig, Type* expected);

  struct ValueRes {
    enum class K { Local, Func, Variant, TraitMethod } kind = K::Local;
    LocalVar* var = nullptr;
    int id = -1;       // function id / enum decl id / trait id
    int variant = -1;  // variant index / trait method index
  };
  // Resolves a (possibly qualified) value name. `locals`: consult local bindings first.
  bool resolveValue(const std::string& qual, Pos qualPos, const std::string& name, Pos namePos, bool locals,
                    ValueRes& out, bool failOnUnknown = true);
  const ValueEntry* findValueEntry(const std::string& name);
  void bindPath(Expr& e, const ValueRes& r);
  CallSig sigOfFunc(int funcId);
  CallSig sigOfVariant(int decl, int variant);
  // Resolves a path naming a struct type (struct literals / struct patterns).
  int resolveStructDecl(const std::string& qual, Pos qualPos, const std::string& name, Pos namePos, Pos at,
                        Type** selfOut);
  std::vector<Type*> instantiate(const TypeDeclInfo& d, std::vector<Type*>& vars);

  // ----- patterns (check_pattern.cpp)
  void checkPattern(Pattern& p, Type* t, std::set<std::string>& seen);
  void checkPatternTop(Pattern& p, Type* t);
  LocalVar* declarePatternVar(const std::string& name, Pos pos, Type* t, std::set<std::string>& seen);
  bool irrefutable(const Pattern& p) const;

  // ----- exhaustiveness (exhaustive.cpp)
  void checkMatchCoverage(Expr& match, Type* scrutinee);
};

}  // namespace langvm
