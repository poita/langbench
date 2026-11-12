#include "kiln/evaluator.hpp"

#include <algorithm>
#include <memory>
#include <optional>
#include <unordered_map>
#include <unordered_set>

#include "kiln/ast.hpp"
#include "kiln/builtins.hpp"
#include "kiln/error.hpp"
#include "kiln/parser.hpp"
#include "kiln/path.hpp"

namespace kiln {

namespace {

constexpr int kMaxRuleDepth = 64;

struct Scope {
  std::shared_ptr<Scope> parent;
  std::unordered_map<std::string, Value> vars;
};
using ScopePtr = std::shared_ptr<Scope>;

ScopePtr child_of(const ScopePtr& parent) {
  auto s = std::make_shared<Scope>();
  s->parent = parent;
  return s;
}

struct RuleDef {
  const Stmt* stmt;
  ScopePtr scope;
};

class Evaluator {
 public:
  explicit Evaluator(const Vfs& vfs) : vfs_(vfs) {}

  BuildDescription run() {
    if (!vfs_.exists(kRootBuildFile)) throw Error(ErrorKind::NoBuildFile, std::string(kRootBuildFile));
    auto root = std::make_shared<Scope>();
    run_file(std::string(kRootBuildFile), root);
    return std::move(out_);
  }

 private:
  // --- files and statements ------------------------------------------------

  void run_file(const std::string& path, const ScopePtr& scope) {
    Vfs::Content content = vfs_.read(path);
    std::shared_ptr<Program> program = parse_program(*content, path);
    programs_.push_back(program);
    include_stack_.push_back(path);
    exec_block(program->statements, scope);
    include_stack_.pop_back();
  }

  void exec_block(const Block& block, const ScopePtr& scope) {
    for (const auto& s : block) exec(*s, scope);
  }

  void exec(const Stmt& s, const ScopePtr& scope) {
    switch (s.kind) {
      case Stmt::Kind::Let: {
        Value v = eval(*s.expr, scope);
        if (scope->vars.count(s.name)) throw Error(ErrorKind::Redefine, s.name);
        scope->vars.emplace(s.name, std::move(v));
        break;
      }
      case Stmt::Kind::Set: {
        Value v = eval(*s.expr, scope);
        for (Scope* sc = scope.get(); sc; sc = sc->parent.get()) {
          auto it = sc->vars.find(s.name);
          if (it != sc->vars.end()) {
            it->second = std::move(v);
            return;
          }
        }
        throw Error(ErrorKind::SetUndefined, s.name);
      }
      case Stmt::Kind::Include: exec_include(s, scope); break;
      case Stmt::Kind::Abort: {
        Value v = eval(*s.expr, scope);
        if (!v.is(Type::Str)) throw_type_error("abort message", "str", v.type());
        throw Error(ErrorKind::Abort, v.as_str());
      }
      case Stmt::Kind::Default: {
        Value v = eval(*s.expr, scope);
        for (auto& t : as_strlist(v, "default")) out_.defaults.push_back(std::move(t));
        break;
      }
      case Stmt::Kind::Phony: exec_phony(s, scope); break;
      case Stmt::Kind::Use: exec_use(s, scope); break;
      case Stmt::Kind::When: {
        for (const auto& br : s.branches) {
          Value c = eval(*br.condition, scope);
          if (!c.is(Type::Bool)) throw_type_error("when condition", "bool", c.type());
          if (c.as_bool()) {
            exec_block(br.body, child_of(scope));
            return;
          }
        }
        if (s.has_otherwise) exec_block(s.otherwise, child_of(scope));
        break;
      }
      case Stmt::Kind::Each: {
        Value subject = eval(*s.expr, scope);
        if (!subject.is(Type::List)) throw_type_error("each subject", "list", subject.type());
        const auto& items = subject.as_list();
        for (std::size_t i = 0; i < items.size(); ++i) {
          ScopePtr it = child_of(scope);
          if (!s.index_name.empty()) it->vars.emplace(s.index_name, Value::integer(static_cast<std::int64_t>(i)));
          it->vars.emplace(s.name, items[i]);
          exec_block(s.body, it);
        }
        break;
      }
      case Stmt::Kind::Rule: {
        if (rules_.count(s.name)) throw Error(ErrorKind::Redefine, s.name);
        rules_.emplace(s.name, RuleDef{&s, scope});
        break;
      }
      case Stmt::Kind::Step: exec_step(s, scope); break;
    }
  }

