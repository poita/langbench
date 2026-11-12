#include "interpreter.hpp"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <limits>

#include "sitegen/template.hpp"
#include "sitegen/text.hpp"

namespace sitegen::tmpl {

namespace {

[[noreturn]] void fail(TemplateErrorKind kind, const std::string& message) {
  throw TemplateError(kind, message);
}
[[noreturn]] void undefined_error(const std::string& what) {
  fail(TemplateErrorKind::Undefined, "undefined value used: " + what);
}
[[noreturn]] void type_error(const std::string& what) { fail(TemplateErrorKind::Type, what); }

struct Scope;
using ScopePtr = std::shared_ptr<Scope>;

/// A mapping from interned names to values plus a parent scope.
struct Scope {
  explicit Scope(ScopePtr p = nullptr) : parent(std::move(p)) {}
  ScopePtr parent;
  std::vector<std::pair<int, Value>> vars;

  void bind(int sym, Value v) {
    for (auto& kv : vars) {
      if (kv.first == sym) {
        kv.second = std::move(v);
        return;
      }
    }
    vars.emplace_back(sym, std::move(v));
  }
};

/// State of one template rendering (the main template or one `include`).
struct RenderCtx {
  ScopePtr tscope;
  std::unordered_map<std::string, std::vector<const Stmt*>> chains;
};

using Kwargs = std::vector<std::pair<std::string, Value>>;

struct MacroCallable;

}  // namespace

struct Interpreter::Impl {
  Impl(TemplateLoader& l, SymbolTable& s);

  // --- Entry points -------------------------------------------------------
  std::string render(const Template& main, const Dict& context);

  // --- Execution ----------------------------------------------------------
  void run_template(const Template& t, RenderCtx& ctx, std::string& out);
  void exec_body(const Body& body, const ScopePtr& sc, RenderCtx& ctx, std::string& out);
  void exec_stmt(const Stmt& s, const ScopePtr& sc, RenderCtx& ctx, std::string& out, bool suppress);
  void exec_for(const Stmt& s, const ScopePtr& sc, RenderCtx& ctx, std::string& out);
  void render_block(RenderCtx& ctx, const std::string& name, std::size_t index, std::string& out);
  void init_chains(const Template& t, RenderCtx& ctx);
  std::string load_name(const Expr& e, const ScopePtr& sc);

  // --- Expressions --------------------------------------------------------
  Value eval(const Expr& e, const ScopePtr& sc);
  Value eval_call(const Expr& e, const ScopePtr& sc);
  Value eval_filter(const Expr& e, const ScopePtr& sc);
  const Value* lookup(const ScopePtr& sc, int sym) const;
  Value binary(BinOp op, const Value& a, const Value& b);
  bool compare(CmpOp op, const Value& a, const Value& b);
  Value apply_filter(FilterId id, const Value& input, std::vector<Value>& extra);
  Value call_macro(const MacroCallable& m, std::vector<Value>& pos, Kwargs& kw);

  static bool truthy(const Value& v);

