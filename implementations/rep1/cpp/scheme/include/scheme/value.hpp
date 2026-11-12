/// \file value.hpp
/// Runtime values, heap objects and the symbol table.
///
/// Memory is managed by intrusive reference counting. Reference cycles
/// (a closure stored in the frame it closes over) are not collected; they live
/// until the owning Interpreter is destroyed (or, for cycles, until exit).
/// Values must not outlive the Interpreter that created them.
#pragma once

#include <cstdint>
#include <memory>
#include <string>
#include <string_view>
#include <unordered_map>
#include <utility>
#include <vector>

#include "scheme/bigint.hpp"

namespace scheme {

struct LambdaNode;  // see ast.hpp
class Interpreter;
class Value;

enum class ObjectKind : uint8_t { BigInt, String, Symbol, Pair, Closure, Primitive, Frame };

/// Base class of all reference-counted heap objects.
class Object {
 public:
  explicit Object(ObjectKind kind) : kind_(kind) {}
  Object(const Object&) = delete;
  Object& operator=(const Object&) = delete;
  virtual ~Object() = default;

  ObjectKind kind() const { return kind_; }
  void retain() { ++refs_; }
  void release() {
    if (--refs_ == 0) dispose(this);
  }

 private:
  /// Destroys `o`. Nested destruction is queued, so freeing a very long list
  /// uses constant native stack.
  static void dispose(Object* o);

  size_t refs_ = 0;
  ObjectKind kind_;
};

/// Intrusive smart pointer to an Object subclass.
template <class T>
class Ref {
 public:
  Ref() = default;
  Ref(T* p) : p_(p) {  // NOLINT: implicit by design
    if (p_) p_->retain();
  }
  Ref(const Ref& o) : p_(o.p_) {
    if (p_) p_->retain();
  }
  Ref(Ref&& o) noexcept : p_(o.p_) { o.p_ = nullptr; }
  Ref& operator=(Ref o) noexcept {
    std::swap(p_, o.p_);
    return *this;
  }
  ~Ref() {
    if (p_) p_->release();
  }
  T* get() const { return p_; }
  T* operator->() const { return p_; }
  T& operator*() const { return *p_; }
  explicit operator bool() const { return p_ != nullptr; }

 private:
  T* p_ = nullptr;
};

/// A Scheme value: an immediate (void, (), booleans, 64-bit integers) or a
/// counted reference to a heap object.
class Value {
 public:
  enum class Tag : uint8_t { Void, Null, False, True, Int, Object };

  Value() : tag_(Tag::Void) { u_.i = 0; }
  Value(const Value& o) : tag_(o.tag_), u_(o.u_) {
    if (tag_ == Tag::Object) u_.o->retain();
  }
  Value(Value&& o) noexcept : tag_(o.tag_), u_(o.u_) { o.tag_ = Tag::Void; }
  Value& operator=(const Value& o) {
    Value tmp(o);
    swap(tmp);
    return *this;
  }
  Value& operator=(Value&& o) noexcept {
    Value tmp(std::move(o));
    swap(tmp);
    return *this;
  }
  ~Value() {
    if (tag_ == Tag::Object) u_.o->release();
  }
  void swap(Value& o) noexcept {
    std::swap(tag_, o.tag_);
    std::swap(u_, o.u_);
  }

  /// Wrap a heap object (takes a new reference).
  explicit Value(Object* o) : tag_(Tag::Object) {
    u_.o = o;
    o->retain();
  }
  template <class T>
  explicit Value(const Ref<T>& r) : Value(static_cast<Object*>(r.get())) {}

  static Value void_value() { return Value(); }
  static Value null() {
    Value v;
    v.tag_ = Tag::Null;
    return v;
  }
  static Value boolean(bool b) {
    Value v;
    v.tag_ = b ? Tag::True : Tag::False;
    return v;
  }
  static Value integer(int64_t i) {
    Value v;
    v.tag_ = Tag::Int;
    v.u_.i = i;
    return v;
  }

  Tag tag() const { return tag_; }
  bool is_void() const { return tag_ == Tag::Void; }
  bool is_null() const { return tag_ == Tag::Null; }
  bool is_bool() const { return tag_ == Tag::True || tag_ == Tag::False; }
  /// Everything except `#f` is true.
  bool truthy() const { return tag_ != Tag::False; }
  bool is_fixnum() const { return tag_ == Tag::Int; }
  int64_t as_fixnum() const { return u_.i; }
  bool is_object() const { return tag_ == Tag::Object; }
  Object* object() const { return u_.o; }
  bool is_kind(ObjectKind k) const { return tag_ == Tag::Object && u_.o->kind() == k; }

