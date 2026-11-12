#include "resolver.h"

#include <algorithm>
#include <set>

#include "builtins.h"
#include "langvm/diagnostic.h"
#include "lexer.h"
#include "parser.h"

namespace langvm {
namespace {

const char* const kReserved[] = {"Int", "Float", "Bool", "Char", "Str", "Unit", "Self"};

bool isReserved(const std::string& n) {
  for (const char* r : kReserved)
    if (n == r) return true;
  return false;
}

bool primitiveType(const std::string& n, TK& out) {
  static const std::pair<const char*, TK> prims[] = {{"Int", TK::Int}, {"Float", TK::Float}, {"Bool", TK::Bool},
                                                      {"Char", TK::Char}, {"Str", TK::Str}, {"Unit", TK::Unit}};
  for (auto& p : prims)
    if (n == p.first) {
      out = p.second;
      return true;
    }
  return false;
}

}  // namespace

int headCtor(const Type* t) {
  switch (t->kind) {
    case TK::Int: case TK::Float: case TK::Bool: case TK::Char: case TK::Str: case TK::Unit:
      return static_cast<int>(t->kind);
    case TK::List: return kCtorList;
    case TK::Map: return kCtorMap;
    case TK::Named: return kCtorDeclBase + t->decl;
    default: return -1;
  }
}

void Resolver::err(ErrorKind k, Pos p) const { throw CompileError(k, p.line, p.col); }

bool Resolver::satisfiesKey(Type* t) const {
  t = prune(t);
  switch (t->kind) {
    case TK::Int: case TK::Bool: case TK::Char: case TK::Str: return true;
    case TK::Param:
      return std::find(t->param->bounds.begin(), t->param->bounds.end(), kTraitKey) != t->param->bounds.end();
    default: return false;
  }
}

// ---------------------------------------------------------------- prelude

void Resolver::loadPrelude() {
  const char* names[] = {"Eq", "Ord", "Key"};
  for (int i = 0; i < 3; ++i) {
    m_.traits.emplace_back();
    TraitInfo& t = m_.traits.back();
    t.name = names[i];
    t.builtin = true;
    m_.prelude.traits[names[i]] = i;
  }
  std::string src = "pub enum Option<T> { Some(T), None }\npub enum Result<T, E> { Ok(T), Err(E) }\n";
  src += builtinSignatureSource();
  std::u32string text;
  for (char c : src) text.push_back(static_cast<char32_t>(static_cast<unsigned char>(c)));
  m_.prelude.name = "<prelude>";
  m_.prelude.ast = parseModule(lex(text));
  declareItems(-1);
  m_.optionDecl = m_.prelude.types.at("Option");
  m_.resultDecl = m_.prelude.types.at("Result");
  signatures(-1);
}

// ------------------------------------------------------------ pass 3.1

std::vector<TypeParam*> Resolver::makeParams(const std::vector<GenParam>& gps) {
  std::vector<TypeParam*> ps;
  for (const GenParam& g : gps) ps.push_back(m_.newParam(g.name));
  return ps;
}

void Resolver::declareItems(int mi) {
  ModuleInfo& mod = m_.mod(mi);
  ModuleAst& ast = mod.ast;
  for (const Item& it : ast.items) {
    switch (it.kind) {
      case ItemKind::Use: break;
      case ItemKind::Fn: {
        FnDecl& f = *ast.fns[it.index];
        m_.funcs.emplace_back();
        int id = static_cast<int>(m_.funcs.size()) - 1;
        FuncInfo& fi = m_.funcs.back();
        fi.name = f.name;
        fi.ast = &f;
        fi.module = mi;
        fi.kind = mi < 0 ? FuncInfo::Kind::Builtin : FuncInfo::Kind::Free;
        if (mi < 0) {
          fi.builtin = builtinIndex(f.name);
          if (fi.builtin < 0) throw std::logic_error("builtin without implementation: " + f.name);
        }
        fi.tparams = makeParams(f.generics);
        fi.scopeParams = fi.tparams;
        f.funcId = id;
        ValueEntry e;
        e.kind = ValueEntry::K::Func;
        e.id = id;
        e.pub = f.pub;
        if (!mod.values.emplace(f.name, e).second) err(ErrorKind::DupName, f.namePos);
        break;
      }
      case ItemKind::Struct: {
        StructDecl& s = *ast.structs[it.index];
        if (isReserved(s.name)) err(ErrorKind::ReservedName, s.namePos);
        m_.decls.emplace_back();
        int id = static_cast<int>(m_.decls.size()) - 1;
        TypeDeclInfo& d = m_.decls.back();
        d.isEnum = false;
        d.name = s.name;
        d.module = mi;
        d.pub = s.pub;
        d.params = makeParams(s.generics);
        s.declId = id;
        if (!mod.types.emplace(s.name, id).second) err(ErrorKind::DupName, s.namePos);
        break;
      }
      case ItemKind::Enum: {
        EnumDecl& e = *ast.enums[it.index];
        if (isReserved(e.name)) err(ErrorKind::ReservedName, e.namePos);
        m_.decls.emplace_back();
        int id = static_cast<int>(m_.decls.size()) - 1;
        {
          TypeDeclInfo& d = m_.decls.back();
          d.isEnum = true;
          d.name = e.name;
          d.module = mi;
          d.pub = e.pub;
          d.params = makeParams(e.generics);
          d.variants.resize(e.variants.size());
        }
        e.declId = id;
        if (!mod.types.emplace(e.name, id).second) err(ErrorKind::DupName, e.namePos);
        for (size_t v = 0; v < e.variants.size(); ++v) {
          m_.decls[static_cast<size_t>(id)].variants[v].name = e.variants[v].name;
          m_.decls[static_cast<size_t>(id)].variants[v].pos = e.variants[v].pos;
          ValueEntry ve;
          ve.kind = ValueEntry::K::Variant;
          ve.id = id;
          ve.variant = static_cast<int>(v);
          ve.pub = e.pub;
          if (!mod.values.emplace(e.variants[v].name, ve).second) err(ErrorKind::DupName, e.variants[v].pos);
        }
        break;
      }
      case ItemKind::Trait: {
        TraitDecl& t = *ast.traits[it.index];
        if (isReserved(t.name)) err(ErrorKind::ReservedName, t.namePos);
        m_.traits.emplace_back();
        int id = static_cast<int>(m_.traits.size()) - 1;
        {
          TraitInfo& ti = m_.traits.back();
          ti.name = t.name;
          ti.module = mi;
          ti.pub = t.pub;
          ti.ast = &t;
          ti.selfParam = m_.newParam("Self");
          ti.selfParam->bounds.push_back(id);
          ti.methods.resize(t.methods.size());
        }
        t.traitId = id;
        if (!mod.traits.emplace(t.name, id).second) err(ErrorKind::DupName, t.namePos);
        for (size_t k = 0; k < t.methods.size(); ++k) {
          FnDecl& f = t.methods[k];
          TraitMethodInfo& tm = m_.traits[static_cast<size_t>(id)].methods[k];
          tm.name = f.name;
          tm.pos = f.namePos;
          tm.ast = &f;
          tm.hasDefault = f.body != nullptr;
          if (f.body) {
            m_.funcs.emplace_back();
            int fid = static_cast<int>(m_.funcs.size()) - 1;
            FuncInfo& fi = m_.funcs.back();
            fi.kind = FuncInfo::Kind::TraitDefault;
            fi.name = f.name;
            fi.ast = &f;
            fi.module = mi;
            fi.trait = id;
            fi.scopeParams = {};
            f.funcId = fid;
            tm.defaultFunc = fid;
          }
        }
        break;
      }
      case ItemKind::Impl: {
        ImplDecl& im = *ast.impls[it.index];
        m_.impls.emplace_back();
        int id = static_cast<int>(m_.impls.size()) - 1;
        ImplInfo& ii = m_.impls.back();
        ii.module = mi;
        ii.ast = &im;
        ii.tparams = makeParams(im.generics);
        im.implId = id;
        for (FnDecl& f : im.methods) {
          m_.funcs.emplace_back();
          int fid = static_cast<int>(m_.funcs.size()) - 1;
          FuncInfo& fi = m_.funcs.back();
          fi.kind = FuncInfo::Kind::ImplMethod;
          fi.name = f.name;
          fi.ast = &f;
          fi.module = mi;
          fi.impl = id;
          fi.scopeParams = ii.tparams;
          f.funcId = fid;
          ii.methodFuncs.push_back(fid);
        }
        break;
      }
    }
  }
}

// ------------------------------------------------------------ pass 3.3

void Resolver::internalDups(int mi) {
  ModuleAst& ast = m_.mod(mi).ast;
  auto genDups = [&](const std::vector<GenParam>& gps) {
    std::set<std::string> seen;
    for (const GenParam& g : gps)
      if (!seen.insert(g.name).second) err(ErrorKind::DupName, g.pos);
  };
  auto paramDups = [&](const std::vector<Param>& ps) {
    std::set<std::string> seen;
    for (const Param& p : ps)
      if (!seen.insert(p.name).second) err(ErrorKind::DupName, p.pos);
  };
  auto methodDups = [&](const std::vector<FnDecl>& ms) {
    std::set<std::string> seen;
    for (const FnDecl& f : ms)
      if (!seen.insert(f.name).second) err(ErrorKind::DupName, f.namePos);
    for (const FnDecl& f : ms) paramDups(f.params);
  };
  for (const Item& it : ast.items) {
    switch (it.kind) {
      case ItemKind::Use: break;
      case ItemKind::Fn: {
        FnDecl& f = *ast.fns[it.index];
        genDups(f.generics);
        paramDups(f.params);
        break;
      }
      case ItemKind::Struct: {
        StructDecl& s = *ast.structs[it.index];
        genDups(s.generics);
        std::set<std::string> seen;
        for (const FieldDecl& f : s.fields)
          if (!seen.insert(f.name).second) err(ErrorKind::DupName, f.pos);
        break;
      }
      case ItemKind::Enum: genDups(ast.enums[it.index]->generics); break;
      case ItemKind::Trait: methodDups(ast.traits[it.index]->methods); break;
      case ItemKind::Impl: {
        ImplDecl& im = *ast.impls[it.index];
        genDups(im.generics);
        methodDups(im.methods);
        break;
      }
    }
  }
}

// ------------------------------------------------------- type resolution

int Resolver::resolveTraitRef(const TraitRef& r, int module) {
  ModuleInfo& cur = m_.mod(module);
  if (!r.qual.empty()) {
    auto im = cur.imports.find(r.qual);
    if (im == cur.imports.end()) err(ErrorKind::UnknownModule, r.qualPos);
    ModuleInfo& other = m_.mod(im->second);
    auto t = other.traits.find(r.name);
    if (t == other.traits.end()) err(ErrorKind::UnknownTrait, r.namePos);
    if (!m_.traits[static_cast<size_t>(t->second)].pub && im->second != module) err(ErrorKind::NotPublic, r.namePos);
    return t->second;
  }
  auto t = cur.traits.find(r.name);
  if (t != cur.traits.end()) return t->second;
  auto p = m_.prelude.traits.find(r.name);
  if (p != m_.prelude.traits.end()) return p->second;
  err(ErrorKind::UnknownTrait, r.namePos);
}

Type* Resolver::resolveType(const TypeExpr& te, const TypeScope& sc) {
  TypeArena& A = m_.types;
  switch (te.kind) {
    case TypeExpr::K::List: return A.list(resolveType(*te.args[0], sc));
    case TypeExpr::K::Map: {
      Type* k = resolveType(*te.args[0], sc);
      Type* v = resolveType(*te.args[1], sc);
      if (!satisfiesKey(k)) err(ErrorKind::BadKeyType, te.pos);
      return A.map(k, v);
    }
    case TypeExpr::K::Tuple: {
      if (te.args.size() > 8) err(ErrorKind::BadArity, te.pos);
      std::vector<Type*> cs;
      for (auto& a : te.args) cs.push_back(resolveType(*a, sc));
      return A.tuple(std::move(cs));
    }
    case TypeExpr::K::Fn: {
      if (te.args.size() > 16) err(ErrorKind::BadArity, te.pos);
      std::vector<Type*> ps;
      for (auto& a : te.args) ps.push_back(resolveType(*a, sc));
      Type* ret = te.ret ? resolveType(*te.ret, sc) : A.unitT();
      return A.fn(std::move(ps), ret);
    }
    case TypeExpr::K::Path: break;
  }
  auto named = [&](int declId) {
    const TypeDeclInfo& d = m_.decls[static_cast<size_t>(declId)];
    if (te.args.size() != d.params.size()) err(ErrorKind::ArityType, te.pos);
    std::vector<Type*> as;
    for (auto& a : te.args) as.push_back(resolveType(*a, sc));
    return A.named(declId, std::move(as));
  };
  ModuleInfo& cur = m_.mod(sc.module);
  if (!te.qual.empty()) {
    auto im = cur.imports.find(te.qual);
    if (im == cur.imports.end()) err(ErrorKind::UnknownModule, te.qualPos);
    ModuleInfo& other = m_.mod(im->second);
    auto t = other.types.find(te.name);
    if (t == other.types.end()) err(ErrorKind::UnknownType, te.namePos);
    if (!m_.decls[static_cast<size_t>(t->second)].pub && im->second != sc.module) err(ErrorKind::NotPublic, te.namePos);
    return named(t->second);
  }
  for (TypeParam* p : sc.params)
    if (p->name == te.name) {
      if (te.hasArgs) err(ErrorKind::ArityType, te.pos);
      return A.param(p);
    }
  if (te.name == "Self") {
    if (!sc.self) err(ErrorKind::SelfOutside, te.pos);
    if (te.hasArgs) err(ErrorKind::ArityType, te.pos);
    return sc.self;
  }
  TK pk;
  if (primitiveType(te.name, pk)) {
    if (te.hasArgs) err(ErrorKind::ArityType, te.pos);
    return A.prim(pk);
  }
  auto t = cur.types.find(te.name);
  if (t != cur.types.end()) return named(t->second);
  if (te.name == "Option") return named(m_.optionDecl);
  if (te.name == "Result") return named(m_.resultDecl);
  err(ErrorKind::UnknownType, te.namePos);
}

// ------------------------------------------------------------ pass 3.4

void Resolver::resolveBounds(const std::vector<GenParam>& gps, const std::vector<TypeParam*>& ps, int module) {
  for (size_t i = 0; i < gps.size(); ++i)
    for (const TraitRef& b : gps[i].bounds) ps[i]->bounds.push_back(resolveTraitRef(b, module));
}

void Resolver::signatures(int mi) {
  ModuleInfo& mod = m_.mod(mi);
  ModuleAst& ast = mod.ast;
  TypeArena& A = m_.types;
  for (const Item& it : ast.items) {
    switch (it.kind) {
      case ItemKind::Use: break;
      case ItemKind::Fn: {
        FnDecl& f = *ast.fns[it.index];
        FuncInfo& fi = m_.funcs[static_cast<size_t>(f.funcId)];
        resolveBounds(f.generics, fi.tparams, mi);
        TypeScope sc{mi, fi.tparams, nullptr};
        for (Param& p : f.params) fi.params.push_back(resolveType(*p.type, sc));
        fi.ret = f.ret ? resolveType(*f.ret, sc) : A.unitT();
        break;
      }
      case ItemKind::Struct: {
        StructDecl& s = *ast.structs[it.index];
        TypeDeclInfo& d = m_.decls[static_cast<size_t>(s.declId)];
        TypeScope sc{mi, d.params, nullptr};
        for (FieldDecl& f : s.fields) {
          FieldInfo fi;
          fi.name = f.name;
          fi.pos = f.pos;
          fi.type = resolveType(*f.type, sc);
          d.fields.push_back(fi);
        }
        break;
      }
      case ItemKind::Enum: {
        EnumDecl& e = *ast.enums[it.index];
        TypeDeclInfo& d = m_.decls[static_cast<size_t>(e.declId)];
        TypeScope sc{mi, d.params, nullptr};
        for (size_t v = 0; v < e.variants.size(); ++v)
          for (auto& p : e.variants[v].payload) d.variants[v].payload.push_back(resolveType(*p, sc));
        break;
      }
      case ItemKind::Trait: {
        TraitDecl& t = *ast.traits[it.index];
        TraitInfo& ti = m_.traits[static_cast<size_t>(t.traitId)];
        TypeScope sc{mi, {}, A.param(ti.selfParam)};
        for (size_t k = 0; k < t.methods.size(); ++k) {
          FnDecl& f = t.methods[k];
          TraitMethodInfo& tm = ti.methods[k];
          for (Param& p : f.params) tm.params.push_back(resolveType(*p.type, sc));
          tm.ret = f.ret ? resolveType(*f.ret, sc) : A.unitT();
          if (f.funcId >= 0) {
            FuncInfo& fi = m_.funcs[static_cast<size_t>(f.funcId)];
            fi.params = tm.params;
            fi.ret = tm.ret;
            fi.selfType = A.param(ti.selfParam);
          }
        }
        break;
      }
      case ItemKind::Impl: {
        ImplDecl& im = *ast.impls[it.index];
        ImplInfo& ii = m_.impls[static_cast<size_t>(im.implId)];
        resolveBounds(im.generics, ii.tparams, mi);
        ii.trait = resolveTraitRef(im.trait, mi);
        // `Self` inside the head itself is a placeholder; it is rejected as a bad head later.
        TypeParam* placeholder = m_.newParam("Self");
        TypeScope hsc{mi, ii.tparams, A.param(placeholder)};
        ii.head = resolveType(*im.head, hsc);
        ii.ctor = headCtor(prune(ii.head));
        TypeScope sc{mi, ii.tparams, ii.head};
        for (size_t k = 0; k < im.methods.size(); ++k) {
          FnDecl& f = im.methods[k];
          FuncInfo& fi = m_.funcs[static_cast<size_t>(f.funcId)];
          for (Param& p : f.params) fi.params.push_back(resolveType(*p.type, sc));
          fi.ret = f.ret ? resolveType(*f.ret, sc) : A.unitT();
          fi.selfType = ii.head;
        }
        break;
      }
    }
  }
}

// ------------------------------------------------------------ pass 3.5

void Resolver::checkImpl(int mi, ImplDecl& im) {
  (void)mi;
  ImplInfo& ii = m_.impls[static_cast<size_t>(im.implId)];
  if (ii.trait <= kTraitKey) err(ErrorKind::BuiltinTraitImpl, im.pos);
  Type* head = prune(ii.head);
  auto isImplParam = [&](Type* t) {
    t = prune(t);
    return t->kind == TK::Param && std::find(ii.tparams.begin(), ii.tparams.end(), t->param) != ii.tparams.end();
  };
  bool valid = true;
  switch (head->kind) {
    case TK::Int: case TK::Float: case TK::Bool: case TK::Char: case TK::Str: case TK::Unit: break;
    case TK::List: valid = isImplParam(head->args[0]); break;
    case TK::Map:
      valid = isImplParam(head->args[0]) && isImplParam(head->args[1]) &&
              prune(head->args[0])->param != prune(head->args[1])->param;
      break;
    case TK::Named: {
      std::set<TypeParam*> seen;
      for (Type* a : head->args) {
        if (!isImplParam(a)) valid = false;
        else if (!seen.insert(prune(a)->param).second) valid = false;
      }
      break;
    }
    default: valid = false;
  }
  if (!valid) err(ErrorKind::BadImplHead, im.head->pos);
  // every impl parameter must occur in the head
  for (size_t i = 0; i < ii.tparams.size(); ++i) {
    bool found = false;
    for (Type* a : head->args)
      if (prune(a)->param == ii.tparams[i]) found = true;
    if (!found) err(ErrorKind::UnusedParam, im.generics[i].pos);
  }
  auto key = Model::implKey(ii.trait, ii.ctor);
  if (m_.implIndex.count(key)) err(ErrorKind::DupImpl, im.pos);
  m_.implIndex[key] = im.implId;

  TraitInfo& tr = m_.traits[static_cast<size_t>(ii.trait)];
  ii.byTraitMethod.assign(tr.methods.size(), -1);
  for (size_t k = 0; k < tr.methods.size(); ++k) {
    bool defined = false;
    for (FnDecl& f : im.methods)
      if (f.name == tr.methods[k].name) defined = true;
    if (!defined && !tr.methods[k].hasDefault) err(ErrorKind::MissingMethod, im.pos);
  }
  for (size_t k = 0; k < im.methods.size(); ++k) {
    FnDecl& f = im.methods[k];
    int idx = -1;
    for (size_t j = 0; j < tr.methods.size(); ++j)
      if (tr.methods[j].name == f.name) idx = static_cast<int>(j);
    if (idx < 0) err(ErrorKind::ExtraMethod, f.namePos);
    const TraitMethodInfo& tm = tr.methods[static_cast<size_t>(idx)];
    FuncInfo& fi = m_.funcs[static_cast<size_t>(f.funcId)];
    bool ok = tm.params.size() == fi.params.size();
    std::vector<TypeParam*> from = {tr.selfParam};
    std::vector<Type*> to = {ii.head};
    for (size_t p = 0; ok && p < fi.params.size(); ++p)
      ok = unify(m_.types.subst(tm.params[p], from, to), fi.params[p]);
    if (ok) ok = unify(m_.types.subst(tm.ret, from, to), fi.ret);
    if (!ok) err(ErrorKind::SigMismatch, f.namePos);
    ii.byTraitMethod[static_cast<size_t>(idx)] = fi.ast->funcId;
  }
  for (size_t k = 0; k < tr.methods.size(); ++k)
    if (ii.byTraitMethod[k] < 0) ii.byTraitMethod[k] = tr.methods[k].defaultFunc;
}

void Resolver::implChecks(int mi) {
  ModuleAst& ast = m_.mod(mi).ast;
  for (const Item& it : ast.items)
    if (it.kind == ItemKind::Impl) checkImpl(mi, *ast.impls[it.index]);
}

// -------------------------------------------------------------- driver

void Resolver::resolve(std::vector<ModuleSource>& sources, std::vector<ModuleAst>& asts) {
  int n = static_cast<int>(sources.size());
  for (int i = 0; i < n; ++i) {
    m_.modules.emplace_back();
    m_.modules.back().name = sources[static_cast<size_t>(i)].name;
    m_.modules.back().ast = std::move(asts[static_cast<size_t>(i)]);
  }
  // 3.1 declarations
  for (int i = 0; i < n; ++i) declareItems(i);
  // 3.2 imports
  std::unordered_map<std::string, int> byName;
  for (int i = 0; i < n; ++i) byName[m_.modules[static_cast<size_t>(i)].name] = i;
  for (int i = 0; i < n; ++i) {
    ModuleInfo& mod = m_.modules[static_cast<size_t>(i)];
    for (const Item& it : mod.ast.items) {
      if (it.kind != ItemKind::Use) continue;
      UseDecl& u = *mod.ast.uses[it.index];
      auto f = byName.find(u.module);
      if (f == byName.end()) err(ErrorKind::UnknownModule, u.modPos);
      const std::string& bound = u.hasAlias ? u.alias : u.module;
      if (!mod.imports.emplace(bound, f->second).second) err(ErrorKind::DupName, u.hasAlias ? u.aliasPos : u.modPos);
    }
  }
  for (int i = 0; i < n; ++i) {
    ModuleInfo& mod = m_.modules[static_cast<size_t>(i)];
    // own traits (any order), then pub traits of imports by bound name
    for (const Item& it : mod.ast.items)
      if (it.kind == ItemKind::Trait) mod.visibleTraits.push_back(mod.ast.traits[it.index]->traitId);
    std::vector<std::pair<std::string, int>> imps(mod.imports.begin(), mod.imports.end());
    std::sort(imps.begin(), imps.end());
    for (auto& [bound, target] : imps) {
      if (target == i) continue;
      ModuleInfo& other = m_.modules[static_cast<size_t>(target)];
      for (const Item& it : other.ast.items)
        if (it.kind == ItemKind::Trait && other.ast.traits[it.index]->pub)
          mod.visibleTraits.push_back(other.ast.traits[it.index]->traitId);
    }
  }
  // 3.3 internal duplicates
  for (int i = 0; i < n; ++i) internalDups(i);
  // 3.4 signatures
  for (int i = 0; i < n; ++i) signatures(i);
  // 3.5 impls
  for (int i = 0; i < n; ++i) implChecks(i);
  // 3.6 entry point
  auto mainMod = byName.find("main");
  if (mainMod == byName.end()) err(ErrorKind::NoMain, {1, 1});
  ModuleInfo& mm = m_.modules[static_cast<size_t>(mainMod->second)];
  auto mf = mm.values.find("main");
  bool ok = false;
  if (mf != mm.values.end() && mf->second.kind == ValueEntry::K::Func) {
    FuncInfo& fi = m_.funcs[static_cast<size_t>(mf->second.id)];
    ok = fi.tparams.empty() && fi.params.empty() && prune(fi.ret)->kind == TK::Unit;
    if (ok) m_.mainFunc = mf->second.id;
  }
  if (!ok) err(ErrorKind::NoMain, {1, 1});
}

}  // namespace langvm
