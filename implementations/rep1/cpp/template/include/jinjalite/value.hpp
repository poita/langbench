#pragma once
/// \file value.hpp
/// The dynamic value type of the template language.
///
/// Values are cheap to copy: strings, lists, dicts and callables are held by
/// `shared_ptr` to immutable data, so binding, passing and returning a value
/// never copies its contents.

#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <string_view>
#include <unordered_map>
#include <utility>
#include <variant>
#include <vector>

namespace jinjalite {

class Value;
class Dict;
class Callable;
class Interpreter;

using List = std::vector<Value>;
using ListPtr = std::shared_ptr<const List>;
using DictPtr = std::shared_ptr<const Dict>;
using CallablePtr = std::shared_ptr<const Callable>;

/// A template value: undefined, none, bool, integer, float, string, list,
/// dict or callable (macro / builtin).
class Value {
 public:
  /// Order matches the alternatives of the internal variant.
  enum class Kind { Undefined, None, Bool, Int, Float, String, List, Dict, Callable };

  /// A default-constructed value is the *undefined* value.
  Value() = default;

  static Value undefined() { return Value(); }
  static Value none() { return Value(std::in_place_index<1>, NoneTag{}); }
  static Value boolean(bool b) { return Value(std::in_place_index<2>, b); }
  static Value integer(int64_t i) { return Value(std::in_place_index<3>, i); }
  static Value real(double d) { return Value(std::in_place_index<4>, d); }
  static Value string(std::string s) {
    return Value(std::in_place_index<5>, std::make_shared<const std::string>(std::move(s)));
  }
  static Value list(List items) {
    return Value(std::in_place_index<6>, std::make_shared<const List>(std::move(items)));
  }
  static Value list(ListPtr items) { return Value(std::in_place_index<6>, std::move(items)); }
  static Value dict(DictPtr d) { return Value(std::in_place_index<7>, std::move(d)); }
  static Value callable(CallablePtr c) { return Value(std::in_place_index<8>, std::move(c)); }

  Kind kind() const noexcept { return static_cast<Kind>(data_.index()); }
  bool is_undefined() const noexcept { return data_.index() == 0; }
  bool is_none() const noexcept { return data_.index() == 1; }
  bool is_bool() const noexcept { return data_.index() == 2; }
  bool is_int() const noexcept { return data_.index() == 3; }
  bool is_float() const noexcept { return data_.index() == 4; }
  bool is_string() const noexcept { return data_.index() == 5; }
  bool is_list() const noexcept { return data_.index() == 6; }
  bool is_dict() const noexcept { return data_.index() == 7; }
  bool is_callable() const noexcept { return data_.index() == 8; }
  /// Booleans are integers for every purpose except printing.
  bool is_integral() const noexcept { return is_bool() || is_int(); }
  /// Integer, float or boolean.
  bool is_number() const noexcept { return is_integral() || is_float(); }

  // Accessors: the caller must have checked the kind.
  bool as_bool() const { return std::get<2>(data_); }
  int64_t as_int() const { return std::get<3>(data_); }
  double as_float() const { return std::get<4>(data_); }
  const std::string& as_string() const { return *std::get<5>(data_); }
  const ListPtr& list_ptr() const { return std::get<6>(data_); }
  const List& as_list() const { return *std::get<6>(data_); }
  const DictPtr& dict_ptr() const { return std::get<7>(data_); }
  const Dict& as_dict() const { return *std::get<7>(data_); }
  const Callable& as_callable() const { return *std::get<8>(data_); }

  /// Integral value of an Int or Bool.
  int64_t integral() const { return is_bool() ? (as_bool() ? 1 : 0) : as_int(); }
  /// Numeric value of any number as a double.
  double number() const { return is_float() ? as_float() : static_cast<double>(integral()); }

 private:
  struct NoneTag {};
  using Data = std::variant<std::monostate, NoneTag, bool, int64_t, double,
                            std::shared_ptr<const std::string>, ListPtr, DictPtr, CallablePtr>;
  template <typename... A>
  explicit Value(A&&... a) : data_(std::forward<A>(a)...) {}
  Data data_;
};

/// An insertion-ordered string-keyed dictionary. Lookup is expected O(1).
class Dict {
 public:
  using Entry = std::pair<std::string, Value>;

  /// Appends `key` (or overwrites its value if it already exists).
  void set(std::string key, Value value);
  /// The value stored under `key`, or nullptr.
  const Value* find(std::string_view key) const;
  size_t size() const noexcept { return entries_.size(); }
  const std::vector<Entry>& entries() const noexcept { return entries_; }

 private:
  struct Hash {
    using is_transparent = void;
    size_t operator()(std::string_view s) const noexcept { return std::hash<std::string_view>{}(s); }
  };
  static constexpr size_t kLinearLimit = 8;
  std::vector<Entry> entries_;
  std::unordered_map<std::string, size_t, Hash, std::equal_to<>> index_;
};

/// Arguments of a call: positional values, then keyword values.
struct CallArgs {
  std::vector<Value> positional;
  std::vector<std::pair<std::string, Value>> keyword;
};

/// Anything callable from a template: macros, `range`, `super`.
class Callable {
 public:
  virtual ~Callable() = default;
  virtual Value call(Interpreter& interp, CallArgs&& args) const = 0;
};

}  // namespace jinjalite
