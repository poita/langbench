// Semantic types and unification (SPEC.md sections 6 and 9.2).
#pragma once

#include <deque>
#include <memory>
#include <string>
#include <vector>

namespace langvm {

// A generic parameter: rigid inside its declaration, instantiated at call sites.
struct TypeParam {
  std::string name;
  std::vector<int> bounds;  // trait ids (built-in Eq/Ord/Key have ids 0, 1, 2)
};

enum class TK : unsigned char { Int, Float, Bool, Char, Str, Unit, List, Map, Tuple, Fn, Named, Param, Var };

struct Type {
  TK kind = TK::Int;
  int decl = -1;                 // Named: struct/enum declaration id
  TypeParam* param = nullptr;    // Param
  Type* ref = nullptr;           // Var: solution (null while unsolved)
  // List: [elem]; Map: [key, value]; Tuple: components; Named: type arguments;
  // Fn: parameters followed by the return type.
  std::vector<Type*> args;
};

constexpr int kTraitEq = 0, kTraitOrd = 1, kTraitKey = 2;

class TypeArena {
 public:
  TypeArena();
  Type* prim(TK k) { return prims_[static_cast<int>(k)]; }
  Type* intT() { return prim(TK::Int); }
  Type* floatT() { return prim(TK::Float); }
  Type* boolT() { return prim(TK::Bool); }
  Type* charT() { return prim(TK::Char); }
  Type* strT() { return prim(TK::Str); }
  Type* unitT() { return prim(TK::Unit); }
  Type* list(Type* elem);
  Type* map(Type* k, Type* v);
  Type* tuple(std::vector<Type*> comps);
  Type* fn(std::vector<Type*> params, Type* ret);
  Type* named(int decl, std::vector<Type*> args);
  Type* param(TypeParam* p);
  Type* fresh();

  // Replaces each params[i] by args[i] throughout `t`.
  Type* subst(Type* t, const std::vector<TypeParam*>& params, const std::vector<Type*>& args);

 private:
  Type* make(TK k);
  std::deque<Type> store_;
  Type* prims_[6];
};

// Follows solved variables (with path compression).
Type* prune(Type* t);
// SPEC.md 9.2: unification with occurs check; solves variables in place.
bool unify(Type* a, Type* b);
// True iff `t` contains no unsolved variable.
bool isGround(Type* t);
// Number of parameters of a Fn type / its return type.
inline size_t fnArity(const Type* t) { return t->args.size() - 1; }
inline Type* fnRet(const Type* t) { return t->args.back(); }

// Debug rendering of a type.
std::string typeToString(Type* t);

}  // namespace langvm