  TemplateLoader& loader;
  SymbolTable& symbols;
  int range_sym;
  int loop_sym;
  int super_sym;
  Value range_value;
};

namespace {

// ---------------------------------------------------------------------------
// Callables
// ---------------------------------------------------------------------------

struct CallableImpl : Callable {
  virtual Value invoke(Interpreter::Impl& in, std::vector<Value>& pos, Kwargs& kw) const = 0;
};

struct MacroCallable : CallableImpl {
  const Stmt* def = nullptr;
  std::weak_ptr<Scope> scope;
  RenderCtx* ctx = nullptr;
  Value invoke(Interpreter::Impl& in, std::vector<Value>& pos, Kwargs& kw) const override {
    return in.call_macro(*this, pos, kw);
  }
};

struct RangeCallable : CallableImpl {
  Value invoke(Interpreter::Impl&, std::vector<Value>& pos, Kwargs& kw) const override {
    if (!kw.empty()) type_error("range() takes no keyword arguments");
    if (pos.empty() || pos.size() > 3) type_error("range() takes 1 to 3 arguments");
    std::int64_t nums[3] = {0, 0, 1};
    for (std::size_t i = 0; i < pos.size(); ++i) {
      const Value& v = pos[i];
      if (v.is_undefined()) undefined_error("range argument");
      if (!v.is_int() && !v.is_bool()) type_error("range() arguments must be integers");
      nums[i] = v.is_bool() ? (v.as_bool() ? 1 : 0) : v.as_int();
    }
    std::int64_t start = 0, stop, step = 1;
    if (pos.size() == 1) {
      stop = nums[0];
    } else {
      start = nums[0];
      stop = nums[1];
      if (pos.size() == 3) step = nums[2];
    }
    if (step == 0) type_error("range() step must not be zero");
    List items;
    if (step > 0) {
      for (std::int64_t i = start; i < stop; i += step) items.push_back(Value::integer(i));
    } else {
      for (std::int64_t i = start; i > stop; i += step) items.push_back(Value::integer(i));
    }
    return Value::list(std::move(items));
  }
};

struct SuperCallable : CallableImpl {
  RenderCtx* ctx = nullptr;
  std::string name;
  std::size_t index = 0;
  Value invoke(Interpreter::Impl& in, std::vector<Value>& pos, Kwargs& kw) const override {
    if (!pos.empty() || !kw.empty()) type_error("super() takes no arguments");
    std::string out;
    in.render_block(*ctx, name, index + 1, out);
    return Value::string(std::move(out));
  }
};

// ---------------------------------------------------------------------------
// Value helpers
// ---------------------------------------------------------------------------

std::int64_t int_of(const Value& v) { return v.is_bool() ? (v.as_bool() ? 1 : 0) : v.as_int(); }

/// A sequence view of a value (see "Sequence view" in the language reference).
class Seq {
 public:
  explicit Seq(const Value& v) {
    switch (v.kind()) {
      case Value::Kind::Undefined: undefined_error("iterating an undefined value");
      case Value::Kind::List:
        holder_ = v;
        list_ = &holder_.as_list();
        break;
      case Value::Kind::Dict:
        for (const auto& e : v.as_dict().entries()) owned_.push_back(Value::string(e.first));
        break;
      case Value::Kind::String: {
        const std::string& s = v.as_string();
        for (std::size_t i = 0; i < s.size();) {
          const std::size_t len = std::min(text::utf8_sequence_length(static_cast<unsigned char>(s[i])), s.size() - i);
          owned_.push_back(Value::string(s.substr(i, len)));
          i += len;
        }
        break;
      }
      default: type_error("value is not a sequence");
    }
  }
  Seq(const Seq&) = delete;
  Seq& operator=(const Seq&) = delete;
  const List& items() const { return list_ != nullptr ? *list_ : owned_; }

