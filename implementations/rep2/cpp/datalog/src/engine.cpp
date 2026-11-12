#include "datalog/engine.h"

#include <algorithm>
#include <array>
#include <map>
#include <set>

#include "datalog/parser.h"

namespace datalog {
namespace {

// ------------------------------------------------------------ compiled form

/// A constant (already encoded) or a rule variable slot.
struct ArgRef {
  bool is_const = false;
  Value value = 0;  // constant
  int var = -1;     // variable slot in the environment
};

struct Filter {
  enum class Kind { Negation, Comparison } kind = Kind::Comparison;
  Relation* rel = nullptr;  // Negation
  std::vector<ArgRef> args;  // Negation
  CompareOp op = CompareOp::Eq;
  ArgRef lhs, rhs;  // Comparison
  std::vector<int> vars;  // variables the filter needs bound
};

/// One positive body atom in a join plan.
struct Step {
  enum class Kind { Scan, Lookup, Probe } kind = Kind::Scan;
  Relation* rel = nullptr;
  Index* index = nullptr;                          // Lookup
  std::vector<ArgRef> key;                         // Lookup / Probe
  std::vector<std::pair<unsigned, Value>> consts;  // Scan: required constants
  std::vector<std::pair<unsigned, int>> binds;     // column -> new variable
  std::vector<std::pair<unsigned, int>> checks;    // column == bound variable
  std::vector<Filter> after;                       // filters now applicable
  int slot = -1;           // component-relation slot, -1 if lower stratum
  bool is_delta = false;
  bool earlier = false;    // in-component atom before the delta atom
  std::size_t lo = 0, hi = 0;
};

struct Plan {
  std::vector<Filter> pre;
  std::vector<Step> steps;
  Relation* head = nullptr;
  std::vector<ArgRef> head_args;
  std::size_t num_vars = 0;
  int delta_slot = -1;
};

// ----------------------------------------------------------------- Compiler

/// Per-rule variable numbering.
class VarTable {
 public:
  explicit VarTable(const Rule& rule) {
    auto note = [&](const Term& t) {
      if (t.kind == Term::Kind::Variable) ++counts_[id(t.variable)];
      else if (t.kind == Term::Kind::Anonymous) ++anon_;
    };
    for (const Term& t : rule.head.args) note(t);
    for (const Literal& l : rule.body) {
      if (l.kind == Literal::Kind::Comparison) { note(l.lhs); note(l.rhs); }
      else for (const Term& t : l.atom.args) note(t);
    }
  }
  int id(const std::string& name) {
    auto it = ids_.find(name);
    if (it != ids_.end()) return it->second;
    int n = static_cast<int>(ids_.size());
    counts_.push_back(0);
    ids_.emplace(name, n);
    return n;
  }
  bool singleton(int v) const { return counts_[v] == 1; }
  std::size_t size() const { return ids_.size(); }

 private:
  std::map<std::string, int> ids_;
  std::vector<int> counts_;
  int anon_ = 0;
};

class Compiler {
 public:
  Compiler(const std::vector<Constant>& constants,
           std::map<PredicateKey, std::unique_ptr<Relation>>& relations)
      : constants_(constants), relations_(relations) {}

  Value encode(const Constant& c) const {
    auto it = std::lower_bound(constants_.begin(), constants_.end(), c);
    return static_cast<Value>(it - constants_.begin());
  }

  Relation* rel_of(const Atom& a) { return relations_.at(key_of(a)).get(); }

