#pragma once
/// \file interpreter.hpp
/// Tree-walking interpreter over parsed templates.

#include <functional>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

#include "jinjalite/ast.hpp"
#include "jinjalite/scope.hpp"
#include "jinjalite/value.hpp"

namespace jinjalite {

/// Per-rendering inheritance state: for every block name the chain of bodies
/// from most to least derived, plus the template scope of the rendering.
struct Rendering {
  std::unordered_map<std::string, std::vector<const BlockStmt*>> chains;
  ScopePtr scope;
};

/// Output sink and flags for executing one body.
struct ExecContext {
  std::string* out;
  /// False after an `extends` tag has run: the template's own output is
  /// suppressed (blocks, text and prints produce nothing).
  bool emit = true;
  std::shared_ptr<Rendering> rendering;
  /// Parent template set by an executed `extends` tag.
  const Template* pending_parent = nullptr;
};

/// Resolves a template name to a loaded template; throws `Error` if the
/// template is missing or broken.
using TemplateLoader = std::function<const Template&(const std::string&)>;

/// Executes templates against a context. One interpreter performs one render.
class Interpreter {
 public:
  Interpreter(DictPtr context, TemplateLoader loader);

  /// Renders `main` as the top-level template and returns its output.
  std::string render(const Template& main);

  // The following are used by callables (macros, super) and are public for
  // that reason only.
  Value eval(const Expr& e, const ScopePtr& scope);
  void exec_body(const Body& body, const ScopePtr& scope, ExecContext& ctx);
  /// Renders entry `index` of the chain of block `name` into `out`.
  void render_block(const std::shared_ptr<Rendering>& rendering, const std::string& name, size_t index,
                    std::string& out);

 private:
  void exec(const Stmt& s, const ScopePtr& scope, ExecContext& ctx);
  void exec_for(const ForStmt& s, const ScopePtr& scope, ExecContext& ctx);
  void exec_include(const IncludeStmt& s, const ScopePtr& scope, ExecContext& ctx);
  void exec_extends(const ExtendsStmt& s, const ScopePtr& scope, ExecContext& ctx);
  const Template& load_named(const Value& name_value);
  void run_template(const Template& t, const std::shared_ptr<Rendering>& rendering, std::string& out);
  static void register_blocks(Rendering& r, const Template& t);

  Value eval_name(const NameExpr& e, const ScopePtr& scope);
  Value eval_compare(const CompareExpr& e, const ScopePtr& scope);
  Value eval_filter(const FilterExpr& e, const ScopePtr& scope);
  Value eval_call(const CallExpr& e, const ScopePtr& scope);

  DictPtr context_;
  TemplateLoader loader_;
  Value range_;
};

}  // namespace jinjalite