 private:
  Value holder_;
  const List* list_ = nullptr;
  List owned_;
};

bool less_than(const Value& a, const Value& b) {
  if (a.is_number() && b.is_number()) {
    if (a.is_float() || b.is_float()) return a.number_as_double() < b.number_as_double();
    return int_of(a) < int_of(b);
  }
  if (a.is_string() && b.is_string()) return a.as_string() < b.as_string();
  type_error("values cannot be ordered");
}

std::string to_str(const Value& v) {
  if (v.is_undefined()) undefined_error("printing an undefined value");
  return to_display_string(v);
}

double float_floor_div(double x, double y, double* mod_out) {
  double mod = std::fmod(x, y);
  double div = (x - mod) / y;
  if (mod != 0.0 && ((y < 0) != (mod < 0))) {
    mod += y;
    div -= 1.0;
  }
  double floordiv;
  if (div != 0.0) {
    floordiv = std::floor(div);
    if (div - floordiv > 0.5) floordiv += 1.0;
  } else {
    floordiv = std::copysign(0.0, x / y);
  }
  if (mod_out != nullptr) *mod_out = mod;
  return floordiv;
}

std::int64_t wrap_add(std::int64_t a, std::int64_t b) {
  return static_cast<std::int64_t>(static_cast<std::uint64_t>(a) + static_cast<std::uint64_t>(b));
}
std::int64_t wrap_sub(std::int64_t a, std::int64_t b) {
  return static_cast<std::int64_t>(static_cast<std::uint64_t>(a) - static_cast<std::uint64_t>(b));
}
std::int64_t wrap_mul(std::int64_t a, std::int64_t b) {
  return static_cast<std::int64_t>(static_cast<std::uint64_t>(a) * static_cast<std::uint64_t>(b));
}

std::int64_t truncate_to_int(double d) {
  if (std::isnan(d)) return 0;
  if (d >= 9.2233720368547758e18) return std::numeric_limits<std::int64_t>::max();
  if (d <= -9.2233720368547758e18) return std::numeric_limits<std::int64_t>::min();
  return static_cast<std::int64_t>(d);
}

std::int64_t int_from_string(const std::string& raw) {
  std::size_t b = 0, e = raw.size();
  while (b < e && text::is_template_space(raw[b])) ++b;
  while (e > b && text::is_template_space(raw[e - 1])) --e;
  const std::string s = raw.substr(b, e - b);
  if (s.empty()) return 0;
  std::size_t i = 0;
  if (s[i] == '+' || s[i] == '-') ++i;
  const std::size_t digits_start = i;
  while (i < s.size() && s[i] >= '0' && s[i] <= '9') ++i;
  if (i == s.size() && i > digits_start) {
    // Plain integer.
    const bool neg = s[0] == '-';
    std::uint64_t v = 0;
    for (std::size_t k = digits_start; k < s.size(); ++k) v = v * 10 + static_cast<unsigned>(s[k] - '0');
    return neg ? static_cast<std::int64_t>(0ULL - v) : static_cast<std::int64_t>(v);
  }
  // Decimal: [+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?
  std::size_t j = digits_start;
  std::size_t int_digits = 0, frac_digits = 0;
  while (j < s.size() && s[j] >= '0' && s[j] <= '9') { ++j; ++int_digits; }
  if (j < s.size() && s[j] == '.') {
    ++j;
    while (j < s.size() && s[j] >= '0' && s[j] <= '9') { ++j; ++frac_digits; }
  }
  if (int_digits == 0 && frac_digits == 0) return 0;
  if (j < s.size() && (s[j] == 'e' || s[j] == 'E')) {
    std::size_t k = j + 1;
    if (k < s.size() && (s[k] == '+' || s[k] == '-')) ++k;
    const std::size_t exp_start = k;
    while (k < s.size() && s[k] >= '0' && s[k] <= '9') ++k;
    if (k == exp_start) return 0;
    j = k;
  }
  if (j != s.size()) return 0;
  return truncate_to_int(std::strtod(s.c_str(), nullptr));
}

std::string escape_markup(const std::string& s) {
  std::string out;
  out.reserve(s.size());
  for (const char c : s) {
    switch (c) {
      case '&': out += "&amp;"; break;
      case '<': out += "&lt;"; break;
      case '>': out += "&gt;"; break;
      case '"': out += "&#34;"; break;
      case '\'': out += "&#39;"; break;
      default: out.push_back(c);
    }
  }
  return out;
}

std::string replace_all(const std::string& s, const std::string& from, const std::string& to) {
  std::string out;
  if (from.empty()) {
    // Python semantics: insert `to` between every character and at both ends.
    out += to;
    for (std::size_t i = 0; i < s.size();) {
      const std::size_t len = std::min(text::utf8_sequence_length(static_cast<unsigned char>(s[i])), s.size() - i);
      out.append(s, i, len);
      out += to;
      i += len;
    }
    return out;
  }
  std::size_t pos = 0;
  while (true) {
    const std::size_t hit = s.find(from, pos);
    if (hit == std::string::npos) {
      out.append(s, pos, std::string::npos);
      return out;
    }
    out.append(s, pos, hit - pos);
    out += to;
    pos = hit + from.size();
  }
}

std::string reverse_string(const std::string& s) {
  std::vector<std::string_view> chars;
  for (std::size_t i = 0; i < s.size();) {
    const std::size_t len = std::min(text::utf8_sequence_length(static_cast<unsigned char>(s[i])), s.size() - i);
    chars.emplace_back(s.data() + i, len);
    i += len;
  }
  std::string out;
  out.reserve(s.size());
  for (auto it = chars.rbegin(); it != chars.rend(); ++it) out.append(*it);
  return out;
}

}  // namespace

// ---------------------------------------------------------------------------
// Interpreter::Impl
// ---------------------------------------------------------------------------

Interpreter::Impl::Impl(TemplateLoader& l, SymbolTable& s) : loader(l), symbols(s) {
  range_sym = symbols.intern("range");
  loop_sym = symbols.intern("loop");
  super_sym = symbols.intern("super");
  range_value = Value::callable(std::make_shared<RangeCallable>());
}

bool Interpreter::Impl::truthy(const Value& v) {
  switch (v.kind()) {
    case Value::Kind::Undefined: undefined_error("testing an undefined value");
    case Value::Kind::None: return false;
    case Value::Kind::Bool: return v.as_bool();
    case Value::Kind::Int: return v.as_int() != 0;
    case Value::Kind::Float: return v.as_float() != 0.0;
    case Value::Kind::String: return !v.as_string().empty();
    case Value::Kind::List: return !v.as_list().empty();
    case Value::Kind::Dict: return !v.as_dict().empty();
    case Value::Kind::Callable: return true;
  }
  return false;
}

const Value* Interpreter::Impl::lookup(const ScopePtr& sc, int sym) const {
  for (const Scope* s = sc.get(); s != nullptr; s = s->parent.get()) {
    for (const auto& kv : s->vars) {
      if (kv.first == sym) return &kv.second;
    }
  }
  if (sym == range_sym) return &range_value;
  return nullptr;
}

void Interpreter::Impl::init_chains(const Template& t, RenderCtx& ctx) {
  for (const std::string& name : t.block_order) ctx.chains[name].push_back(t.blocks.at(name));
}

std::string Interpreter::Impl::render(const Template& main, const Dict& context) {
  auto root = std::make_shared<Scope>();
  for (const auto& [key, value] : context.entries()) root->bind(symbols.intern(key), value);
  RenderCtx ctx;
  ctx.tscope = std::make_shared<Scope>(root);
  init_chains(main, ctx);
  std::string out;
  run_template(main, ctx, out);
  return out;
}

std::string Interpreter::Impl::load_name(const Expr& e, const ScopePtr& sc) {
  const Value v = eval(e, sc);
  if (v.is_undefined()) undefined_error("template name");
  if (!v.is_string()) type_error("template name must be a string");
  return v.as_string();
}

void Interpreter::Impl::run_template(const Template& t, RenderCtx& ctx, std::string& out) {
  const Template* cur = &t;
  while (cur != nullptr) {
    const Template* parent = nullptr;
    bool suppress = false;
    for (const StmtPtr& s : cur->body) {
      if (s->kind == StmtKind::Extends) {
        const std::string name = load_name(*s->expr, ctx.tscope);
        parent = loader.load(name);
        for (const std::string& bname : parent->block_order) {
          ctx.chains[bname].push_back(parent->blocks.at(bname));
        }
        suppress = true;
        continue;
      }
      exec_stmt(*s, ctx.tscope, ctx, out, suppress);
    }
    cur = parent;
  }
}

void Interpreter::Impl::exec_body(const Body& body, const ScopePtr& sc, RenderCtx& ctx,
                                  std::string& out) {
  for (const StmtPtr& s : body) exec_stmt(*s, sc, ctx, out, false);
}

void Interpreter::Impl::render_block(RenderCtx& ctx, const std::string& name, std::size_t index,
                                     std::string& out) {
  const auto it = ctx.chains.find(name);
  if (it == ctx.chains.end() || index >= it->second.size()) {
    undefined_error("super() without a less derived block");
  }
  auto scope = std::make_shared<Scope>(ctx.tscope);
  auto sup = std::make_shared<SuperCallable>();
  sup->ctx = &ctx;
  sup->name = name;
  sup->index = index;
  scope->bind(super_sym, Value::callable(std::move(sup)));
  exec_body(it->second[index]->body, scope, ctx, out);
}

void Interpreter::Impl::exec_for(const Stmt& s, const ScopePtr& sc, RenderCtx& ctx, std::string& out) {
  const Value iterable = eval(*s.expr, sc);
  const Seq seq(iterable);
  const List& items = seq.items();
  if (items.empty()) {
    exec_body(s.else_body, sc, ctx, out);
    return;
  }
  const std::int64_t n = static_cast<std::int64_t>(items.size());
  for (std::int64_t i = 0; i < n; ++i) {
    auto inner = std::make_shared<Scope>(sc);
    inner->bind(s.sym, items[static_cast<std::size_t>(i)]);
    Dict loop;
    loop.set("index", Value::integer(i + 1));
    loop.set("index0", Value::integer(i));
    loop.set("first", Value::boolean(i == 0));
    loop.set("last", Value::boolean(i == n - 1));
    loop.set("length", Value::integer(n));
    inner->bind(loop_sym, Value::dict(std::move(loop)));
    exec_body(s.body, inner, ctx, out);
  }
}

void Interpreter::Impl::exec_stmt(const Stmt& s, const ScopePtr& sc, RenderCtx& ctx, std::string& out,
                                  bool suppress) {
  switch (s.kind) {
    case StmtKind::Set:
      sc->bind(s.sym, eval(*s.expr, sc));
      return;
    case StmtKind::Macro: {
      auto m = std::make_shared<MacroCallable>();
      m->def = &s;
      m->scope = sc;
      m->ctx = &ctx;
      sc->bind(s.sym, Value::callable(std::move(m)));
      return;
    }
    default:
      break;
  }
  if (suppress) return;
  switch (s.kind) {
    case StmtKind::Text:
      out += s.text;
      break;
    case StmtKind::Print:
      out += to_str(eval(*s.expr, sc));
      break;
    case StmtKind::If:
      for (const Branch& b : s.branches) {
        if (truthy(eval(*b.condition, sc))) {
          exec_body(b.body, sc, ctx, out);
          return;
        }
      }
      exec_body(s.else_body, sc, ctx, out);
      break;
    case StmtKind::For:
      exec_for(s, sc, ctx, out);
      break;
    case StmtKind::Include: {
      const std::string name = load_name(*s.expr, sc);
      const Template* t = loader.load(name);
      RenderCtx sub;
      sub.tscope = std::make_shared<Scope>(sc);
      init_chains(*t, sub);
      run_template(*t, sub, out);
      break;
    }
    case StmtKind::Block:
      render_block(ctx, s.text, 0, out);
      break;
    case StmtKind::Extends:  // handled by run_template
    case StmtKind::Set:
    case StmtKind::Macro:
      break;
  }
}

Value Interpreter::Impl::call_macro(const MacroCallable& m, std::vector<Value>& pos, Kwargs& kw) {
  const ScopePtr defining = m.scope.lock();
  if (!defining) undefined_error("macro outlived its scope");
  const Stmt& def = *m.def;
  auto scope = std::make_shared<Scope>(defining);
  const std::size_t np = def.params.size();
  if (pos.size() > np) type_error("too many arguments for macro '" + def.text + "'");
  std::vector<char> bound(np, 0);
  for (std::size_t i = 0; i < pos.size(); ++i) {
    scope->bind(def.params[i].sym, pos[i]);
    bound[i] = 1;
  }
  for (auto& [name, value] : kw) {
    std::size_t k = 0;
    while (k < np && def.params[k].name != name) ++k;
    if (k == np) type_error("unknown keyword argument '" + name + "'");
    if (bound[k]) type_error("argument '" + name + "' given twice");
    scope->bind(def.params[k].sym, std::move(value));
    bound[k] = 1;
  }
  for (std::size_t i = 0; i < np; ++i) {
    if (bound[i]) continue;
    const Param& p = def.params[i];
    scope->bind(p.sym, p.default_value ? eval(*p.default_value, scope) : Value::undefined());
  }
  std::string buffer;
  exec_body(def.body, scope, *m.ctx, buffer);
  return Value::string(std::move(buffer));
}

// ---------------------------------------------------------------------------
// Expressions
// ---------------------------------------------------------------------------

Value Interpreter::Impl::eval(const Expr& e, const ScopePtr& sc) {
  switch (e.kind) {
    case ExprKind::Literal:
      return e.literal;
    case ExprKind::Name: {
      const Value* v = lookup(sc, e.sym);
      return v != nullptr ? *v : Value::undefined();
    }
    case ExprKind::List: {
      List items;
      items.reserve(e.args.size());
      for (const ExprPtr& a : e.args) items.push_back(eval(*a, sc));
      return Value::list(std::move(items));
    }
    case ExprKind::Attr: {
      const Value obj = eval(*e.args[0], sc);
      if (obj.is_undefined()) undefined_error("attribute '" + e.name + "' of an undefined value");
      if (obj.is_dict()) {
        const Value* v = obj.as_dict().find(e.name);
        return v != nullptr ? *v : Value::undefined();
      }
      return Value::undefined();
    }
    case ExprKind::Index: {
      const Value obj = eval(*e.args[0], sc);
      const Value key = eval(*e.args[1], sc);
      if (obj.is_undefined() || key.is_undefined()) undefined_error("subscript");
      if (obj.is_dict() && key.is_string()) {
        const Value* v = obj.as_dict().find(key.as_string());
        return v != nullptr ? *v : Value::undefined();
      }
      if ((key.is_int() || key.is_bool()) && (obj.is_list() || obj.is_string())) {
        std::int64_t i = int_of(key);
        if (obj.is_list()) {
          const List& l = obj.as_list();
          const std::int64_t n = static_cast<std::int64_t>(l.size());
          if (i < 0) i += n;
          if (i < 0 || i >= n) return Value::undefined();
          return l[static_cast<std::size_t>(i)];
        }
        const std::string& s = obj.as_string();
        if (i < 0) i += static_cast<std::int64_t>(text::utf8_length(s));
        if (i < 0) return Value::undefined();
        std::size_t pos = 0;
        for (std::int64_t k = 0; k < i && pos < s.size(); ++k) {
          pos += std::min(text::utf8_sequence_length(static_cast<unsigned char>(s[pos])), s.size() - pos);
        }
        if (pos >= s.size()) return Value::undefined();
        return Value::string(s.substr(pos, std::min(text::utf8_sequence_length(static_cast<unsigned char>(s[pos])), s.size() - pos)));
      }
      return Value::undefined();
    }
    case ExprKind::Call:
      return eval_call(e, sc);
    case ExprKind::Neg: {
      const Value v = eval(*e.args[0], sc);
      if (v.is_undefined()) undefined_error("negation");
      if (v.is_float()) return Value::real(-v.as_float());
      if (v.is_int() || v.is_bool()) return Value::integer(wrap_sub(0, int_of(v)));
      type_error("cannot negate this value");
    }
    case ExprKind::Not:
      return Value::boolean(!truthy(eval(*e.args[0], sc)));
    case ExprKind::And: {
      Value l = eval(*e.args[0], sc);
      if (!truthy(l)) return l;
      return eval(*e.args[1], sc);
    }
    case ExprKind::Or: {
      Value l = eval(*e.args[0], sc);
      if (truthy(l)) return l;
      return eval(*e.args[1], sc);
    }
    case ExprKind::Binary: {
      const Value a = eval(*e.args[0], sc);
      const Value b = eval(*e.args[1], sc);
      return binary(e.bop, a, b);
    }
    case ExprKind::Compare: {
      Value left = eval(*e.args[0], sc);
      for (std::size_t i = 0; i < e.cmp_ops.size(); ++i) {
        Value right = eval(*e.args[i + 1], sc);
        if (!compare(e.cmp_ops[i], left, right)) return Value::boolean(false);
        left = std::move(right);
      }
      return Value::boolean(true);
    }
    case ExprKind::Filter:
      return eval_filter(e, sc);
    case ExprKind::IsDefined: {
      const Value v = eval(*e.args[0], sc);
      return Value::boolean(v.is_undefined() == e.negate);
    }
  }
  return Value::undefined();
}

Value Interpreter::Impl::eval_call(const Expr& e, const ScopePtr& sc) {
  const Value callee = eval(*e.args[0], sc);
  std::vector<Value> pos;
  pos.reserve(e.args.size());
  for (std::size_t i = 1; i < e.args.size(); ++i) pos.push_back(eval(*e.args[i], sc));
  Kwargs kw;
  for (const auto& [name, expr] : e.kwargs) kw.emplace_back(name, eval(*expr, sc));
  if (callee.is_undefined()) undefined_error("calling an undefined value");
  if (!callee.is_callable()) type_error("value is not callable");
  return static_cast<const CallableImpl&>(callee.as_callable()).invoke(*this, pos, kw);
}

Value Interpreter::Impl::eval_filter(const Expr& e, const ScopePtr& sc) {
  const Value input = eval(*e.args[0], sc);
  std::vector<Value> extra;
  extra.reserve(e.args.size() - 1);
  for (std::size_t i = 1; i < e.args.size(); ++i) extra.push_back(eval(*e.args[i], sc));
  if (e.filter != FilterId::Default) {
    if (input.is_undefined()) undefined_error("filter input");
  }
  return apply_filter(e.filter, input, extra);
}

bool Interpreter::Impl::compare(CmpOp op, const Value& a, const Value& b) {
  if (a.is_undefined() || b.is_undefined()) undefined_error("comparison");
  switch (op) {
    case CmpOp::Eq: return values_equal(a, b);
    case CmpOp::Ne: return !values_equal(a, b);
    case CmpOp::Lt: return less_than(a, b);
    case CmpOp::Gt: return less_than(b, a);
    case CmpOp::Le: return !less_than(b, a);
    case CmpOp::Ge: return !less_than(a, b);
    case CmpOp::In:
    case CmpOp::NotIn: {
      bool found = false;
      if (b.is_string()) {
        if (!a.is_string()) type_error("'in <string>' requires a string on the left");
        found = b.as_string().find(a.as_string()) != std::string::npos;
      } else if (b.is_dict()) {
        found = a.is_string() && b.as_dict().find(a.as_string()) != nullptr;
      } else if (b.is_list()) {
        for (const Value& item : b.as_list()) {
          if (values_equal(item, a)) {
            found = true;
            break;
          }
        }
      } else {
        type_error("'in' requires a string, list or dict on the right");
      }
      return op == CmpOp::In ? found : !found;
    }
  }
  return false;
}

Value Interpreter::Impl::binary(BinOp op, const Value& a, const Value& b) {
  if (a.is_undefined() || b.is_undefined()) undefined_error("operand");
  const bool nums = a.is_number() && b.is_number();
  const bool any_float = a.is_float() || b.is_float();
  switch (op) {
    case BinOp::Add:
      if (nums) {
        if (any_float) return Value::real(a.number_as_double() + b.number_as_double());
        return Value::integer(wrap_add(int_of(a), int_of(b)));
      }
      if (a.is_string() && b.is_string()) return Value::string(a.as_string() + b.as_string());
      if (a.is_list() && b.is_list()) {
        List l = a.as_list();
        l.insert(l.end(), b.as_list().begin(), b.as_list().end());
        return Value::list(std::move(l));
      }
      type_error("unsupported operands for +");
    case BinOp::Sub:
      if (!nums) type_error("unsupported operands for -");
      if (any_float) return Value::real(a.number_as_double() - b.number_as_double());
      return Value::integer(wrap_sub(int_of(a), int_of(b)));
    case BinOp::Mul: {
      if (nums) {
        if (any_float) return Value::real(a.number_as_double() * b.number_as_double());
        return Value::integer(wrap_mul(int_of(a), int_of(b)));
      }
      const Value* str = a.is_string() ? &a : (b.is_string() ? &b : nullptr);
      const Value* cnt = str == &a ? &b : &a;
      if (str != nullptr && (cnt->is_int() || cnt->is_bool())) {
        const std::int64_t n = int_of(*cnt);
        std::string out;
        if (n > 0) {
          out.reserve(str->as_string().size() * static_cast<std::size_t>(n));
          for (std::int64_t i = 0; i < n; ++i) out += str->as_string();
        }
        return Value::string(std::move(out));
      }
      type_error("unsupported operands for *");
    }
    case BinOp::Div:
      if (!nums) type_error("unsupported operands for /");
      if (b.number_as_double() == 0.0) type_error("division by zero");
      return Value::real(a.number_as_double() / b.number_as_double());
    case BinOp::FloorDiv: {
      if (!nums) type_error("unsupported operands for //");
      if (any_float) {
        const double y = b.number_as_double();
        if (y == 0.0) type_error("division by zero");
        return Value::real(float_floor_div(a.number_as_double(), y, nullptr));
      }
      const std::int64_t x = int_of(a), y = int_of(b);
      if (y == 0) type_error("division by zero");
      if (y == -1) return Value::integer(wrap_sub(0, x));
      std::int64_t q = x / y;
      if ((x % y != 0) && ((x < 0) != (y < 0))) --q;
      return Value::integer(q);
    }
    case BinOp::Mod: {
      if (!nums) type_error("unsupported operands for %");
      if (any_float) {
        const double y = b.number_as_double();
        if (y == 0.0) type_error("modulo by zero");
        double mod;
        float_floor_div(a.number_as_double(), y, &mod);
        return Value::real(mod);
      }
      const std::int64_t x = int_of(a), y = int_of(b);
      if (y == 0) type_error("modulo by zero");
      if (y == -1) return Value::integer(0);
      std::int64_t r = x % y;
      if (r != 0 && ((r < 0) != (y < 0))) r += y;
      return Value::integer(r);
    }
    case BinOp::Pow: {
      if (!nums) type_error("unsupported operands for **");
      if (!any_float) {
        const std::int64_t base = int_of(a), exp = int_of(b);
        if (exp >= 0) {
          std::int64_t result = 1, cur = base;
          std::int64_t e = exp;
          while (e > 0) {
            if (e & 1) result = wrap_mul(result, cur);
            cur = wrap_mul(cur, cur);
            e >>= 1;
          }
          return Value::integer(result);
        }
        if (base == 0) type_error("0 cannot be raised to a negative power");
        return Value::real(std::pow(static_cast<double>(base), static_cast<double>(exp)));
      }
      const double x = a.number_as_double(), y = b.number_as_double();
      if (x == 0.0 && y < 0.0) type_error("0 cannot be raised to a negative power");
      return Value::real(std::pow(x, y));
    }
    case BinOp::Concat:
      return Value::string(to_str(a) + to_str(b));
  }
  return Value::undefined();
}

Value Interpreter::Impl::apply_filter(FilterId id, const Value& input, std::vector<Value>& extra) {
  auto arity = [&](std::size_t lo, std::size_t hi) {
    if (extra.size() < lo || extra.size() > hi) type_error("wrong number of filter arguments");
    for (const Value& v : extra) {
      if (v.is_undefined() && id != FilterId::Default) undefined_error("filter argument");
    }
  };
  switch (id) {
    case FilterId::Default:
      arity(0, 1);
      if (input.is_undefined()) return extra.empty() ? Value::string("") : extra[0];
      return input;
    case FilterId::Upper:
      arity(0, 0);
      return Value::string(text::ascii_upper(to_str(input)));
    case FilterId::Lower:
      arity(0, 0);
      return Value::string(text::ascii_lower(to_str(input)));
    case FilterId::Trim: {
      arity(0, 0);
      const std::string s = to_str(input);
      std::size_t b = 0, e = s.size();
      while (b < e && text::is_template_space(s[b])) ++b;
      while (e > b && text::is_template_space(s[e - 1])) --e;
      return Value::string(s.substr(b, e - b));
    }
    case FilterId::Escape:
      arity(0, 0);
      return Value::string(escape_markup(to_str(input)));
    case FilterId::Replace:
      arity(2, 2);
      return Value::string(replace_all(to_str(input), to_str(extra[0]), to_str(extra[1])));
    case FilterId::Length:
      arity(0, 0);
      if (input.is_string()) return Value::integer(static_cast<std::int64_t>(text::utf8_length(input.as_string())));
      if (input.is_list()) return Value::integer(static_cast<std::int64_t>(input.as_list().size()));
      if (input.is_dict()) return Value::integer(static_cast<std::int64_t>(input.as_dict().size()));
      type_error("length of a value without a length");
    case FilterId::Int:
      arity(0, 0);
      switch (input.kind()) {
        case Value::Kind::Int: return input;
        case Value::Kind::Bool: return Value::integer(input.as_bool() ? 1 : 0);
        case Value::Kind::Float: return Value::integer(truncate_to_int(input.as_float()));
        case Value::Kind::String: return Value::integer(int_from_string(input.as_string()));
        default: return Value::integer(0);
      }
    case FilterId::Join: {
      arity(0, 1);
      const std::string sep = extra.empty() ? std::string() : to_str(extra[0]);
      const Seq seq(input);
      std::string out;
      bool first = true;
      for (const Value& item : seq.items()) {
        if (!first) out += sep;
        first = false;
        out += to_str(item);
      }
      return Value::string(std::move(out));
    }
    case FilterId::First:
    case FilterId::Last: {
      arity(0, 0);
      const Seq seq(input);
      const List& items = seq.items();
      if (items.empty()) return Value::undefined();
      return id == FilterId::First ? items.front() : items.back();
    }
    case FilterId::Reverse: {
      arity(0, 0);
      if (input.is_string()) return Value::string(reverse_string(input.as_string()));
      const Seq seq(input);
      List out(seq.items().rbegin(), seq.items().rend());
      return Value::list(std::move(out));
    }
    case FilterId::Sort: {
      arity(0, 0);
      const Seq seq(input);
      List items = seq.items();
      bool all_numbers = true, all_strings = true;
      for (const Value& v : items) {
        if (!v.is_number()) all_numbers = false;
        if (!v.is_string()) all_strings = false;
      }
      if (all_numbers) {
        std::stable_sort(items.begin(), items.end(),
                         [](const Value& a, const Value& b) { return less_than(a, b); });
      } else if (all_strings) {
        std::vector<std::pair<std::string, std::size_t>> keys;
        keys.reserve(items.size());
        for (std::size_t i = 0; i < items.size(); ++i) {
          keys.emplace_back(text::ascii_lower(items[i].as_string()), i);
        }
        std::stable_sort(keys.begin(), keys.end(),
                         [](const auto& a, const auto& b) { return a.first < b.first; });
        List sorted;
        sorted.reserve(items.size());
        for (const auto& k : keys) sorted.push_back(items[k.second]);
        items = std::move(sorted);
      } else if (!items.empty()) {
        type_error("cannot sort a mix of value kinds");
      }
      return Value::list(std::move(items));
    }
  }
  return Value::undefined();
}

// ---------------------------------------------------------------------------
// Public wrapper
// ---------------------------------------------------------------------------

Interpreter::Interpreter(TemplateLoader& loader, SymbolTable& symbols)
    : impl_(std::make_unique<Impl>(loader, symbols)) {}
Interpreter::~Interpreter() = default;

std::string Interpreter::render(const Template& main, const Dict& context) {
  return impl_->render(main, context);
}

}  // namespace sitegen::tmpl
