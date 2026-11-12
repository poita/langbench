/// @file value.hpp
/// Dynamic values used as template variables.
///
/// Values are cheap to copy: strings, lists, dicts and callables are shared
/// immutably, so binding a name, passing an argument or iterating never copies
/// the underlying data.
#pragma once

#include <cstdint>
#include <memory>
#include <string>
#include <string_view>
#include <unordered_map>
#include <utility>
#include <vector>

namespace sitegen {

class Value;
class Dict;

/// A list of values.
using List = std::vector<Value>;

/// Base class of the callable values the template engine itself creates
/// (macros, `range`, `super`). Library users have no reason to subclass it.
struct Callable {
  virtual ~Callable() = default;
};

/// A template value: undefined, none, boolean, integer, float, string, list,
/// dict or callable. A default-constructed value is *undefined*.
class Value {
 public:
  enum class Kind : std::uint8_t { Undefined, None, Bool, Int, Float, String, List, Dict, Callable };

  Value() = default;

  static Value undefined() { return Value(); }
  static Value none();
  static Value boolean(bool b);
  static Value integer(std::int64_t i);
  static Value real(double d);
  static Value string(std::string s);
  static Value list(List items);
  static Value dict(Dict d);
  static Value callable(std::shared_ptr<const Callable> c);

  Kind kind() const { return kind_; }
  bool is_undefined() const { return kind_ == Kind::Undefined; }
  bool is_none() const { return kind_ == Kind::None; }
  bool is_bool() const { return kind_ == Kind::Bool; }
  bool is_int() const { return kind_ == Kind::Int; }
  bool is_float() const { return kind_ == Kind::Float; }
  bool is_string() const { return kind_ == Kind::String; }
  bool is_list() const { return kind_ == Kind::List; }
  bool is_dict() const { return kind_ == Kind::Dict; }
  bool is_callable() const { return kind_ == Kind::Callable; }
  /// Booleans count as numbers, as in Jinja.
  bool is_number() const { return kind_ == Kind::Bool || kind_ == Kind::Int || kind_ == Kind::Float; }

  /// Accessors. The value must have the matching kind.
  bool as_bool() const { return prim_.b; }
  std::int64_t as_int() const { return prim_.i; }
  double as_float() const { return prim_.d; }
  const std::string& as_string() const { return *static_cast<const std::string*>(ptr_.get()); }
  const List& as_list() const { return *static_cast<const List*>(ptr_.get()); }
  const Dict& as_dict() const { return *static_cast<const Dict*>(ptr_.get()); }
  const Callable& as_callable() const { return *static_cast<const Callable*>(ptr_.get()); }

  /// Numeric view of a bool/int/float value.
  double number_as_double() const;

 private:
  Kind kind_ = Kind::Undefined;
  union Prim {
    bool b;
    std::int64_t i;
    double d;
  } prim_{};
  std::shared_ptr<const void> ptr_;
};

/// An insertion-ordered mapping from string keys to values.
class Dict {
 public:
  using Entry = std::pair<std::string, Value>;

  /// Inserts `key`, or replaces its value keeping its original position.
  void set(std::string key, Value value);

  /// The value for `key`, or nullptr.
  const Value* find(std::string_view key) const;

  std::size_t size() const { return entries_.size(); }
  bool empty() const { return entries_.empty(); }
  const std::vector<Entry>& entries() const { return entries_; }

 private:
  struct StringHash {
    using is_transparent = void;
    std::size_t operator()(std::string_view s) const { return std::hash<std::string_view>()(s); }
  };
  static constexpr std::size_t kLinearLimit = 8;
  static constexpr std::size_t kNotFound = static_cast<std::size_t>(-1);

  std::size_t find_index(std::string_view key) const;

  std::vector<Entry> entries_;
  // Built only once the dict outgrows kLinearLimit entries.
  std::unordered_map<std::string, std::size_t, StringHash, std::equal_to<>> index_;
};

/// The string a value prints as in `{{ ... }}`: `True`/`False`, `None`,
/// shortest round-trip floats, Python-style lists and dicts. Undefined values
/// and callables print as the empty string (the engine rejects printing them
/// before it gets here).
std::string to_display_string(const Value& v);

/// Like `to_display_string`, but strings are quoted as Python would.
std::string repr(const Value& v);

/// Template `==`: numbers compare numerically, strings, lists and dicts
/// structurally, `none == none`; anything else is unequal.
bool values_equal(const Value& a, const Value& b);

/// Formats a double as the template language prints it (`3.0`, `1e+16`, ...).
std::string format_float(double d);

}  // namespace sitegen
