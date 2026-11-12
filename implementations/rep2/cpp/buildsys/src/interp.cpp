#include "kiln/interp.hpp"

#include "kiln/builtins.hpp"
#include "kiln/commands.hpp"
#include "kiln/error.hpp"
#include "kiln/parser.hpp"
#include "kiln/path.hpp"

namespace kiln {

namespace {

constexpr int kMaxRuleDepth = 64;

void requireType(const Value& v, unsigned mask, const std::string& site) {
  if (!(maskOf(v.type()) & mask)) throw typeError(site, maskName(mask), typeName(v.type()));
}

std::int64_t wrap(std::uint64_t u) { return static_cast<std::int64_t>(u); }

// Converts a `str` or list-of-`str` value, raising the `strlist` type error.
std::vector<std::string> toStrList(const Value& v, const std::string& site) {
  std::vector<std::string> out;
  if (v.isStr()) {
    out.push_back(v.asStr());
  } else if (v.isList()) {
    for (const auto& e : v.asList()) {
      if (!e.isStr()) throw typeError(site, "strlist", typeName(e.type()));
      out.push_back(e.asStr());
    }
  } else {
    throw typeError(site, "strlist", typeName(v.type()));
  }
  return out;
}

// A path-or-phony reference as accepted by `in`, `after` and phony lists.
void checkReference(const std::string& s) {
  if (!s.empty() && s[0] == '@') {
    if (!isPhonyRef(s)) throw Error("E_BAD_PATH", s);
  } else if (!isWorkspacePath(s)) {
    throw Error("E_BAD_PATH", s);
  }
}

}  // namespace

Evaluator::Evaluator(const Vfs& vfs) : vfs_(vfs) {}

BuildPlan Evaluator::evaluate() {
  if (!vfs_.exists("main.kiln")) throw Error("E_NO_BUILD_FILE", "main.kiln");
  auto root = std::make_shared<Scope>();
  includeStack_.push_back("main.kiln");
  runFile("main.kiln", root);
  includeStack_.pop_back();
  return std::move(plan_);
}

void Evaluator::runFile(const std::string& path, const ScopePtr& scope) {
  Content src = vfs_.read(path);
  files_.push_back(parseBuildFile(*src, path));
  const ParsedFile* file = files_.back().get();
  execBlock(file->statements, scope);
}

// ---- expressions ------------------------------------------------------------

Value Evaluator::eval(const Expr& e, const ScopePtr& scope) {
  switch (e.kind) {
    case ExprKind::Const:
      return e.value;
    case ExprKind::Interp: {
      std::string out;
      for (const auto& part : e.parts) {
        if (!part.expr) {
          out += part.literal;
          continue;
        }
        Value v = eval(*part.expr, scope);
        if (v.isList()) throw Error("E_INTERP", "list");
        if (v.isStr()) out += v.asStr();
        else out += toText(v);
      }
      return Value::string(std::move(out));
    }
    case ExprKind::Var: {
      for (const Scope* s = scope.get(); s; s = s->parent.get()) {
        auto it = s->vars.find(e.name);
        if (it != s->vars.end()) return it->second;
      }
      throw Error("E_UNKNOWN_VAR", e.name);
    }
    case ExprKind::List: {
      Value::List items;
      items.reserve(e.kids.size());
      for (const auto& k : e.kids) items.push_back(eval(*k, scope));
      return Value::list(std::move(items));
    }
    case ExprKind::Call:
      return evalCall(e, scope);
    case ExprKind::Index:
      return evalIndex(e, scope);
    case ExprKind::Unary: {
      Value v = eval(*e.kids[0], scope);
      if (e.op == Op::Not) {
        requireType(v, kBool, "operator !");
        return Value::boolean(!v.asBool());
      }
      requireType(v, kInt, "operator -");
      return Value::integer(wrap(0 - static_cast<std::uint64_t>(v.asInt())));
    }
    case ExprKind::Binary:
      return evalBinary(e, scope);
  }
  throw Error("E_INTERNAL", "bad expression");
}

Value Evaluator::evalBinary(const Expr& e, const ScopePtr& scope) {
  const Op op = e.op;
  const std::string site = std::string("operator ") + opSpelling(op);
  if (op == Op::Or || op == Op::And) {
    Value l = eval(*e.kids[0], scope);
    requireType(l, kBool, site);
    if (op == Op::Or && l.asBool()) return l;
    if (op == Op::And && !l.asBool()) return l;
    Value r = eval(*e.kids[1], scope);
    requireType(r, kBool, site);
    return r;
  }
  Value l = eval(*e.kids[0], scope);
  Value r = eval(*e.kids[1], scope);
  switch (op) {
    case Op::Eq: return Value::boolean(equal(l, r));
    case Op::Ne: return Value::boolean(!equal(l, r));
    case Op::Lt: return Value::boolean(compare(l, r) < 0);
    case Op::Le: return Value::boolean(compare(l, r) <= 0);
    case Op::Gt: return Value::boolean(compare(l, r) > 0);
    case Op::Ge: return Value::boolean(compare(l, r) >= 0);
    case Op::Concat: {
      requireType(l, kList, site);
      requireType(r, kList, site);
      Value::List out;
      out.reserve(l.asList().size() + r.asList().size());
      out.insert(out.end(), l.asList().begin(), l.asList().end());
      out.insert(out.end(), r.asList().begin(), r.asList().end());
      return Value::list(std::move(out));
    }
    case Op::Tilde: {
      requireType(l, kStr, site);
      requireType(r, kStr, site);
      std::string out;
      out.reserve(l.asStr().size() + r.asStr().size());
      out += l.asStr();
      out += r.asStr();
      return Value::string(std::move(out));
    }
    default: break;
  }
  requireType(l, kInt, site);
  requireType(r, kInt, site);
  std::int64_t a = l.asInt(), b = r.asInt();
  std::uint64_t ua = static_cast<std::uint64_t>(a), ub = static_cast<std::uint64_t>(b);
  switch (op) {
    case Op::Add: return Value::integer(wrap(ua + ub));
    case Op::Sub: return Value::integer(wrap(ua - ub));
    case Op::Mul: return Value::integer(wrap(ua * ub));
    case Op::Div:
      if (b == 0) throw Error("E_DIV_ZERO");
      if (b == -1) return Value::integer(wrap(0 - ua));
      return Value::integer(a / b);
    case Op::Mod:
      if (b == 0) throw Error("E_DIV_ZERO");
      if (b == -1) return Value::integer(0);
      return Value::integer(a % b);
    default: break;
  }
  throw Error("E_INTERNAL", "bad operator");
}

Value Evaluator::evalCall(const Expr& e, const ScopePtr& scope) {
  const Builtin* fn = findBuiltin(e.name);
  if (!fn) throw Error("E_UNKNOWN_FUNC", e.name);
  std::vector<Value> args;
  args.reserve(e.kids.size());
  for (const auto& k : e.kids) args.push_back(eval(*k, scope));
  return callBuiltin(*fn, args, vfs_);
}

Value Evaluator::evalIndex(const Expr& e, const ScopePtr& scope) {
  Value target = eval(*e.kids[0], scope);
  Value index = eval(*e.kids[1], scope);
  requireType(index, kInt, "index");
  requireType(target, kStr | kList, "index target");
  std::int64_t i = index.asInt();
  std::int64_t n = target.isStr() ? static_cast<std::int64_t>(target.asStr().size())
                                  : static_cast<std::int64_t>(target.asList().size());
  if (i < -n || i >= n) throw argError("fn", "index", "out of range");
  if (i < 0) i += n;
  if (target.isStr()) return Value::string(std::string(1, target.asStr()[static_cast<std::size_t>(i)]));
  return target.asList()[static_cast<std::size_t>(i)];
}

std::vector<std::string> Evaluator::evalStrList(const Expr& e, const ScopePtr& scope,
                                                const std::string& site) {
  return toStrList(eval(e, scope), site);
}

// ---- statements -------------------------------------------------------------

void Evaluator::execBlock(const Block& block, const ScopePtr& scope) {
  for (const auto& s : block) exec(*s, scope);
}

void Evaluator::exec(const Stmt& s, const ScopePtr& scope) {
  switch (s.kind) {
    case Stmt::Let: {
      Value v = eval(*s.expr, scope);
      if (scope->vars.count(s.name)) throw Error("E_REDEFINE", s.name);
      scope->vars.emplace(s.name, std::move(v));
      break;
    }
    case Stmt::Set: {
      Value v = eval(*s.expr, scope);
      for (Scope* sc = scope.get(); sc; sc = sc->parent.get()) {
        auto it = sc->vars.find(s.name);
        if (it != sc->vars.end()) {
          it->second = std::move(v);
          return;
        }
      }
      throw Error("E_SET_UNDEFINED", s.name);
    }
    case Stmt::Include:
      execInclude(s, scope);
      break;
    case Stmt::Abort: {
      Value v = eval(*s.expr, scope);
      requireType(v, kStr, "abort message");
      throw Error("E_ABORT", v.asStr());
    }
    case Stmt::Default: {
      auto names = evalStrList(*s.expr, scope, "default");
      for (auto& n : names) plan_.defaults.push_back(std::move(n));
      break;
    }
    case Stmt::Phony:
      execPhony(s, scope);
      break;
    case Stmt::Use:
      execUse(s, scope);
      break;
    case Stmt::When: {
      for (const auto& br : s.branches) {
        if (br.cond) {
          Value c = eval(*br.cond, scope);
          requireType(c, kBool, "when condition");
          if (!c.asBool()) continue;
        }
        auto child = std::make_shared<Scope>();
        child->parent = scope;
        execBlock(br.body, child);
        break;
      }
      break;
    }
    case Stmt::Each: {
      Value subject = eval(*s.expr, scope);
      requireType(subject, kList, "each subject");
      const auto& items = subject.asList();
      for (std::size_t i = 0; i < items.size(); ++i) {
        auto child = std::make_shared<Scope>();
        child->parent = scope;
        child->vars.emplace(s.name, items[i]);
        if (!s.indexName.empty()) child->vars.emplace(s.indexName, Value::integer(static_cast<std::int64_t>(i)));
        execBlock(s.body, child);
      }
      break;
    }
    case Stmt::Rule: {
      if (rules_.count(s.name)) throw Error("E_REDEFINE", s.name);
      rules_.emplace(s.name, RuleDef{&s, scope});
      break;
    }
    case Stmt::Step:
      execStep(s, scope);
      break;
  }
}

void Evaluator::execInclude(const Stmt& s, const ScopePtr& scope) {
  Value v = eval(*s.expr, scope);
  requireType(v, kStr, "include path");
  const std::string& path = v.asStr();
  if (!isWorkspacePath(path)) throw Error("E_BAD_PATH", path);
  if (!vfs_.exists(path)) throw Error("E_INCLUDE_MISSING", path);
  for (const auto& p : includeStack_)
    if (p == path) throw Error("E_INCLUDE_CYCLE", path);
  includeStack_.push_back(path);
  runFile(path, scope);
  includeStack_.pop_back();
}

void Evaluator::execPhony(const Stmt& s, const ScopePtr& scope) {
  auto deps = evalStrList(*s.expr, scope, "phony " + s.name);
  for (const auto& d : deps) checkReference(d);
  if (phonyIndex_.count(s.name)) throw Error("E_DUP_PHONY", s.name);
  phonyIndex_.emplace(s.name, plan_.phonies.size());
  plan_.phonies.push_back(PhonyDecl{s.name, std::move(deps)});
}

void Evaluator::execUse(const Stmt& s, const ScopePtr& scope) {
  auto it = rules_.find(s.name);
  if (it == rules_.end()) throw Error("E_UNKNOWN_RULE", s.name);
  if (depth_ + 1 > kMaxRuleDepth) throw Error("E_RULE_RECURSION", s.name);
  const RuleDef def = it->second;  // copy: the table may not change, but be safe
  const Stmt& rule = *def.stmt;

  std::vector<Value> values;
  values.reserve(s.args.size());
  for (const auto& a : s.args) values.push_back(eval(*a.expr, scope));

  auto child = std::make_shared<Scope>();
  child->parent = def.scope;
  const auto& params = rule.params;
  std::vector<bool> bound(params.size(), false);

  std::size_t positional = 0;
  for (const auto& a : s.args)
    if (a.keyword.empty()) ++positional;
  if (positional > params.size())
    throw Error("E_ARITY", "rule " + s.name + ": expected " + std::to_string(params.size()) +
                               ", got " + std::to_string(positional));
  std::size_t pi = 0;
  for (std::size_t i = 0; i < s.args.size(); ++i) {
    if (!s.args[i].keyword.empty()) continue;
    child->vars.emplace(params[pi].name, values[i]);
    bound[pi++] = true;
  }
  for (std::size_t i = 0; i < s.args.size(); ++i) {
    const std::string& kw = s.args[i].keyword;
    if (kw.empty()) continue;
    std::size_t k = 0;
    while (k < params.size() && params[k].name != kw) ++k;
    if (k == params.size()) throw argError("rule", s.name, "unknown argument " + kw);
    if (bound[k]) throw argError("rule", s.name, "duplicate argument " + kw);
    child->vars.emplace(kw, values[i]);
    bound[k] = true;
  }
  for (std::size_t k = 0; k < params.size(); ++k) {
    if (bound[k]) continue;
    if (!params[k].defaultValue) throw argError("rule", s.name, "missing argument " + params[k].name);
    child->vars.emplace(params[k].name, eval(*params[k].defaultValue, child));
  }

  ++depth_;
  execBlock(rule.body, child);
  --depth_;
}

void Evaluator::execStep(const Stmt& s, const ScopePtr& scope) {
  Step step;
  std::optional<std::int64_t> cost;
  bool haveCmd = false;

  for (const auto& f : s.fields) {
    switch (f.kind) {
      case StepField::Out:
        for (auto& p : evalStrList(*f.expr, scope, "field out")) step.outputs.push_back(std::move(p));
        break;
      case StepField::In:
        for (auto& p : evalStrList(*f.expr, scope, "field in")) step.inputs.push_back(std::move(p));
        break;
      case StepField::After:
        for (auto& p : evalStrList(*f.expr, scope, "field after")) step.after.push_back(std::move(p));
        break;
      case StepField::Cost: {
        if (cost) throw Error("E_STEP_FIELD", "duplicate cost");
        Value v = eval(*f.expr, scope);
        requireType(v, kInt, "field cost");
        if (v.asInt() < 0) throw argError("field", "cost", "negative");
        cost = v.asInt();
        break;
      }
      case StepField::Depfile: {
        if (step.depfile) throw Error("E_STEP_FIELD", "duplicate depfile");
        Value v = eval(*f.expr, scope);
        requireType(v, kStr, "field depfile");
        step.depfile = v.asStr();
        break;
      }
      case StepField::Cmd: {
        if (haveCmd) throw Error("E_STEP_FIELD", "duplicate cmd");
        const CommandInfo* info = findCommand(f.cmdName);
        if (!info) throw Error("E_UNKNOWN_CMD", f.cmdName);
        std::vector<Value> args;
        for (const auto& a : f.cmdArgs) args.push_back(eval(*a, scope));
        if (args.size() != info->args.size())
          throw Error("E_ARITY", "cmd " + f.cmdName + ": expected " +
                                     std::to_string(info->args.size()) + ", got " +
                                     std::to_string(args.size()));
        for (std::size_t i = 0; i < args.size(); ++i)
          requireType(args[i], info->args[i] == ArgType::Str ? kStr : kInt,
                      "cmd " + f.cmdName + " argument " + std::to_string(i + 1));
        step.info = info;
        step.call = CommandCall{f.cmdName, std::move(args)};
        haveCmd = true;
        break;
      }
    }
  }

  // Validation at the closing brace.
  if (!haveCmd) throw Error("E_STEP_FIELD", "missing cmd");
  if (step.outputs.empty()) throw Error("E_STEP_FIELD", "missing out");
  auto checkOutput = [](const std::string& p) {
    if (!isWorkspacePath(p)) throw Error("E_BAD_PATH", p);
    if (!isGeneratedPath(p)) throw Error("E_OUTPUT_PATH", p);
  };
  for (const auto& p : step.outputs) checkOutput(p);
  if (step.depfile) checkOutput(*step.depfile);
  for (const auto& p : step.inputs) checkReference(p);
  for (const auto& p : step.after) checkReference(p);

  const CommandInfo& info = *step.info;
  std::int64_t fileInputs = 0;
  for (const auto& p : step.inputs)
    if (p.empty() || p[0] != '@') ++fileInputs;
  if (fileInputs < info.minInputs || (info.maxInputs >= 0 && fileInputs > info.maxInputs)) {
    std::string hi = info.maxInputs < 0 ? "N" : std::to_string(info.maxInputs);
    throw Error("E_CMD_SHAPE", step.call.name + ": expected inputs " +
                                   std::to_string(info.minInputs) + "-" + hi + ", got " +
                                   std::to_string(fileInputs));
  }
  if (step.outputs.size() != 1)
    throw Error("E_CMD_SHAPE", step.call.name + ": expected outputs 1, got " +
                                   std::to_string(step.outputs.size()));
  if (info.usesDepfile && !step.depfile)
    throw Error("E_CMD_SHAPE", step.call.name + ": depfile required");
  if (!info.usesDepfile && step.depfile)
    throw Error("E_CMD_SHAPE", step.call.name + ": depfile not allowed");
  if (step.call.name == "replace" && step.call.args[0].asStr().empty())
    throw argError("cmd", "replace", "empty pattern");
  if (step.call.name == "indent" && step.call.args[0].asInt() < 0)
    throw argError("cmd", "indent", "negative");

  step.serial = static_cast<int>(plan_.steps.size());
  step.cost = cost ? *cost : info.defaultCost;
  step.canonical = canonicalCommand(step.call);
  plan_.steps.push_back(std::move(step));
}

}  // namespace kiln
