#include "jinjalite/interpreter.hpp"

#include <limits>

#include "jinjalite/error.hpp"
#include "jinjalite/format.hpp"
#include "jinjalite/ops.hpp"

namespace jinjalite {
namespace {

[[noreturn]] void type_error(const char* what) { throw Error(ErrorKind::Type, what); }

/// The `range` builtin.
class RangeCallable : public Callable {
 public:
  Value call(Interpreter&, CallArgs&& args) const override {
    if (!args.keyword.empty()) type_error("range takes no keyword arguments");
    const size_t n = args.positional.size();
    if (n < 1 || n > 3) type_error("range takes one to three arguments");
    int64_t v[3];
    for (size_t i = 0; i < n; ++i) {
      const Value& a = args.positional[i];
      require_defined(a);
      if (!a.is_integral()) type_error("range arguments must be integers");
      v[i] = a.integral();
    }
    int64_t start = 0, stop, step = 1;
    if (n == 1) {
      stop = v[0];
    } else {
      start = v[0];
      stop = v[1];
      if (n == 3) step = v[2];
    }
    if (step == 0) type_error("range step must not be zero");
    List out;
    if (step > 0) {
      for (int64_t i = start; i < stop; i += step) {
        out.push_back(Value::integer(i));
        if (i > std::numeric_limits<int64_t>::max() - step) break;
      }
    } else {
      for (int64_t i = start; i > stop; i += step) {
        out.push_back(Value::integer(i));
        if (i < std::numeric_limits<int64_t>::min() - step) break;
      }
    }
    return Value::list(std::move(out));
  }
};

/// A macro value: the definition plus the scope it was defined in.
class MacroCallable : public Callable {
 public:
  MacroCallable(const MacroStmt* def, ScopePtr scope, std::shared_ptr<Rendering> rendering)
      : def_(def), scope_(std::move(scope)), rendering_(std::move(rendering)) {}

  Value call(Interpreter& interp, CallArgs&& args) const override {
    const auto& params = def_->params;
    if (args.positional.size() > params.size()) type_error("too many arguments to macro");
    auto scope = std::make_shared<Scope>(scope_);
    std::vector<bool> bound(params.size(), false);
    for (size_t i = 0; i < args.positional.size(); ++i) {
      scope->set(params[i].name, std::move(args.positional[i]));
      bound[i] = true;
    }
    for (auto& kw : args.keyword) {
      size_t idx = 0;
      while (idx < params.size() && params[idx].name != kw.first) ++idx;
      if (idx == params.size()) type_error("unknown keyword argument");
      if (bound[idx]) type_error("argument given twice");
      scope->set(params[idx].name, std::move(kw.second));
      bound[idx] = true;
    }
    for (size_t i = 0; i < params.size(); ++i) {
      if (bound[i]) continue;
      if (params[i].default_value) {
        scope->set(params[i].name, interp.eval(*params[i].default_value, scope));
      } else {
        scope->set(params[i].name, Value());
      }
    }
    std::string buffer;
    ExecContext ctx{&buffer, true, rendering_, nullptr};
    interp.exec_body(def_->body, scope, ctx);
    return Value::string(std::move(buffer));
  }

 private:
  const MacroStmt* def_;
  ScopePtr scope_;
  std::shared_ptr<Rendering> rendering_;
};

/// `super` inside a block body: renders the next less-derived body.
class SuperCallable : public Callable {
 public:
  SuperCallable(std::shared_ptr<Rendering> r, std::string name, size_t index)
      : rendering_(std::move(r)), name_(std::move(name)), index_(index) {}

  Value call(Interpreter& interp, CallArgs&& args) const override {
    if (!args.positional.empty() || !args.keyword.empty()) type_error("super takes no arguments");
    const auto& chain = rendering_->chains.at(name_);
    if (index_ + 1 >= chain.size()) throw Error(ErrorKind::Undefined, "no super block");
    std::string buffer;
    interp.render_block(rendering_, name_, index_ + 1, buffer);
    return Value::string(std::move(buffer));
  }