  /// Builds the plan for `rule`. `delta` is the body index of the atom read
  /// from the delta (or -1); `slot_of` maps component predicates to slots.
  Plan compile(const Rule& rule, int delta,
               const std::map<PredicateKey, int>& slot_of) {
    VarTable vars(rule);
    Plan plan;
    plan.head = rel_of(rule.head);
    plan.num_vars = vars.size();
    plan.delta_slot = -1;

    auto arg = [&](const Term& t) {
      ArgRef r;
      if (t.kind == Term::Kind::Constant) {
        r.is_const = true;
        r.value = encode(t.constant);
      } else {
        r.var = vars.id(t.variable);  // safe rules have no anonymous here
      }
      return r;
    };
    for (const Term& t : rule.head.args) plan.head_args.push_back(arg(t));

    // Filters, in body order.
    std::vector<Filter> filters;
    for (const Literal& l : rule.body) {
      if (l.kind == Literal::Kind::Positive) continue;
      Filter f;
      if (l.kind == Literal::Kind::Negative) {
        f.kind = Filter::Kind::Negation;
        f.rel = rel_of(l.atom);
        for (const Term& t : l.atom.args) f.args.push_back(arg(t));
        for (const ArgRef& a : f.args) if (!a.is_const) f.vars.push_back(a.var);
      } else {
        f.kind = Filter::Kind::Comparison;
        f.op = l.op;
        f.lhs = arg(l.lhs);
        f.rhs = arg(l.rhs);
        if (!f.lhs.is_const) f.vars.push_back(f.lhs.var);
        if (!f.rhs.is_const) f.vars.push_back(f.rhs.var);
      }
      filters.push_back(std::move(f));
    }
    std::vector<bool> placed(filters.size(), false);
    std::vector<bool> bound(vars.size(), false);
    auto place = [&](std::vector<Filter>& dest) {
      for (std::size_t i = 0; i < filters.size(); ++i) {
        if (placed[i]) continue;
        bool ready = true;
        for (int v : filters[i].vars) if (!bound[v]) { ready = false; break; }
        if (ready) { placed[i] = true; dest.push_back(filters[i]); }
      }
    };
    place(plan.pre);

    // Positive atoms (body index preserved for tie-breaking).
    std::vector<int> remaining;
    for (std::size_t i = 0; i < rule.body.size(); ++i)
      if (rule.body[i].kind == Literal::Kind::Positive)
        remaining.push_back(static_cast<int>(i));

    bool first = true;
    while (!remaining.empty()) {
      std::size_t pick = 0;
      if (first && delta >= 0) {
        pick = std::find(remaining.begin(), remaining.end(), delta) -
               remaining.begin();
      } else {
        int best = -1;
        for (std::size_t j = 0; j < remaining.size(); ++j) {
          int n = 0;
          for (const Term& t : rule.body[remaining[j]].atom.args) {
            if (t.kind == Term::Kind::Constant) ++n;
            else if (t.kind == Term::Kind::Variable &&
                     bound[vars.id(t.variable)]) ++n;
          }
          if (n > best) { best = n; pick = j; }
        }
      }
      int body_index = remaining[pick];
      remaining.erase(remaining.begin() + pick);
      const Atom& atom = rule.body[body_index].atom;

      Step step;
      step.rel = rel_of(atom);
      auto sit = slot_of.find(key_of(atom));
      step.slot = sit == slot_of.end() ? -1 : sit->second;
      step.is_delta = first && delta >= 0;
      if (step.is_delta) plan.delta_slot = step.slot;
      step.earlier = delta >= 0 && body_index < delta;

      std::uint32_t mask = 0;
      std::vector<bool> seen_here(vars.size(), false);
      std::vector<ArgRef> key;
      for (unsigned c = 0; c < atom.args.size(); ++c) {
        const Term& t = atom.args[c];
        if (t.kind == Term::Kind::Constant) {
          mask |= 1u << c;
          Value v = encode(t.constant);
          key.push_back({true, v, -1});
          step.consts.emplace_back(c, v);
        } else if (t.kind == Term::Kind::Variable) {
          int v = vars.id(t.variable);
          if (bound[v]) {
            mask |= 1u << c;
            key.push_back({false, 0, v});
          } else if (seen_here[v]) {
            step.checks.emplace_back(c, v);
          } else if (!vars.singleton(v)) {
            seen_here[v] = true;
            step.binds.emplace_back(c, v);
          }
        }
      }
      unsigned arity = static_cast<unsigned>(atom.args.size());
      if (step.is_delta || mask == 0) {
        step.kind = Step::Kind::Scan;
      } else if (mask == (arity == 32 ? ~0u : (1u << arity) - 1)) {
        step.kind = Step::Kind::Probe;
        step.key = std::move(key);
      } else {
        step.kind = Step::Kind::Lookup;
        step.index = &step.rel->index(mask);
        step.key = std::move(key);
      }
      if (step.kind != Step::Kind::Scan) step.consts.clear();
      for (auto& b : step.binds) bound[b.second] = true;
      place(step.after);
      plan.steps.push_back(std::move(step));
      first = false;
    }
    return plan;
  }