  void exec_include(const Stmt& s, const ScopePtr& scope) {
    Value v = eval(*s.expr, scope);
    if (!v.is(Type::Str)) throw_type_error("include path", "str", v.type());
    const std::string& path = v.as_str();
    if (!is_workspace_path(path)) throw Error(ErrorKind::BadPath, path);
    if (!vfs_.exists(path)) throw Error(ErrorKind::IncludeMissing, path);
    if (std::find(include_stack_.begin(), include_stack_.end(), path) != include_stack_.end()) {
      throw Error(ErrorKind::IncludeCycle, path);
    }
    run_file(path, scope);
  }

  void exec_phony(const Stmt& s, const ScopePtr& scope) {
    Value v = eval(*s.expr, scope);
    std::vector<std::string> deps = as_strlist(v, "phony " + s.name);
    for (const auto& d : deps) {
      if (!is_reference_shape(d)) throw Error(ErrorKind::BadPath, d);
    }
    if (!phony_names_.insert(s.name).second) throw Error(ErrorKind::DupPhony, s.name);
    out_.phonies.push_back(PhonyDef{s.name, std::move(deps)});
  }

  void exec_use(const Stmt& s, const ScopePtr& scope) {
    auto it = rules_.find(s.name);
    if (it == rules_.end()) throw Error(ErrorKind::UnknownRule, s.name);
    if (rule_depth_ + 1 > kMaxRuleDepth) throw Error(ErrorKind::RuleRecursion, s.name);
    const RuleDef rule = it->second;  // copy: the table may not change, but be safe
    const auto& params = rule.stmt->params;

    std::vector<Value> pos;
    for (const auto& a : s.positional) pos.push_back(eval(*a, scope));
    std::vector<Value> kw;
    for (const auto& a : s.keywords) kw.push_back(eval(*a.value, scope));

    ScopePtr inner = child_of(rule.scope);
    if (pos.size() > params.size()) {
      throw Error(ErrorKind::Arity, "rule " + s.name + ": expected " + std::to_string(params.size()) +
                                        ", got " + std::to_string(pos.size()));
    }
    for (std::size_t i = 0; i < pos.size(); ++i) inner->vars.emplace(params[i].name, pos[i]);
    for (std::size_t i = 0; i < s.keywords.size(); ++i) {
      const std::string& name = s.keywords[i].name;
      bool known = std::any_of(params.begin(), params.end(), [&](const Param& p) { return p.name == name; });
      if (!known) throw Error(ErrorKind::Arg, "rule " + s.name + ": unknown argument " + name);
      if (inner->vars.count(name)) throw Error(ErrorKind::Arg, "rule " + s.name + ": duplicate argument " + name);
      inner->vars.emplace(name, kw[i]);
    }
    for (const auto& p : params) {
      if (inner->vars.count(p.name)) continue;
      if (!p.default_value) throw Error(ErrorKind::Arg, "rule " + s.name + ": missing argument " + p.name);
      inner->vars.emplace(p.name, eval(*p.default_value, inner));
    }
    ++rule_depth_;
    exec_block(rule.stmt->body, inner);
    --rule_depth_;
  }