 private:
  std::shared_ptr<Rendering> rendering_;
  std::string name_;
  size_t index_;
};

}  // namespace

Interpreter::Interpreter(DictPtr context, TemplateLoader loader)
    : context_(std::move(context)),
      loader_(std::move(loader)),
      range_(Value::callable(std::make_shared<RangeCallable>())) {}

std::string Interpreter::render(const Template& main) {
  auto rendering = std::make_shared<Rendering>();
  rendering->scope = std::make_shared<Scope>(std::make_shared<Scope>(context_));
  register_blocks(*rendering, main);
  std::string out;
  run_template(main, rendering, out);
  return out;
}

void Interpreter::register_blocks(Rendering& r, const Template& t) {
  for (const BlockStmt* b : t.blocks) r.chains[b->name].push_back(b);
}

void Interpreter::run_template(const Template& t, const std::shared_ptr<Rendering>& rendering, std::string& out) {
  // `rendering` already holds this template's blocks (or, for a parent
  // template, they were appended by the `extends` tag that loaded it).
  ExecContext ctx{&out, true, rendering, nullptr};
  exec_body(t.body, rendering->scope, ctx);
  if (ctx.pending_parent) run_template(*ctx.pending_parent, rendering, out);
}

void Interpreter::render_block(const std::shared_ptr<Rendering>& rendering, const std::string& name, size_t index,
                               std::string& out) {
  const BlockStmt* block = rendering->chains.at(name)[index];
  auto scope = std::make_shared<Scope>(rendering->scope);
  scope->set("super", Value::callable(std::make_shared<SuperCallable>(rendering, name, index)));
  ExecContext ctx{&out, true, rendering, nullptr};
  exec_body(block->body, scope, ctx);
}

// ---- statements -------------------------------------------------------------

void Interpreter::exec_body(const Body& body, const ScopePtr& scope, ExecContext& ctx) {
  for (const StmtPtr& s : body) exec(*s, scope, ctx);
}

void Interpreter::exec(const Stmt& s, const ScopePtr& scope, ExecContext& ctx) {
  switch (s.kind) {
    case StmtKind::Text:
      if (ctx.emit) ctx.out->append(static_cast<const TextStmt&>(s).text);
      break;
    case StmtKind::Print: {
      if (!ctx.emit) break;
      Value v = eval(*static_cast<const PrintStmt&>(s).expr, scope);
      append_display(*ctx.out, v);
      break;
    }
    case StmtKind::If: {
      const auto& st = static_cast<const IfStmt&>(s);
      for (const auto& branch : st.branches) {
        if (is_truthy(eval(*branch.first, scope))) {
          exec_body(branch.second, scope, ctx);
          return;
        }
      }
      exec_body(st.else_body, scope, ctx);
      break;
    }
    case StmtKind::For: exec_for(static_cast<const ForStmt&>(s), scope, ctx); break;
    case StmtKind::Set: {
      const auto& st = static_cast<const SetStmt&>(s);
      scope->set(st.name, eval(*st.value, scope));
      break;
    }
    case StmtKind::Macro: {
      const auto& st = static_cast<const MacroStmt&>(s);
      scope->set(st.name, Value::callable(std::make_shared<MacroCallable>(&st, scope, ctx.rendering)));
      break;
    }
    case StmtKind::Include:
      if (ctx.emit) exec_include(static_cast<const IncludeStmt&>(s), scope, ctx);
      break;
    case StmtKind::Extends: exec_extends(static_cast<const ExtendsStmt&>(s), scope, ctx); break;
    case StmtKind::Block: {
      if (!ctx.emit) break;
      const auto& st = static_cast<const BlockStmt&>(s);
      render_block(ctx.rendering, st.name, 0, *ctx.out);
      break;
    }
  }
}

void Interpreter::exec_for(const ForStmt& s, const ScopePtr& scope, ExecContext& ctx) {
  Value iterable = eval(*s.iterable, scope);
  ListPtr seq = sequence_view(iterable);
  if (seq->empty()) {
    exec_body(s.else_body, scope, ctx);
    return;
  }
  const int64_t length = static_cast<int64_t>(seq->size());
  for (int64_t i = 0; i < length; ++i) {
    auto iter_scope = std::make_shared<Scope>(scope);
    iter_scope->set(s.var, (*seq)[static_cast<size_t>(i)]);
    auto loop = std::make_shared<Dict>();
    loop->set("index", Value::integer(i + 1));
    loop->set("index0", Value::integer(i));
    loop->set("first", Value::boolean(i == 0));
    loop->set("last", Value::boolean(i == length - 1));
    loop->set("length", Value::integer(length));
    iter_scope->set("loop", Value::dict(std::move(loop)));
    exec_body(s.body, iter_scope, ctx);
  }
}

const Template& Interpreter::load_named(const Value& v) {
  require_defined(v);
  if (!v.is_string()) type_error("template name must be a string");
  return loader_(v.as_string());
}

void Interpreter::exec_include(const IncludeStmt& s, const ScopePtr& scope, ExecContext& ctx) {
  const Template& t = load_named(eval(*s.name, scope));
  auto rendering = std::make_shared<Rendering>();
  rendering->scope = std::make_shared<Scope>(scope);
  register_blocks(*rendering, t);
  run_template(t, rendering, *ctx.out);
}

void Interpreter::exec_extends(const ExtendsStmt& s, const ScopePtr& scope, ExecContext& ctx) {
  const Template& parent = load_named(eval(*s.name, scope));
  register_blocks(*ctx.rendering, parent);
  ctx.pending_parent = &parent;
  ctx.emit = false;
}

// ---- expressions ------------------------------------------------------------

Value Interpreter::eval(const Expr& e, const ScopePtr& scope) {
  switch (e.kind) {
    case ExprKind::Literal: return static_cast<const LiteralExpr&>(e).value;
    case ExprKind::Name: return eval_name(static_cast<const NameExpr&>(e), scope);
    case ExprKind::List: {
      const auto& le = static_cast<const ListExpr&>(e);
      List items;
      items.reserve(le.items.size());
      for (const ExprPtr& item : le.items) items.push_back(eval(*item, scope));
      return Value::list(std::move(items));
    }
    case ExprKind::Negate: return negate(eval(*static_cast<const UnaryExpr&>(e).operand, scope));
    case ExprKind::Not: return Value::boolean(!is_truthy(eval(*static_cast<const UnaryExpr&>(e).operand, scope)));
    case ExprKind::And: {
      const auto& le = static_cast<const LogicalExpr&>(e);
      Value l = eval(*le.lhs, scope);
      if (!is_truthy(l)) return l;
      return eval(*le.rhs, scope);
    }
    case ExprKind::Or: {
      const auto& le = static_cast<const LogicalExpr&>(e);
      Value l = eval(*le.lhs, scope);
      if (is_truthy(l)) return l;
      return eval(*le.rhs, scope);
    }
    case ExprKind::Binary: {
      const auto& be = static_cast<const BinaryExpr&>(e);
      Value l = eval(*be.lhs, scope);
      Value r = eval(*be.rhs, scope);
      return binary_op(be.op, l, r);
    }
    case ExprKind::Compare: return eval_compare(static_cast<const CompareExpr&>(e), scope);
    case ExprKind::Filter: return eval_filter(static_cast<const FilterExpr&>(e), scope);
    case ExprKind::IsDefined: {
      const auto& de = static_cast<const IsDefinedExpr&>(e);
      bool defined = !eval(*de.operand, scope).is_undefined();
      return Value::boolean(de.negated ? !defined : defined);
    }
    case ExprKind::Get: {
      const auto& ge = static_cast<const GetExpr&>(e);
      Value obj = eval(*ge.object, scope);
      Value key = eval(*ge.key, scope);
      return get_item(obj, key);
    }
    case ExprKind::Call: return eval_call(static_cast<const CallExpr&>(e), scope);
  }
  return Value();
}

Value Interpreter::eval_name(const NameExpr& e, const ScopePtr& scope) {
  if (const Value* v = scope->find(e.name)) return *v;
  if (e.name == "range") return range_;
  return Value();
}

Value Interpreter::eval_compare(const CompareExpr& e, const ScopePtr& scope) {
  Value lhs = eval(*e.first, scope);
  for (const auto& step : e.rest) {
    Value rhs = eval(*step.second, scope);
    if (!compare(step.first, lhs, rhs)) return Value::boolean(false);
    lhs = std::move(rhs);
  }
  return Value::boolean(true);
}

Value Interpreter::eval_filter(const FilterExpr& e, const ScopePtr& scope) {
  Value input = eval(*e.input, scope);
  std::vector<Value> args;
  args.reserve(e.args.size());
  for (const ExprPtr& a : e.args) args.push_back(eval(*a, scope));
  const FilterInfo& f = *e.filter;
  if (!f.accepts_undefined) require_defined(input);
  if (args.size() < f.min_args || args.size() > f.max_args) type_error("wrong number of filter arguments");
  return f.apply(input, args);
}

Value Interpreter::eval_call(const CallExpr& e, const ScopePtr& scope) {
  Value callee = eval(*e.callee, scope);
  CallArgs args;
  args.positional.reserve(e.args.size());
  for (const ExprPtr& a : e.args) args.positional.push_back(eval(*a, scope));
  for (const auto& kw : e.kwargs) args.keyword.emplace_back(kw.first, eval(*kw.second, scope));
  require_defined(callee);
  if (!callee.is_callable()) type_error("value is not callable");
  return callee.as_callable().call(*this, std::move(args));
}

}  // namespace jinjalite