 private:
  const std::vector<Constant>& constants_;
  std::map<PredicateKey, std::unique_ptr<Relation>>& relations_;
};

// ----------------------------------------------------------------- Executor

class Executor {
 public:
  void run(Plan& plan) {
    env_.assign(std::max<std::size_t>(plan.num_vars, 1), 0);
    if (!check(plan.pre)) return;
    descend(plan, 0);
  }

 private:
  bool check(const std::vector<Filter>& filters) {
    for (const Filter& f : filters) {
      if (f.kind == Filter::Kind::Negation) {
        std::array<Value, kMaxArity> t;
        for (std::size_t i = 0; i < f.args.size(); ++i)
          t[i] = f.args[i].is_const ? f.args[i].value : env_[f.args[i].var];
        if (f.rel->contains(t.data())) return false;
      } else {
        Value a = f.lhs.is_const ? f.lhs.value : env_[f.lhs.var];
        Value b = f.rhs.is_const ? f.rhs.value : env_[f.rhs.var];
        bool ok = false;
        switch (f.op) {  // values are ranks: order-preserving
          case CompareOp::Lt: ok = a < b; break;
          case CompareOp::Le: ok = a <= b; break;
          case CompareOp::Gt: ok = a > b; break;
          case CompareOp::Ge: ok = a >= b; break;
          case CompareOp::Eq: ok = a == b; break;
          case CompareOp::Ne: ok = a != b; break;
        }
        if (!ok) return false;
      }
    }
    return true;
  }

  /// Binds/checks the variables of tuple `t` for `s`, then continues.
  void accept(Plan& plan, std::size_t k, Step& s, const Value* t) {
    for (const auto& b : s.binds) env_[b.second] = t[b.first];
    for (const auto& c : s.checks)
      if (env_[c.second] != t[c.first]) return;
    if (!check(s.after)) return;
    descend(plan, k + 1);
  }

  void descend(Plan& plan, std::size_t k) {
    if (k == plan.steps.size()) {
      std::array<Value, kMaxArity> t;
      for (std::size_t i = 0; i < plan.head_args.size(); ++i)
        t[i] = plan.head_args[i].is_const ? plan.head_args[i].value
                                          : env_[plan.head_args[i].var];
      plan.head->insert(t.data());
      return;
    }
    Step& s = plan.steps[k];
    switch (s.kind) {
      case Step::Kind::Scan:
        for (std::size_t id = s.lo; id < s.hi; ++id) {
          const Value* t = s.rel->tuple(static_cast<std::uint32_t>(id));
          bool ok = true;
          for (const auto& c : s.consts)
            if (t[c.first] != c.second) { ok = false; break; }
          if (ok) accept(plan, k, s, t);
        }
        break;
      case Step::Kind::Lookup: {
        std::array<Value, kMaxArity> key;
        for (std::size_t i = 0; i < s.key.size(); ++i)
          key[i] = s.key[i].is_const ? s.key[i].value : env_[s.key[i].var];
        for (std::uint32_t id = s.index->first(key.data());
             id != kNone && id < s.hi; id = s.index->next(id))
          accept(plan, k, s, s.rel->tuple(id));
        break;
      }
      case Step::Kind::Probe: {
        std::array<Value, kMaxArity> key;
        for (std::size_t i = 0; i < s.key.size(); ++i)
          key[i] = s.key[i].is_const ? s.key[i].value : env_[s.key[i].var];
        std::uint32_t id = s.rel->find(key.data());
        if (id != kNone && id >= s.lo && id < s.hi)
          accept(plan, k, s, s.rel->tuple(id));
        break;
      }
    }
  }