  void exec_step(const Stmt& s, const ScopePtr& scope) {
    StepDef step;
    bool has_cost = false, has_depfile = false, has_cmd = false;
    std::int64_t cost = 0;
    for (const auto& f : s.fields) {
      switch (f.kind) {
        case StepField::Kind::Out: append_field(step.outputs, f, scope, "out"); break;
        case StepField::Kind::In: append_field(step.inputs, f, scope, "in"); break;
        case StepField::Kind::After: append_field(step.after, f, scope, "after"); break;
        case StepField::Kind::Cost: {
          if (has_cost) throw Error(ErrorKind::StepField, "duplicate cost");
          has_cost = true;
          Value v = eval(*f.expr, scope);
          if (!v.is(Type::Int)) throw_type_error("field cost", "int", v.type());
          if (v.as_int() < 0) throw_arg_error("field", "cost", "negative");
          cost = v.as_int();
          break;
        }
        case StepField::Kind::Depfile: {
          if (has_depfile) throw Error(ErrorKind::StepField, "duplicate depfile");
          has_depfile = true;
          Value v = eval(*f.expr, scope);
          if (!v.is(Type::Str)) throw_type_error("field depfile", "str", v.type());
          step.depfile = v.as_str();
          break;
        }
        case StepField::Kind::Cmd: {
          if (has_cmd) throw Error(ErrorKind::StepField, "duplicate cmd");
          const CommandSpec* spec = find_command(f.command);
          if (!spec) throw Error(ErrorKind::UnknownCmd, f.command);
          std::vector<Value> args;
          for (const auto& a : f.args) args.push_back(eval(*a, scope));
          if (args.size() != spec->args.size()) {
            throw Error(ErrorKind::Arity, "cmd " + std::string(spec->name) + ": expected " +
                                              std::to_string(spec->args.size()) + ", got " +
                                              std::to_string(args.size()));
          }
          for (std::size_t i = 0; i < args.size(); ++i) {
            Type want = spec->args[i] == ArgType::Str ? Type::Str : Type::Int;
            if (args[i].type() != want) {
              throw_type_error("cmd " + std::string(spec->name) + " argument " + std::to_string(i + 1),
                               type_name(want), args[i].type());
            }
          }
          has_cmd = true;
          step.command = spec;
          step.args = std::move(args);
          break;
        }
      }
    }

    // Validation at the closing brace.
    if (!has_cmd) throw Error(ErrorKind::StepField, "missing cmd");
    if (step.outputs.empty()) throw Error(ErrorKind::StepField, "missing out");
    auto check_output = [](const std::string& p) {
      if (!is_workspace_path(p)) throw Error(ErrorKind::BadPath, p);
      if (!is_generated_path(p)) throw Error(ErrorKind::OutputPath, p);
    };
    for (const auto& o : step.outputs) check_output(o);
    if (has_depfile) check_output(step.depfile);
    for (const auto& in : step.inputs) {
      if (!is_reference_shape(in)) throw Error(ErrorKind::BadPath, in);
    }
    for (const auto& a : step.after) {
      if (!is_reference_shape(a)) throw Error(ErrorKind::BadPath, a);
    }
    const CommandSpec& spec = *step.command;
    int files = static_cast<int>(step.file_inputs().size());
    if (files < spec.min_inputs || (spec.max_inputs >= 0 && files > spec.max_inputs)) {
      std::string hi = spec.max_inputs < 0 ? "N" : std::to_string(spec.max_inputs);
      throw Error(ErrorKind::CmdShape, std::string(spec.name) + ": expected inputs " +
                                           std::to_string(spec.min_inputs) + "-" + hi + ", got " +
                                           std::to_string(files));
    }
    if (step.outputs.size() != 1) {
      throw Error(ErrorKind::CmdShape, std::string(spec.name) + ": expected outputs 1, got " +
                                           std::to_string(step.outputs.size()));
    }
    if (has_depfile && !spec.depfile_required) {
      throw Error(ErrorKind::CmdShape, std::string(spec.name) + ": depfile not allowed");
    }
    if (!has_depfile && spec.depfile_required) {
      throw Error(ErrorKind::CmdShape, std::string(spec.name) + ": depfile required");
    }
    check_command_args(spec, step.args);

    step.cost = has_cost ? cost : spec.default_cost;
    step.serial = out_.steps.size();
    out_.steps.push_back(std::move(step));
  }

