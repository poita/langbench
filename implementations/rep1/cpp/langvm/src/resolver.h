// Pass 3: declarations, imports, signatures and impls (SPEC.md sections 5, 8, 13.2).
#pragma once

#include <string>
#include <vector>

#include "langvm/diagnostic.h"
#include "model.h"
#include "source.h"

namespace langvm {

// Names visible while resolving written types.
struct TypeScope {
  int module = -1;
  std::vector<TypeParam*> params;
  Type* self = nullptr;  // meaning of `Self`; null => self-outside
};

class Resolver {
 public:
  explicit Resolver(Model& m) : m_(m) {}

  // Parses and declares the prelude (Option, Result, the built-ins).
  void loadPrelude();
  // Runs passes 3.1-3.6 over the parsed user modules.
  void resolve(std::vector<ModuleSource>& sources, std::vector<ModuleAst>& asts);

  // --- services shared with the checker
  Type* resolveType(const TypeExpr& te, const TypeScope& sc);
  // Resolves a trait reference; throws unknown-trait / not-public / unknown-module.
  int resolveTraitRef(const TraitRef& r, int module);
  // Does `t` satisfy the built-in `Key` (map keys, SPEC 7.3)?
  bool satisfiesKey(Type* t) const;

 private:
  Model& m_;

  void declareModule(int mi);
  void declareItems(int mi);
  void internalDups(int mi);
  void signatures(int mi);
  void implChecks(int mi);

  std::vector<TypeParam*> makeParams(const std::vector<GenParam>& gps);
  void resolveBounds(const std::vector<GenParam>& gps, const std::vector<TypeParam*>& ps, int module);
  void checkImpl(int mi, ImplDecl& im);
  [[noreturn]] void err(ErrorKind k, Pos p) const;
};

}  // namespace langvm