  std::vector<Value> env_;
};

// ---------------------------------------------------------------- Evaluator

class Evaluator {
 public:
  Evaluator(const Program& program, const std::vector<Constant>& constants,
            std::map<PredicateKey, std::unique_ptr<Relation>>& relations)
      : program_(program), relations_(relations),
        compiler_(constants, relations) {}

  void run(const std::vector<std::vector<PredicateKey>>& components) {
    // Facts first: they are present before any stratum is evaluated.
    for (const Rule& r : program_.rules) {
      if (!r.body.empty()) continue;
      std::array<Value, kMaxArity> t;
      for (std::size_t i = 0; i < r.head.args.size(); ++i)
        t[i] = compiler_.encode(r.head.args[i].constant);
      compiler_.rel_of(r.head)->insert(t.data());
    }
    std::map<PredicateKey, std::vector<const Rule*>> by_head;
    for (const Rule& r : program_.rules)
      if (!r.body.empty()) by_head[key_of(r.head)].push_back(&r);

    for (const auto& comp : components) {
      std::map<PredicateKey, int> slot_of;
      std::vector<Relation*> rels;
      for (const PredicateKey& k : comp) {
        slot_of.emplace(k, static_cast<int>(rels.size()));
        rels.push_back(relations_.at(k).get());
      }
      std::vector<Plan> base, variants;
      for (const PredicateKey& k : comp) {
        auto it = by_head.find(k);
        if (it == by_head.end()) continue;
        for (const Rule* r : it->second) {
          std::vector<int> rec;
          for (std::size_t i = 0; i < r->body.size(); ++i)
            if (r->body[i].kind == Literal::Kind::Positive &&
                slot_of.count(key_of(r->body[i].atom)))
              rec.push_back(static_cast<int>(i));
          if (rec.empty()) {
            base.push_back(compiler_.compile(*r, -1, slot_of));
          } else {
            for (int d : rec)
              variants.push_back(compiler_.compile(*r, d, slot_of));
          }
        }
      }
      evaluate_component(rels, base, variants);
    }
  }

 private:
  void prepare(Plan& p, const std::vector<std::size_t>& ds,
               const std::vector<std::size_t>& de) {
    for (Step& s : p.steps) {
      s.lo = 0;
      s.hi = s.rel->size();
      if (s.slot < 0) continue;
      if (s.is_delta) { s.lo = ds[s.slot]; s.hi = de[s.slot]; }
      else s.hi = s.earlier ? ds[s.slot] : de[s.slot];
    }
  }

  void evaluate_component(const std::vector<Relation*>& rels,
                          std::vector<Plan>& base,
                          std::vector<Plan>& variants) {
    std::vector<std::size_t> ds(rels.size(), 0), de(rels.size(), 0);
    for (Plan& p : base) {
      prepare(p, ds, de);
      exec_.run(p);
    }
    if (variants.empty()) return;
    for (std::size_t i = 0; i < rels.size(); ++i) de[i] = rels[i]->size();
    for (;;) {
      bool any = false;
      for (std::size_t i = 0; i < rels.size(); ++i) any |= ds[i] < de[i];
      if (!any) break;
      for (Relation* r : rels) r->sync_indexes();
      for (Plan& p : variants) {
        if (ds[p.delta_slot] == de[p.delta_slot]) continue;
        prepare(p, ds, de);
        exec_.run(p);
      }
      for (std::size_t i = 0; i < rels.size(); ++i) {
        ds[i] = de[i];
        de[i] = rels[i]->size();
      }
    }
  }