  void append_field(std::vector<std::string>& dest, const StepField& f, const ScopePtr& scope,
                    const char* name) {
    Value v = eval(*f.expr, scope);
    for (auto& s : as_strlist(v, std::string("field ") + name)) dest.push_back(std::move(s));
  }

  static std::vector<std::string> as_strlist(const Value& v, const std::string& site) {
    std::vector<std::string> out;
    if (v.is(Type::Str)) {
      out.push_back(v.as_str());
    } else if (v.is(Type::List)) {
      for (const Value& e : v.as_list()) {
        if (!e.is(Type::Str)) throw_type_error(site, "strlist", e.type());
        out.push_back(e.as_str());
      }
    } else {
      throw_type_error(site, "strlist", v.type());
    }
    return out;
  }

  // --- expressions ---------------------------------------------------------

  static void need(const Value& v, Type t, const std::string& site) {
    if (v.type() != t) throw_type_error(site, type_name(t), v.type());
  }

  static void append_interp(std::string& out, const Value& v) {
    switch (v.type()) {
      case Type::Str: out += v.as_str(); break;
      case Type::Int: out += std::to_string(v.as_int()); break;
      case Type::Bool: out += v.as_bool() ? "true" : "false"; break;
      case Type::List: throw Error(ErrorKind::Interp, "list");
    }
  }

  Value eval(const Expr& e, const ScopePtr& scope) {
    switch (e.kind) {
      case Expr::Kind::Literal: return e.literal;
      case Expr::Kind::Interp: {
        std::string out;
        for (const auto& p : e.parts) {
          if (p.expr) append_interp(out, eval(*p.expr, scope));
          else out += p.literal;
        }
        return Value::string(std::move(out));
      }
      case Expr::Kind::Var: {
        for (const Scope* sc = scope.get(); sc; sc = sc->parent.get()) {
          auto it = sc->vars.find(e.name);
          if (it != sc->vars.end()) return it->second;
        }
        throw Error(ErrorKind::UnknownVar, e.name);
      }
      case Expr::Kind::List: {
        Value::List items;
        items.reserve(e.args.size());
        for (const auto& a : e.args) items.push_back(eval(*a, scope));
        return Value::list(std::move(items));
      }
      case Expr::Kind::Unary: {
        Value v = eval(*e.args[0], scope);
        std::string site = std::string("operator ") + op_spelling(e.unary_op);
        if (e.unary_op == UnaryOp::Not) {
          need(v, Type::Bool, site);
          return Value::boolean(!v.as_bool());
        }
        need(v, Type::Int, site);
        return Value::integer(static_cast<std::int64_t>(0 - static_cast<std::uint64_t>(v.as_int())));
      }
      case Expr::Kind::Binary: return eval_binary(e, scope);
      case Expr::Kind::Call: {
        if (!is_builtin(e.name)) throw Error(ErrorKind::UnknownFunc, e.name);
        std::vector<Value> args;
        args.reserve(e.args.size());
        for (const auto& a : e.args) args.push_back(eval(*a, scope));
        return call_builtin(e.name, args, vfs_);
      }
      case Expr::Kind::Index: {
        Value target = eval(*e.args[0], scope);
        Value index = eval(*e.args[1], scope);
        need(index, Type::Int, "index");
        std::int64_t i = index.as_int();
        if (target.is(Type::Str)) {
          const std::string& s = target.as_str();
          std::int64_t n = static_cast<std::int64_t>(s.size());
          if (i < 0) i += n;
          if (i < 0 || i >= n) throw_arg_error("fn", "index", "out of range");
          return Value::string(std::string(1, s[static_cast<std::size_t>(i)]));
        }
        if (target.is(Type::List)) {
          const auto& l = target.as_list();
          std::int64_t n = static_cast<std::int64_t>(l.size());
          if (i < 0) i += n;
          if (i < 0 || i >= n) throw_arg_error("fn", "index", "out of range");
          return l[static_cast<std::size_t>(i)];
        }
        throw_type_error("index target", "str|list", target.type());
      }
    }
    throw Error(ErrorKind::Parse, "unreachable");
  }

