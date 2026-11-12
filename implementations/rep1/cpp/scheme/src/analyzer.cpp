#include "scheme/analyzer.hpp"

#include "scheme/errors.hpp"

namespace scheme {

namespace {

[[noreturn]] void syntax(const char* msg) { throw SchemeError(ErrorKind::SyntaxError, msg); }

Symbol* as_symbol(const Value& v) {
  if (!v.is_symbol()) syntax("expected a symbol");
  return v.as<Symbol>();
}

std::vector<Value> to_vector(const Value& list) {
  std::vector<Value> out;
  if (!list_to_vector(list, out)) syntax("expected a proper list");
  return out;
}

}  // namespace

Analyzer::Analyzer(SymbolTable& s)
    : s_quote_(s.intern("quote")), s_if_(s.intern("if")), s_define_(s.intern("define")),
      s_set_(s.intern("set!")), s_lambda_(s.intern("lambda")), s_let_(s.intern("let")),
      s_letstar_(s.intern("let*")), s_letrec_(s.intern("letrec")), s_begin_(s.intern("begin")),
      s_cond_(s.intern("cond")), s_and_(s.intern("and")), s_or_(s.intern("or")),
      s_else_(s.intern("else")) {}

const Node* Analyzer::analyze(const Value& d) {
  if (d.is_symbol()) return make<VarNode>(d.as<Symbol>());
  if (d.is_pair()) return analyze_pair(d);
  if (d.is_null()) syntax("empty application");
  return make<ConstNode>(d);  // integers, booleans, strings
}

const Node* Analyzer::analyze_body(const std::vector<Value>& forms, size_t from) {
  if (from >= forms.size()) syntax("empty body");
  if (forms.size() - from == 1) return analyze(forms[from]);
  auto* seq = make<SeqNode>();
  for (size_t i = from; i < forms.size(); ++i) seq->forms.push_back(analyze(forms[i]));
  return seq;
}

const LambdaNode* Analyzer::analyze_lambda(const Value& params, const std::vector<Value>& forms,
                                           size_t body_from) {
  auto* lam = make<LambdaNode>();
  const Value* cur = &params;
  while (cur->is_pair()) {
    lam->params.push_back(as_symbol(cur->as<Pair>()->car));
    cur = &cur->as<Pair>()->cdr;
  }
  if (cur->is_symbol())
    lam->rest = cur->as<Symbol>();
  else if (!cur->is_null())
    syntax("bad parameter list");
  lam->body = analyze_body(forms, body_from);
  return lam;
}

void Analyzer::parse_bindings(const Value& list, std::vector<Symbol*>& names,
                              std::vector<const Node*>& inits) {
  for (const Value& b : to_vector(list)) {
    std::vector<Value> parts = to_vector(b);
    if (parts.size() != 2) syntax("bad binding");
    names.push_back(as_symbol(parts[0]));
    inits.push_back(analyze(parts[1]));
  }
}

const Node* Analyzer::analyze_let(const std::vector<Value>& f) {
  if (f.size() < 3) syntax("bad let");
  if (f[1].is_symbol()) {  // named let
    if (f.size() < 4) syntax("bad named let");
    auto* nl = make<NamedLetNode>();
    nl->name = f[1].as<Symbol>();
    auto* lam = make<LambdaNode>();
    parse_bindings(f[2], lam->params, nl->inits);
    lam->body = analyze_body(f, 3);
    nl->lambda = lam;
    return nl;
  }
  auto* let = make<LetNode>();
  parse_bindings(f[1], let->names, let->inits);
  let->body = analyze_body(f, 2);
  return let;
}

const Node* Analyzer::analyze_let_star(const std::vector<Value>& f) {
  if (f.size() < 3) syntax("bad let*");
  std::vector<Value> bindings = to_vector(f[1]);
  if (bindings.empty()) {
    auto* let = make<LetNode>();
    let->body = analyze_body(f, 2);
    return let;
  }
  // Build the nest from the outside in: each let's body is the next let.
  LetNode* outer = nullptr;
  LetNode* inner = nullptr;
  for (const Value& b : bindings) {
    std::vector<Value> parts = to_vector(b);
    if (parts.size() != 2) syntax("bad binding");
    auto* let = make<LetNode>();
    let->names.push_back(as_symbol(parts[0]));
    let->inits.push_back(analyze(parts[1]));
    if (inner)
      inner->body = let;
    else
      outer = let;
    inner = let;
  }
  inner->body = analyze_body(f, 2);
  return outer;
}

const Node* Analyzer::analyze_letrec(const std::vector<Value>& f) {
  if (f.size() < 3) syntax("bad letrec");
  auto* lr = make<LetrecNode>();
  parse_bindings(f[1], lr->names, lr->inits);
  lr->body = analyze_body(f, 2);
  return lr;
}

const Node* Analyzer::analyze_cond(const std::vector<Value>& f) {
  auto* c = make<CondNode>();
  for (size_t i = 1; i < f.size(); ++i) {
    std::vector<Value> parts = to_vector(f[i]);
    if (parts.empty()) syntax("bad cond clause");
    CondClause cl{nullptr, nullptr};
    if (parts[0].is_symbol() && parts[0].as<Symbol>() == s_else_) {
      cl.body = analyze_body(parts, 1);
    } else {
      cl.test = analyze(parts[0]);
      if (parts.size() > 1) cl.body = analyze_body(parts, 1);
    }
    c->clauses.push_back(cl);
  }
  return c;
}

const Node* Analyzer::analyze_define(const std::vector<Value>& f) {
  if (f.size() < 3) syntax("bad define");
  if (f[1].is_pair()) {
    Symbol* name = as_symbol(f[1].as<Pair>()->car);
    return make<DefineNode>(name, analyze_lambda(f[1].as<Pair>()->cdr, f, 2));
  }
  if (f.size() != 3) syntax("bad define");
  return make<DefineNode>(as_symbol(f[1]), analyze(f[2]));
}

const Node* Analyzer::analyze_pair(const Value& d) {
  std::vector<Value> f = to_vector(d);
  if (f[0].is_symbol()) {
    Symbol* head = f[0].as<Symbol>();
    if (head == s_quote_) {
      if (f.size() != 2) syntax("bad quote");
      return make<ConstNode>(f[1]);
    }
    if (head == s_if_) {
      if (f.size() != 3 && f.size() != 4) syntax("bad if");
      return make<IfNode>(analyze(f[1]), analyze(f[2]), f.size() == 4 ? analyze(f[3]) : nullptr);
    }
    if (head == s_define_) return analyze_define(f);
    if (head == s_set_) {
      if (f.size() != 3) syntax("bad set!");
      return make<SetNode>(as_symbol(f[1]), analyze(f[2]));
    }
    if (head == s_lambda_) {
      if (f.size() < 3) syntax("bad lambda");
      return analyze_lambda(f[1], f, 2);
    }
    if (head == s_let_) return analyze_let(f);
    if (head == s_letstar_) return analyze_let_star(f);
    if (head == s_letrec_) return analyze_letrec(f);
    if (head == s_begin_) {
      if (f.size() < 2) syntax("empty begin");
      return analyze_body(f, 1);
    }
    if (head == s_cond_) return analyze_cond(f);
    if (head == s_and_ || head == s_or_) {
      bool is_and = head == s_and_;
      if (f.size() == 1) return make<ConstNode>(Value::boolean(is_and));
      if (f.size() == 2) return analyze(f[1]);
      auto* n = make<AndOrNode>(is_and ? NodeKind::And : NodeKind::Or);
      for (size_t i = 1; i < f.size(); ++i) n->forms.push_back(analyze(f[i]));
      return n;
    }
  }
  auto* app = make<AppNode>();
  app->fn = analyze(f[0]);
  for (size_t i = 1; i < f.size(); ++i) app->args.push_back(analyze(f[i]));
  return app;
}

}  // namespace scheme