  bool is_bigint() const { return is_kind(ObjectKind::BigInt); }
  bool is_integer() const { return is_fixnum() || is_bigint(); }
  bool is_string() const { return is_kind(ObjectKind::String); }
  bool is_symbol() const { return is_kind(ObjectKind::Symbol); }
  bool is_pair() const { return is_kind(ObjectKind::Pair); }
  bool is_closure() const { return is_kind(ObjectKind::Closure); }
  bool is_primitive() const { return is_kind(ObjectKind::Primitive); }
  bool is_procedure() const { return is_closure() || is_primitive(); }

  /// Downcast to the object type; the caller must have checked the kind.
  template <class T>
  T* as() const {
    return static_cast<T*>(u_.o);
  }

 private:
  Tag tag_;
  union {
    int64_t i;
    Object* o;
  } u_;
};

class BigIntObject : public Object {
 public:
  explicit BigIntObject(BigInt v) : Object(ObjectKind::BigInt), value(std::move(v)) {}
  BigInt value;
};

class String : public Object {
 public:
  explicit String(std::string s) : Object(ObjectKind::String), value(std::move(s)) {}
  std::string value;
};

/// An interned symbol. Also holds the symbol's global binding.
class Symbol : public Object {
 public:
  explicit Symbol(std::string n) : Object(ObjectKind::Symbol), name(std::move(n)) {}
  std::string name;
  Value global;
  bool bound = false;
};

class Pair : public Object {
 public:
  Pair(Value a, Value d) : Object(ObjectKind::Pair), car(std::move(a)), cdr(std::move(d)) {}
  Value car, cdr;
};

/// One variable binding of a Frame.
struct Binding {
  Symbol* sym;
  Value val;
};

/// An environment frame: a small association list plus the enclosing frame.
/// The global environment is represented by a null frame (globals live in the
/// Symbol objects).
class Frame : public Object {
 public:
  explicit Frame(Ref<Frame> p) : Object(ObjectKind::Frame), parent(std::move(p)) {}
  Ref<Frame> parent;
  std::vector<Binding> bindings;

  Value* find(const Symbol* s) {
    for (auto& b : bindings)
      if (b.sym == s) return &b.val;
    return nullptr;
  }
  /// Bind or rebind `s` in this frame.
  void define(Symbol* s, Value v) {
    if (Value* slot = find(s))
      *slot = std::move(v);
    else
      bindings.push_back(Binding{s, std::move(v)});
  }
};

class Closure : public Object {
 public:
  Closure(const LambdaNode* l, Ref<Frame> e) : Object(ObjectKind::Closure), lambda(l), env(std::move(e)) {}
  const LambdaNode* lambda;  // owned by the Interpreter's analyzer
  Ref<Frame> env;
};

/// Native procedure signature. Arity has been checked before the call.
using PrimitiveFn = Value (*)(Interpreter&, Value* args, size_t nargs);

class Primitive : public Object {
 public:
  Primitive(const char* n, int lo, int hi, PrimitiveFn f)
      : Object(ObjectKind::Primitive), name(n), min_args(lo), max_args(hi), fn(f) {}
  const char* name;
  int min_args;
  int max_args;  ///< -1: any number
  PrimitiveFn fn;
  bool is_apply = false;  ///< `apply` is evaluated by the interpreter loop (tail call)
};

/// Interns symbols; owns them.
class SymbolTable {
 public:
  SymbolTable() = default;
  SymbolTable(const SymbolTable&) = delete;
  SymbolTable& operator=(const SymbolTable&) = delete;
  ~SymbolTable();

  Symbol* intern(std::string_view name);

 private:
  std::unordered_map<std::string, Symbol*> table_;
};

// ---- construction helpers --------------------------------------------------

inline Value make_pair(Value a, Value d) { return Value(new Pair(std::move(a), std::move(d))); }
inline Value make_string(std::string s) { return Value(new String(std::move(s))); }
inline Value make_symbol_value(Symbol* s) { return Value(static_cast<Object*>(s)); }

/// Build a proper list from `items`.
Value make_list(std::vector<Value> items);
/// Flatten a proper list into a vector; returns false (and leaves `out`
/// unspecified) if `list` is not a proper list.
bool list_to_vector(const Value& list, std::vector<Value>& out);

/// `eq?` semantics: numeric equality for integers, identity otherwise.
bool is_eq(const Value& a, const Value& b);
/// `equal?` semantics: structural on pairs and strings.
bool is_equal(const Value& a, const Value& b);

}  // namespace scheme