  Value eval_binary(const Expr& e, const ScopePtr& scope) {
    const BinaryOp op = e.binary_op;
    const std::string site = std::string("operator ") + op_spelling(op);
    if (op == BinaryOp::Or || op == BinaryOp::And) {
      Value l = eval(*e.args[0], scope);
      need(l, Type::Bool, site);
      if (op == BinaryOp::Or && l.as_bool()) return Value::boolean(true);
      if (op == BinaryOp::And && !l.as_bool()) return Value::boolean(false);
      Value r = eval(*e.args[1], scope);
      need(r, Type::Bool, site);
      return r;
    }
    Value l = eval(*e.args[0], scope);
    Value r = eval(*e.args[1], scope);
    switch (op) {
      case BinaryOp::Eq: return Value::boolean(equal(l, r));
      case BinaryOp::Ne: return Value::boolean(!equal(l, r));
      case BinaryOp::Lt: return Value::boolean(compare(l, r) < 0);
      case BinaryOp::Le: return Value::boolean(compare(l, r) <= 0);
      case BinaryOp::Gt: return Value::boolean(compare(l, r) > 0);
      case BinaryOp::Ge: return Value::boolean(compare(l, r) >= 0);
      case BinaryOp::ListConcat: {
        need(l, Type::List, site);
        need(r, Type::List, site);
        Value::List out;
        out.reserve(l.as_list().size() + r.as_list().size());
        out.insert(out.end(), l.as_list().begin(), l.as_list().end());
        out.insert(out.end(), r.as_list().begin(), r.as_list().end());
        return Value::list(std::move(out));
      }
      case BinaryOp::StrConcat: {
        need(l, Type::Str, site);
        need(r, Type::Str, site);
        return Value::string(l.as_str() + r.as_str());
      }
      default: break;
    }
    need(l, Type::Int, site);
    need(r, Type::Int, site);
    const std::int64_t a = l.as_int(), b = r.as_int();
    const auto ua = static_cast<std::uint64_t>(a), ub = static_cast<std::uint64_t>(b);
    switch (op) {
      case BinaryOp::Add: return Value::integer(static_cast<std::int64_t>(ua + ub));
      case BinaryOp::Sub: return Value::integer(static_cast<std::int64_t>(ua - ub));
      case BinaryOp::Mul: return Value::integer(static_cast<std::int64_t>(ua * ub));
      case BinaryOp::Div:
        if (b == 0) throw Error(ErrorKind::DivZero);
        if (b == -1) return Value::integer(static_cast<std::int64_t>(0 - ua));
        return Value::integer(a / b);
      case BinaryOp::Mod:
        if (b == 0) throw Error(ErrorKind::DivZero);
        if (b == -1) return Value::integer(0);
        return Value::integer(a % b);
      default: break;
    }
    throw Error(ErrorKind::Parse, "unreachable");
  }

  const Vfs& vfs_;
  BuildDescription out_;
  std::unordered_map<std::string, RuleDef> rules_;
  std::unordered_set<std::string> phony_names_;
  std::vector<std::string> include_stack_;
  std::vector<std::shared_ptr<Program>> programs_;
  int rule_depth_ = 0;
};

}  // namespace

BuildDescription evaluate_workspace(const Vfs& vfs) { return Evaluator(vfs).run(); }

}  // namespace kiln
