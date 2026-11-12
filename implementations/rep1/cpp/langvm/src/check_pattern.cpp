// Pattern typing and irrefutability (SPEC.md sections 12.1, 12.2, 12.6).
#include "checker.h"
#include "langvm/diagnostic.h"

namespace langvm {

void Checker::checkPatternTop(Pattern& p, Type* t) {
  std::set<std::string> seen;
  checkPattern(p, t, seen);
}

LocalVar* Checker::declarePatternVar(const std::string& name, Pos pos, Type* t, std::set<std::string>& seen) {
  if (!seen.insert(name).second) err(ErrorKind::DupName, pos);
  return declare(name, t, false);
}

void Checker::checkPattern(Pattern& p, Type* t, std::set<std::string>& seen) {
  t = prune(t);
  auto mismatch = [&]() { err(ErrorKind::TypeMismatch, p.pos); };
  switch (p.kind) {
    case Pattern::K::Wild: return;
    case Pattern::K::Bind: p.var = declarePatternVar(p.name, p.namePos, t, seen); return;
    case Pattern::K::Float: err(ErrorKind::BadPattern, p.pos);
    case Pattern::K::Int: if (t->kind != TK::Int) mismatch(); return;
    case Pattern::K::Str: if (t->kind != TK::Str) mismatch(); return;
    case Pattern::K::Char: if (t->kind != TK::Char) mismatch(); return;
    case Pattern::K::Bool: if (t->kind != TK::Bool) mismatch(); return;
    case Pattern::K::Tuple:
      if (t->kind != TK::Tuple || t->args.size() != p.subs.size()) mismatch();
      for (size_t i = 0; i < p.subs.size(); ++i) checkPattern(*p.subs[i], t->args[i], seen);
      return;
    case Pattern::K::List:
      if (t->kind != TK::List) mismatch();
      for (auto& s : p.subs) checkPattern(*s, t->args[0], seen);
      if (p.hasRest && !p.restName.empty()) p.var = declarePatternVar(p.restName, p.restPos, A_.list(t->args[0]), seen);
      return;
    case Pattern::K::Struct: {
      Type* selfT;
      int decl = resolveStructDecl(p.qual, p.qualPos, p.name, p.namePos, p.pos, &selfT);
      if (t->kind != TK::Named || t->decl != decl) mismatch();
      const TypeDeclInfo& d = m_.decls[static_cast<size_t>(decl)];
      for (size_t i = 0; i < p.fields.size(); ++i) {
        FieldPat& f = p.fields[i];
        for (size_t j = 0; j < i; ++j)
          if (p.fields[j].name == f.name) err(ErrorKind::DupField, f.pos);
        int idx = -1;
        for (size_t k = 0; k < d.fields.size(); ++k)
          if (d.fields[k].name == f.name) idx = static_cast<int>(k);
        if (idx < 0) err(ErrorKind::UnknownField, f.pos);
        f.fieldIdx = idx;
      }
      if (!p.hasDots && p.fields.size() != d.fields.size()) err(ErrorKind::MissingField, p.pos);
      p.decl = decl;
      for (FieldPat& f : p.fields)
        checkPattern(*f.pat, A_.subst(d.fields[static_cast<size_t>(f.fieldIdx)].type, d.params, t->args), seen);
      return;
    }
    case Pattern::K::Path: {
      ValueRes r;
      if (!p.hasParens && p.qual.empty()) {
        const ValueEntry* ve = findValueEntry(p.name);
        bool zeroVariant = ve && ve->kind == ValueEntry::K::Variant &&
                           m_.decls[static_cast<size_t>(ve->id)].variants[static_cast<size_t>(ve->variant)].payload.empty();
        if (!zeroVariant) {
          p.kind = Pattern::K::Bind;
          p.var = declarePatternVar(p.name, p.namePos, t, seen);
          return;
        }
        r.kind = ValueRes::K::Variant;
        r.id = ve->id;
        r.variant = ve->variant;
      } else {
        resolveValue(p.qual, p.qualPos, p.name, p.namePos, false, r);
        if (r.kind != ValueRes::K::Variant) mismatch();
      }
      const TypeDeclInfo& d = m_.decls[static_cast<size_t>(r.id)];
      const VariantInfo& v = d.variants[static_cast<size_t>(r.variant)];
      if (t->kind != TK::Named || t->decl != r.id) mismatch();
      if (p.subs.size() != v.payload.size()) err(ErrorKind::Arity, p.pos);
      p.decl = r.id;
      p.variant = r.variant;
      for (size_t i = 0; i < p.subs.size(); ++i)
        checkPattern(*p.subs[i], A_.subst(v.payload[i], d.params, t->args), seen);
      return;
    }
  }
}

bool Checker::irrefutable(const Pattern& p) const {
  switch (p.kind) {
    case Pattern::K::Wild: case Pattern::K::Bind: return true;
    case Pattern::K::Tuple:
      for (auto& s : p.subs)
        if (!irrefutable(*s)) return false;
      return true;
    case Pattern::K::Struct:
      for (const FieldPat& f : p.fields)
        if (!irrefutable(*f.pat)) return false;
      return true;
    case Pattern::K::Path: {
      if (m_.decls[static_cast<size_t>(p.decl)].variants.size() != 1) return false;
      for (auto& s : p.subs)
        if (!irrefutable(*s)) return false;
      return true;
    }
    case Pattern::K::List: return p.hasRest && p.subs.empty();
    default: return false;
  }
}

}  // namespace langvm