  const Program& program_;
  std::map<PredicateKey, std::unique_ptr<Relation>>& relations_;
  Compiler compiler_;
  Executor exec_;
};

void collect(const Term& t, std::vector<Constant>& out) {
  if (t.kind == Term::Kind::Constant) out.push_back(t.constant);
}

}  // namespace

// -------------------------------------------------------------------- Model

Model evaluate(const Program& program) {
  check_safety(program);
  auto components = stratify(program);

  Model model;
  for (const auto& comp : components)
    for (const PredicateKey& k : comp) {
      if (k.arity > kMaxArity) throw ProgramError("arity too large");
      model.relations_.emplace(
          k, std::make_unique<Relation>(static_cast<unsigned>(k.arity)));
    }

  std::vector<Constant>& cs = model.constants_;
  for (const Rule& r : program.rules) {
    for (const Term& t : r.head.args) collect(t, cs);
    for (const Literal& l : r.body) {
      if (l.kind == Literal::Kind::Comparison) {
        collect(l.lhs, cs);
        collect(l.rhs, cs);
      } else {
        for (const Term& t : l.atom.args) collect(t, cs);
      }
    }
  }
  std::sort(cs.begin(), cs.end());
  cs.erase(std::unique(cs.begin(), cs.end()), cs.end());

  Evaluator ev(program, model.constants_, model.relations_);
  ev.run(components);
  return model;
}

std::size_t Model::size(const std::string& predicate,
                        std::size_t arity) const {
  auto it = relations_.find(PredicateKey{predicate, arity});
  return it == relations_.end() ? 0 : it->second->size();
}

std::vector<Tuple> Model::query(const Atom& atom) {
  std::vector<Tuple> result;
  auto it = relations_.find(key_of(atom));
  if (it == relations_.end()) return result;
  Relation& rel = *it->second;
  const unsigned arity = rel.arity();

  std::uint32_t mask = 0;
  std::array<Value, kMaxArity> key;
  std::size_t nkey = 0;
  std::vector<std::pair<unsigned, unsigned>> equal;  // column pairs
  std::map<std::string, unsigned> first_col;
  for (unsigned c = 0; c < arity; ++c) {
    const Term& t = atom.args[c];
    if (t.kind == Term::Kind::Constant) {
      auto pos = std::lower_bound(constants_.begin(), constants_.end(),
                                  t.constant);
      if (pos == constants_.end() || *pos != t.constant) return result;
      mask |= 1u << c;
      key[nkey++] = static_cast<Value>(pos - constants_.begin());
    } else if (t.kind == Term::Kind::Variable) {
      auto [f, inserted] = first_col.emplace(t.variable, c);
      if (!inserted) equal.emplace_back(f->second, c);
    }
  }

  std::vector<std::uint32_t> ids;
  auto consider = [&](std::uint32_t id) {
    const Value* t = rel.tuple(id);
    for (auto [a, b] : equal)
      if (t[a] != t[b]) return;
    ids.push_back(id);
  };
  if (mask != 0) {
    Index& idx = rel.index(mask);
    for (std::uint32_t id = idx.first(key.data()); id != kNone;
         id = idx.next(id))
      consider(id);
  } else {
    for (std::uint32_t id = 0; id < rel.size(); ++id) consider(id);
  }
  std::sort(ids.begin(), ids.end(), [&](std::uint32_t a, std::uint32_t b) {
    return std::lexicographical_compare(rel.tuple(a), rel.tuple(a) + arity,
                                        rel.tuple(b), rel.tuple(b) + arity);
  });
  result.reserve(ids.size());
  for (std::uint32_t id : ids) {
    Tuple t;
    t.reserve(arity);
    const Value* v = rel.tuple(id);
    for (unsigned c = 0; c < arity; ++c) t.push_back(constants_[v[c]]);
    result.push_back(std::move(t));
  }
  return result;
}

std::string Model::answer(const Query& q) {
  std::string out;
  std::vector<Tuple> rows = query(q.atom);
  for (const Tuple& t : rows) {
    out += q.atom.predicate;
    out += '(';
    for (std::size_t i = 0; i < t.size(); ++i) {
      if (i) out += ", ";
      out += t[i].to_string();
    }
    out += ")\n";
  }
  out += "-- " + std::to_string(rows.size()) + "\n";
  return out;
}

std::string run_program(const std::string& source) {
  Program program = parse_program(source);
  try {
    Model model = evaluate(program);
    std::string out;
    for (const Query& q : program.queries) out += model.answer(q);
    return out;
  } catch (const ProgramError&) {
    return "error\n";
  }
}

}  // namespace datalog
