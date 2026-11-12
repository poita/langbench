// The KBL tree-walking interpreter: build files in, build plan out.
#pragma once

#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

#include "kiln/ast.hpp"
#include "kiln/plan.hpp"
#include "kiln/vfs.hpp"

namespace kiln {

/// Evaluates `main.kiln` (and everything it includes) against a workspace and
/// produces the build plan. A fresh `Evaluator` is used for every build.
class Evaluator {
 public:
  explicit Evaluator(const Vfs& vfs);

  /// Runs phase 1-2 of a build. Throws `Error` on any configuration error.
  BuildPlan evaluate();

 private:
  struct Scope {
    std::unordered_map<std::string, Value> vars;
    std::shared_ptr<Scope> parent;
  };
  using ScopePtr = std::shared_ptr<Scope>;
  struct RuleDef {
    const Stmt* stmt = nullptr;
    ScopePtr scope;  // the scope in which the `rule` statement ran
  };

  Value eval(const Expr& e, const ScopePtr& scope);
  Value evalBinary(const Expr& e, const ScopePtr& scope);
  Value evalCall(const Expr& e, const ScopePtr& scope);
  Value evalIndex(const Expr& e, const ScopePtr& scope);
  std::vector<std::string> evalStrList(const Expr& e, const ScopePtr& scope, const std::string& site);

  void execBlock(const Block& block, const ScopePtr& scope);
  void exec(const Stmt& s, const ScopePtr& scope);
  void execInclude(const Stmt& s, const ScopePtr& scope);
  void execUse(const Stmt& s, const ScopePtr& scope);
  void execStep(const Stmt& s, const ScopePtr& scope);
  void execPhony(const Stmt& s, const ScopePtr& scope);
  void runFile(const std::string& path, const ScopePtr& scope);

  const Vfs& vfs_;
  BuildPlan plan_;
  std::vector<std::unique_ptr<ParsedFile>> files_;
  std::vector<std::string> includeStack_;
  std::unordered_map<std::string, RuleDef> rules_;
  std::unordered_map<std::string, std::size_t> phonyIndex_;
  int depth_ = 0;
};

}  // namespace kiln
