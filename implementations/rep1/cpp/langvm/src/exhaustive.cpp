// Exhaustiveness and reachability by the usefulness algorithm (SPEC.md section 12.4).
#include <map>
#include <set>

#include "checker.h"
#include "langvm/diagnostic.h"

namespace langvm {
namespace {

struct DPat {
  enum class K { Wild, Ctor, List } k = K::Wild;
  int64_t ctor = 0;  // Ctor: variant index / literal value / 0 for single-constructor types
  bool open = false; // List: has a rest
  std::vector<DPat> subs;
};

using Row = std::vector<const DPat*>;
const DPat kWild;

class Coverage {
 public:
  explicit Coverage(Model& m) : m_(m) {}

  DPat convert(const Pattern& p) {
    DPat d;
    switch (p.kind) {
      case Pattern::K::Wild: case Pattern::K::Bind: return d;
      case Pattern::K::Int: case Pattern::K::Char:
        d.k = DPat::K::Ctor;
        d.ctor = p.ival;
        return d;
      case Pattern::K::Bool:
        d.k = DPat::K::Ctor;
        d.ctor = p.bval ? 1 : 0;
        return d;
      case Pattern::K::Str: {
        d.k = DPat::K::Ctor;
        auto it = strIds_.emplace(p.sval, static_cast<int64_t>(strIds_.size())).first;
        d.ctor = it->second;
        return d;
      }
      case Pattern::K::Tuple:
        d.k = DPat::K::Ctor;
        for (auto& s : p.subs) d.subs.push_back(convert(*s));
        return d;
      case Pattern::K::List:
        d.k = DPat::K::List;
        d.open = p.hasRest;
        for (auto& s : p.subs) d.subs.push_back(convert(*s));
        return d;
      case Pattern::K::Struct:
        d.k = DPat::K::Ctor;
        d.subs.resize(m_.decls[static_cast<size_t>(p.decl)].fields.size());
        for (const FieldPat& f : p.fields) d.subs[static_cast<size_t>(f.fieldIdx)] = convert(*f.pat);
        return d;
      case Pattern::K::Path:
        d.k = DPat::K::Ctor;
        d.ctor = p.variant;
        for (auto& s : p.subs) d.subs.push_back(convert(*s));
        return d;
      default: return d;
    }
  }

  bool useful(const std::vector<Row>& P, const Row& q, const std::vector<Type*>& tys) {
    if (q.empty()) return P.empty();
    Type* t = prune(tys[0]);
    const DPat& q0 = *q[0];
    if (t->kind == TK::List) return usefulList(P, q, tys, t);
    if (q0.k == DPat::K::Ctor) return specializeAndRecurse(P, q, tys, t, q0.ctor);
    // q0 is a wildcard
    std::set<int64_t> used;
    for (const Row& r : P)
      if (r[0]->k == DPat::K::Ctor) used.insert(r[0]->ctor);
    int n = ctorCount(t);
    if (n >= 0 && static_cast<int>(used.size()) == n) {
      for (int64_t c : used)
        if (specializeAndRecurse(P, q, tys, t, c)) return true;
      return false;
    }
    std::vector<Row> D;
    for (const Row& r : P)
      if (r[0]->k == DPat::K::Wild) D.emplace_back(r.begin() + 1, r.end());
    return useful(D, Row(q.begin() + 1, q.end()), std::vector<Type*>(tys.begin() + 1, tys.end()));
  }

 private:
  Model& m_;
  std::map<std::u32string, int64_t> strIds_;

  int ctorCount(Type* t) {
    switch (t->kind) {
      case TK::Bool: return 2;
      case TK::Unit: case TK::Tuple: return 1;
      case TK::Named: {
        const TypeDeclInfo& d = m_.decls[static_cast<size_t>(t->decl)];
        return d.isEnum ? static_cast<int>(d.variants.size()) : 1;
      }
      default: return -1;
    }
  }

