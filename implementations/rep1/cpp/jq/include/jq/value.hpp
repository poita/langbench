// Immutable, cheaply copyable JSON values.
//
// A `Value` is null, false, true, a number (double), a string, an array or an
// object. Strings, arrays and objects live in reference-counted immutable
// storage, so copying a `Value` is O(1) and values are shared, never
// deep-copied. Objects preserve insertion order and offer expected O(1)
// lookup; the sorted key order is computed lazily, at most once per object.
//
// Thread safety: a Value may be read concurrently, except that the lazily
// built lookup index / sorted-key cache of an Object is not synchronised.
// Share a Value between threads only after it has been "warmed up" or guard
// it externally.
#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

namespace jq {

/// Value kinds, declared in jq's sort order: null < false < true < numbers <
/// strings < arrays < objects.
enum class Type : std::uint8_t { Null, False, True, Number, String, Array, Object };

/// jq's name for a type: "null", "boolean", "number", "string", "array" or "object".
const char* type_name(Type t) noexcept;

class Object;

class Value {
 public:
  using Array = std::vector<Value>;

  /// Constructs `null`.
  Value() noexcept : type_(Type::Null) {}

  static Value null() noexcept { return Value(); }
  static Value boolean(bool b) noexcept {
    Value v;
    v.type_ = b ? Type::True : Type::False;
    return v;
  }
  static Value number(double d) noexcept {
    Value v;
    v.type_ = Type::Number;
    v.num_ = d;
    return v;
  }
  static Value string(std::string s);
  static Value array(Array items);
  static Value object(Object obj);

  Type type() const noexcept { return type_; }
  const char* type_name() const noexcept { return jq::type_name(type_); }

  bool is_null() const noexcept { return type_ == Type::Null; }
  bool is_boolean() const noexcept { return type_ == Type::False || type_ == Type::True; }
  bool is_number() const noexcept { return type_ == Type::Number; }
  bool is_string() const noexcept { return type_ == Type::String; }
  bool is_array() const noexcept { return type_ == Type::Array; }
  bool is_object() const noexcept { return type_ == Type::Object; }

  /// jq truthiness: everything except `false` and `null` is true.
  bool truthy() const noexcept { return type_ != Type::Null && type_ != Type::False; }

  /// Accessors; the caller must have checked the type first.
  double number() const noexcept { return num_; }
  const std::string& string() const noexcept {
    return *static_cast<const std::string*>(ptr_.get());
  }
  const Array& array() const noexcept { return *static_cast<const Array*>(ptr_.get()); }
  inline const Object& object() const noexcept;

 private:
  Type type_;
  double num_ = 0;
  std::shared_ptr<const void> ptr_;
};

/// Total order over values (see SPEC: null < false < true < numbers < strings
/// < arrays < objects; objects compare by sorted key list, then by values in
/// sorted key order). Returns <0, 0 or >0.
int compare(const Value& a, const Value& b);

inline bool operator==(const Value& a, const Value& b) { return compare(a, b) == 0; }
inline bool operator!=(const Value& a, const Value& b) { return compare(a, b) != 0; }
inline bool operator<(const Value& a, const Value& b) { return compare(a, b) < 0; }

/// An insertion-ordered string-keyed map. Immutable once wrapped in a Value;
/// build one with ObjectBuilder.
class Object {
 public:
  struct Entry {
    std::string key;
    Value value;
  };
  using const_iterator = std::vector<Entry>::const_iterator;

  std::size_t size() const noexcept { return entries_.size(); }
  bool empty() const noexcept { return entries_.empty(); }
  const Entry& entry(std::size_t i) const noexcept { return entries_[i]; }
  const_iterator begin() const noexcept { return entries_.begin(); }
  const_iterator end() const noexcept { return entries_.end(); }

  /// Expected O(1) lookup (linear scan for very small objects). Null if absent.
  const Value* find(std::string_view key) const;
  bool contains(std::string_view key) const { return find(key) != nullptr; }

  /// Entry indices ordered by key (code point order). Computed on first use
  /// and cached for the lifetime of the object.
  const std::vector<std::uint32_t>& sorted_order() const;

  /// The keys in sorted order.
  std::vector<std::string> sorted_keys() const;

 private:
  friend class ObjectBuilder;
  static constexpr std::size_t kLinearLimit = 8;
  static constexpr std::uint32_t kEmpty = 0xffffffffu;

  long index_of(std::string_view key) const;
  void rebuild_table() const;
  void table_insert(std::uint32_t entry_index) const;

  std::vector<Entry> entries_;
  mutable std::vector<std::uint32_t> table_;   // open-addressing index, lazy
  mutable std::vector<std::uint32_t> sorted_;  // sorted entry indices, lazy
  mutable bool sorted_ready_ = false;
};

/// Builds an Object. `set` on an existing key replaces the value and keeps
/// the key's position; a new key is appended.
class ObjectBuilder {
 public:
  ObjectBuilder() = default;
  /// Starts from a copy of `base` (O(|base|)).
  explicit ObjectBuilder(const Object& base);

  void reserve(std::size_t n) { obj_.entries_.reserve(n); }
  void set(std::string_view key, Value value);
  const Value* find(std::string_view key) const { return obj_.find(key); }
  std::size_t size() const noexcept { return obj_.size(); }

  /// Finishes the object. The builder is left empty.
  Object build();
  Value build_value() { return Value::object(build()); }

 private:
  Object obj_;
};

inline const Object& Value::object() const noexcept {
  return *static_cast<const Object*>(ptr_.get());
}

}  // namespace jq
