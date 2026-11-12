// The semantic model of a program: modules, declarations, traits, impls and
// function signatures, built by the resolver and consumed by the checker.
#pragma once

#include <deque>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

#include "ast.h"
#include "types.h"

namespace langvm {

struct ValueEntry {
  enum class K { Func, Variant } kind = K::Func;
  int id = -1;       // function id, or the enum's declaration id
  int variant = -1;  // variant index
  bool pub = false;
};

struct ModuleInfo {
  std::string name;
  ModuleAst ast;
  std::unordered_map<std::string, int> types;    // name -> declaration id
  std::unordered_map<std::string, int> traits;   // name -> trait id
  std::unordered_map<std::string, ValueEntry> values;
  std::unordered_map<std::string, int> imports;  // bound name -> module index
  // Traits nameable by a qualified `Tr::m`, in priority order (SPEC 5.4).
  std::vector<int> visibleTraits;
};

struct FieldInfo {
  std::string name;
  Pos pos;
  Type* type = nullptr;
};

struct VariantInfo {
  std::string name;
  Pos pos;
  std::vector<Type*> payload;
};

struct TypeDeclInfo {
  bool isEnum = false;
  std::string name;
  int module = -1;  // -1: the prelude
  bool pub = true;
  std::vector<TypeParam*> params;
  std::vector<FieldInfo> fields;      // struct
  std::vector<VariantInfo> variants;  // enum
};

struct TraitMethodInfo {
  std::string name;
  Pos pos;
  std::vector<Type*> params;  // excluding self
  Type* ret = nullptr;
  bool hasDefault = false;
  FnDecl* ast = nullptr;
  int defaultFunc = -1;
};

struct TraitInfo {
  std::string name;
  int module = -1;
  bool pub = true;
  bool builtin = false;
  TypeParam* selfParam = nullptr;  // the rigid `Self` of default bodies
  std::vector<TraitMethodInfo> methods;
  TraitDecl* ast = nullptr;
};

struct FuncInfo {
  enum class Kind { Free, ImplMethod, TraitDefault, Builtin } kind = Kind::Free;
  std::string name;
  FnDecl* ast = nullptr;
  int module = -1;
  std::vector<TypeParam*> tparams;  // own generics (Free)
  std::vector<Type*> params;        // excluding self
  Type* ret = nullptr;
  Type* selfType = nullptr;         // methods: the type of `self`
  int impl = -1;                    // ImplMethod
  int trait = -1;                   // TraitDefault
  int builtin = -1;                 // Builtin: index into the native table
  std::vector<TypeParam*> scopeParams;  // type parameters visible in the body
};

struct ImplInfo {
  int module = -1;
  ImplDecl* ast = nullptr;
  std::vector<TypeParam*> tparams;
  int trait = -1;
  Type* head = nullptr;
  int ctor = -1;
  std::vector<int> methodFuncs;  // per ast->methods
  // Function implementing each trait method (the trait default when absent).
  std::vector<int> byTraitMethod;
};

// Head constructors: 0..5 primitives, 6 List, 7 Map, 8+d the declaration d.
constexpr int kCtorList = 6, kCtorMap = 7, kCtorDeclBase = 8;

struct Model {
  TypeArena types;
  std::deque<TypeParam> typeParams;
  std::deque<TypeDeclInfo> decls;
  std::deque<TraitInfo> traits;
  std::deque<FuncInfo> funcs;
  std::deque<ImplInfo> impls;
  std::deque<LocalVar> locals;
  ModuleInfo prelude;
  std::deque<ModuleInfo> modules;
  std::unordered_map<unsigned long long, int> implIndex;  // (trait, ctor) -> impl id
  int mainFunc = -1;
  int optionDecl = -1, resultDecl = -1;

  ModuleInfo& mod(int i) { return i < 0 ? prelude : modules[static_cast<size_t>(i)]; }

  TypeParam* newParam(const std::string& name) {
    typeParams.emplace_back();
    typeParams.back().name = name;
    return &typeParams.back();
  }
  LocalVar* newLocal(const std::string& name, Type* t, bool isMut, int ownerFn) {
    locals.emplace_back();
    LocalVar& v = locals.back();
    v.name = name;
    v.type = t;
    v.isMut = isMut;
    v.ownerFn = ownerFn;
    return &v;
  }
  static unsigned long long implKey(int trait, int ctor) {
    return (static_cast<unsigned long long>(trait) << 32) | static_cast<unsigned>(ctor);
  }
  const ImplInfo* findImpl(int trait, int ctor) const {
    auto it = implIndex.find(implKey(trait, ctor));
    return it == implIndex.end() ? nullptr : &impls[static_cast<size_t>(it->second)];
  }
};

// The head constructor of a (pruned) type, or -1 for tuples, functions, etc.
int headCtor(const Type* t);

}  // namespace langvm
