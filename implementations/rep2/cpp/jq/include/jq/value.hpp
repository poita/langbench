// jq/value.hpp -- immutable, cheaply copyable JSON values.
//
// A `Value` is one of null, false, true, number (IEEE-754 double), string
// (UTF-8 bytes), array or object. Strings, arrays and objects live in
// reference-counted heap blocks, so copying a `Value` is O(1) and values can
// be shared freely. Values are immutable once built.
//
// Objects are insertion-ordered maps with expected O(1) key lookup. The key
// order used for sorting/`keys` is computed lazily, at most once per object.
//
// Thread safety: Values may share heap blocks, and the reference counts and
// the lazily built object indexes are not synchronised. Do not share Values
// between threads.
#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <string_view>
#include <unordered_map>
#include <utility>
#include <vector>

namespace jq {

/// Value kinds, declared in jq's sort order (null < false < true < number <
/// string < array < object).
enum class Type : std::uint8_t { Null, False, True, Number, String, Array, Object };

class Value;
class Object;

namespace detail {
struct Heap {
  mutable std::uint32_t refs = 1;
  virtual ~Heap() = default;
};
}  // namespace detail

/// A key/value pair stored in an object.
struct Member;

class Value {
 public:
  /// The null value.
  Value() noexcept : type_(Type::Null), num_(0) {}
  Value(const Value& o) noexcept : type_(o.type_), num_(o.num_) { retain(); }
  Value(Value&& o) noexcept : type_(o.type_), num_(o.num_) { o.type_ = Type::Null; }
  Value& operator=(const Value& o) noexcept {
    if (this != &o) {
      Value tmp(o);
      swap(tmp);
    }
    return *this;
  }
  Value& operator=(Value&& o) noexcept {
    if (this != &o) {
      release();
      type_ = o.type_;
      num_ = o.num_;
      o.type_ = Type::Null;
    }
    return *this;
  }
  ~Value() { release(); }

  static Value null() { return Value(); }
  static Value boolean(bool b) { return Value(b ? Type::True : Type::False); }
  static Value number(double d) {
    Value v(Type::Number);
    v.num_ = d;
    return v;
  }
  static Value string(std::string s);
  static Value array(std::vector<Value> items);
  /// Build an object from members already known to have distinct keys.
  /// Prefer ObjectBuilder, which de-duplicates.
  static Value object(std::vector<Member> members);

  Type type() const noexcept { return type_; }
  bool is_null() const noexcept { return type_ == Type::Null; }
  bool is_boolean() const noexcept { return type_ == Type::True || type_ == Type::False; }
  bool is_number() const noexcept { return type_ == Type::Number; }
  bool is_string() const noexcept { return type_ == Type::String; }
  bool is_array() const noexcept { return type_ == Type::Array; }
  bool is_object() const noexcept { return type_ == Type::Object; }

  /// jq truthiness: everything except `false` and `null` is true.
  bool truthy() const noexcept { return type_ >= Type::True; }

  // Accessors: the caller must check the type first.
  double as_number() const noexcept { return num_; }
  const std::string& as_string() const noexcept;
  const std::vector<Value>& as_array() const noexcept;
  const Object& as_object() const noexcept;

  /// "null", "boolean", "number", "string", "array" or "object".
  const char* type_name() const noexcept;

  void swap(Value& o) noexcept {
    std::swap(type_, o.type_);
    std::swap(num_, o.num_);
  }

 private:
  explicit Value(Type t) noexcept : type_(t), num_(0) {}
  Value(Type t, detail::Heap* h) noexcept : type_(t), heap_(h) {}
  bool has_heap() const noexcept { return type_ >= Type::String; }
  void retain() const noexcept {
    if (has_heap()) ++heap_->refs;
  }
  void release() noexcept {
    if (has_heap() && --heap_->refs == 0) delete heap_;
  }

  Type type_;
  union {
    double num_;
    detail::Heap* heap_;
  };
};

/// A member of an object.
struct Member {
  std::string key;
  Value value;
};

/// An insertion-ordered string-keyed map. Obtain one from `Value::as_object`.
class Object final : public detail::Heap {
 public:
  explicit Object(std::vector<Member> members) : members_(std::move(members)) {}

  std::size_t size() const noexcept { return members_.size(); }
  bool empty() const noexcept { return members_.empty(); }
  /// Members in insertion order.
  const std::vector<Member>& members() const noexcept { return members_; }
  /// Looks up `key`; returns nullptr when absent. Expected O(1).
  const Value* find(std::string_view key) const;
  /// Indices into `members()` ordered by key (code point order). Computed on
  /// first use and cached.
  const std::vector<std::uint32_t>& sorted_order() const;

 private:
  std::vector<Member> members_;
  mutable std::unordered_map<std::string_view, std::uint32_t> index_;
  mutable bool indexed_ = false;
  mutable std::vector<std::uint32_t> sorted_;
  mutable bool sorted_valid_ = false;
};

/// Accumulates members, keeping first-insertion position and last value for
/// repeated keys, then produces an immutable object.
class ObjectBuilder {
 public:
  ObjectBuilder() = default;
  /// Starts from the members of an existing object.
  explicit ObjectBuilder(const Object& base);

  void reserve(std::size_t n) { members_.reserve(n); }
  /// Sets `key` to `value`: replaces in place if present, appends otherwise.
  void set(std::string key, Value value);
  std::size_t size() const noexcept { return members_.size(); }
  Value build();

 private:
  static constexpr std::size_t kIndexThreshold = 12;
  Member* lookup(std::string_view key);
  void build_index();

  std::vector<Member> members_;
  std::unordered_map<std::string, std::uint32_t> index_;
  bool indexed_ = false;
};

/// Three-way comparison in jq's total order: returns <0, 0 or >0.
int compare(const Value& a, const Value& b);

inline bool operator==(const Value& a, const Value& b) { return compare(a, b) == 0; }
inline bool operator!=(const Value& a, const Value& b) { return compare(a, b) != 0; }
inline bool operator<(const Value& a, const Value& b) { return compare(a, b) < 0; }

}  // namespace jq
