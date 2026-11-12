// Runtime values of the VM: scalars inline, everything else reference counted.
#pragma once

#include <cstdint>
#include <cstdlib>
#include <new>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

namespace langvm {

enum class VT : uint8_t { Unit, Bool, Int, Char, Float, Str, List, Map, Tuple, Struct, Enum, Closure };

struct Obj {
  uint32_t rc = 0;
  VT kind = VT::Str;
};

void objFree(Obj* o);  // called when the count reaches zero (iterative; see value.cpp)

class Value {
 public:
  VT t = VT::Unit;
  uint8_t variant = 0;  // Enum: variant index
  uint32_t decl = 0;    // Struct / Enum: declaration id
  union {
    int64_t i;
    double f;
    Obj* o;
  } u;

  Value() noexcept { u.i = 0; }
  Value(const Value& v) noexcept : t(v.t), variant(v.variant), decl(v.decl), u(v.u) {
    if (isRef()) ++u.o->rc;
  }
  Value(Value&& v) noexcept : t(v.t), variant(v.variant), decl(v.decl), u(v.u) {
    v.t = VT::Unit;
    v.u.i = 0;
  }
  Value& operator=(const Value& v) noexcept {
    if (this != &v) {
      Value tmp(v);
      swap(tmp);
    }
    return *this;
  }
  Value& operator=(Value&& v) noexcept {
    if (this != &v) {
      Value tmp(std::move(v));
      swap(tmp);
    }
    return *this;
  }
  ~Value() {
    if (isRef() && --u.o->rc == 0) objFree(u.o);
  }
  void swap(Value& v) noexcept {
    std::swap(t, v.t);
    std::swap(variant, v.variant);
    std::swap(decl, v.decl);
    std::swap(u, v.u);
  }

  bool isRef() const { return t >= VT::Str && u.o != nullptr; }

  static Value ofInt(int64_t x) { Value v; v.t = VT::Int; v.u.i = x; return v; }
  static Value ofFloat(double x) { Value v; v.t = VT::Float; v.u.f = x; return v; }
  static Value ofBool(bool x) { Value v; v.t = VT::Bool; v.u.i = x; return v; }
  static Value ofChar(char32_t x) { Value v; v.t = VT::Char; v.u.i = x; return v; }
  static Value unit() { return Value(); }

  int64_t asInt() const { return u.i; }
  double asFloat() const { return u.f; }
  bool asBool() const { return u.i != 0; }
  char32_t asChar() const { return static_cast<char32_t>(u.i); }
};

struct StrObj : Obj {
  std::u32string s;
};

struct ListObj : Obj {
  std::vector<Value> v;
};

// Fixed-size sequence of values: tuples, struct instances, enum payloads, closures
// (aux = function index).
struct alignas(8) ArrObj : Obj {
  uint32_t n = 0;
  int32_t aux = 0;
  Value* items() { return reinterpret_cast<Value*>(this + 1); }
  const Value* items() const { return reinterpret_cast<const Value*>(this + 1); }
};

struct KeyHash {
  size_t operator()(const Value& v) const;
};
struct KeyEq {
  bool operator()(const Value& a, const Value& b) const;
};

// Insertion-ordered hash map with tombstones (compacted when sparse).
struct MapObj : Obj {
  struct Entry {
    Value k, v;
    bool live = false;
  };
  std::vector<Entry> entries;
  std::unordered_map<Value, uint32_t, KeyHash, KeyEq> index;

  size_t size() const { return index.size(); }
  Value* find(const Value& k);
  void set(const Value& k, const Value& v);
  bool erase(const Value& k);
  void clear();
  void compact();
};

Value newStr(std::u32string s);
Value newList(std::vector<Value> v = {});
Value newMap();
// An ArrObj-backed value (Tuple / Struct / Enum payload / Closure) with `n` unit slots.
Value newArr(VT kind, uint32_t n, uint32_t decl = 0, uint8_t variant = 0, int32_t aux = 0);

inline const std::u32string& strOf(const Value& v) { return static_cast<const StrObj*>(v.u.o)->s; }
inline std::vector<Value>& listOf(const Value& v) { return static_cast<ListObj*>(v.u.o)->v; }
inline MapObj& mapOf(const Value& v) { return *static_cast<MapObj*>(v.u.o); }
inline ArrObj& arrOf(const Value& v) { return *static_cast<ArrObj*>(v.u.o); }

// Head-constructor id of a value for impl dispatch (SPEC 8.6); -1 if none.
int valueCtor(const Value& v);

// Structural equality (SPEC 10.4).
bool valuesEqual(const Value& a, const Value& b);

}  // namespace langvm