  std::vector<Type*> subTypes(Type* t, int64_t c) {
    if (t->kind == TK::Tuple) return t->args;
    if (t->kind == TK::Named) {
      const TypeDeclInfo& d = m_.decls[static_cast<size_t>(t->decl)];
      std::vector<Type*> out;
      if (d.isEnum) {
        for (Type* p : d.variants[static_cast<size_t>(c)].payload) out.push_back(m_.types.subst(p, d.params, t->args));
      } else {
        for (const FieldInfo& f : d.fields) out.push_back(m_.types.subst(f.type, d.params, t->args));
      }
      return out;
    }
    return {};
  }

  bool specializeAndRecurse(const std::vector<Row>& P, const Row& q, const std::vector<Type*>& tys, Type* t,
                            int64_t c) {
    std::vector<Type*> sub = subTypes(t, c);
    size_t k = sub.size();
    std::vector<Type*> ntys = sub;
    ntys.insert(ntys.end(), tys.begin() + 1, tys.end());
    std::vector<Row> SP;
    for (const Row& r : P) {
      const DPat& p = *r[0];
      if (p.k == DPat::K::Ctor && p.ctor != c) continue;
      Row nr;
      if (p.k == DPat::K::Ctor) {
        for (const DPat& s : p.subs) nr.push_back(&s);
      } else {
        nr.assign(k, &kWild);
      }
      nr.insert(nr.end(), r.begin() + 1, r.end());
      SP.push_back(std::move(nr));
    }
    Row nq;
    const DPat& q0 = *q[0];
    if (q0.k == DPat::K::Ctor) {
      for (const DPat& s : q0.subs) nq.push_back(&s);
    } else {
      nq.assign(k, &kWild);
    }
    nq.insert(nq.end(), q.begin() + 1, q.end());
    return useful(SP, nq, ntys);
  }

  bool usefulList(const std::vector<Row>& P, const Row& q, const std::vector<Type*>& tys, Type* t) {
    size_t lmax = 0;
    for (const Row& r : P)
      if (r[0]->k == DPat::K::List) lmax = std::max(lmax, r[0]->subs.size());
    const DPat& q0 = *q[0];
    if (q0.k == DPat::K::List) lmax = std::max(lmax, q0.subs.size());
    Type* elem = t->args[0];
    for (size_t k = 0; k <= lmax + 1; ++k) {
      bool admits = q0.k == DPat::K::Wild || (q0.k == DPat::K::List && (q0.open ? k >= q0.subs.size() : k == q0.subs.size()));
      if (!admits) continue;
      std::vector<Row> SP;
      for (const Row& r : P) {
        const DPat& p = *r[0];
        Row nr;
        if (p.k == DPat::K::Wild) {
          nr.assign(k, &kWild);
        } else {
          size_t n = p.subs.size();
          if (p.open ? n > k : n != k) continue;
          for (const DPat& s : p.subs) nr.push_back(&s);
          nr.resize(k, &kWild);
        }
        nr.insert(nr.end(), r.begin() + 1, r.end());
        SP.push_back(std::move(nr));
      }
      Row nq;
      if (q0.k == DPat::K::Wild) {
        nq.assign(k, &kWild);
      } else {
        for (const DPat& s : q0.subs) nq.push_back(&s);
        nq.resize(k, &kWild);
      }
      nq.insert(nq.end(), q.begin() + 1, q.end());
      std::vector<Type*> ntys(k, elem);
      ntys.insert(ntys.end(), tys.begin() + 1, tys.end());
      if (useful(SP, nq, ntys)) return true;
    }
    return false;
  }
};

}  // namespace

void Checker::checkMatchCoverage(Expr& match, Type* scrutinee) {
  Coverage cov(m_);
  std::vector<DPat> dp;
  dp.reserve(match.arms.size());
  for (Arm& a : match.arms) dp.push_back(cov.convert(*a.pat));
  std::vector<Type*> tys = {scrutinee};
  std::vector<Row> earlier;
  for (size_t i = 0; i < match.arms.size(); ++i) {
    Row q = {&dp[i]};
    if (!cov.useful(earlier, q, tys)) err(ErrorKind::Unreachable, match.arms[i].pos);
    if (!match.arms[i].guard) earlier.push_back(Row{&dp[i]});
  }
  Row q = {&kWild};
  if (cov.useful(earlier, q, tys)) err(ErrorKind::NonExhaustive, match.pos);
}

}  // namespace langvm
