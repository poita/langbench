// KBL runtime values: bool, int, str, list. Copying is O(1).
#pragma once

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace kiln {

enum class Type { Bool, Int, Str, List };

/// "bool", "int", "str" or "list".
const char* typeName(Type t) noexcept;

/// Bit masks of accepted types, used by type checks.
enum TypeMask : unsigned { kBool = 1, kInt = 2, kStr = 4, kList = 8, kAny = 15 };

/// The mask bit of a type.
unsigned maskOf(Type t) noexcept;

/// Renders a mask as SPEC's expected-type token: `str`, `str|list`, ...
std::string maskName(unsigned mask);

/// An immutable KBL value. Strings and lists are reference counted, so copying
/// a `Value` never copies its payload.
class Value {
 public:
  using List = std::vector<Value>;

  Value() noexcept : type_(Type::Bool), i_(0) {}

  static Value boolean(bool b) noexcept;
  static Value integer(std::int64_t i) noexcept;
  static Value string(std::string s);
  static Value list(List items);

  Type type() const noexcept { return type_; }
  bool isStr() const noexcept { return type_ == Type::Str; }
  bool isInt() const noexcept { return type_ == Type::Int; }
  bool isBool() const noexcept { return type_ == Type::Bool; }
  bool isList() const noexcept { return type_ == Type::List; }

  bool asBool() const noexcept { return i_ != 0; }
  std::int64_t asInt() const noexcept { return i_; }
  const std::string& asStr() const noexcept {
    return *static_cast<const std::string*>(p_.get());
  }
  const List& asList() const noexcept {
    return *static_cast<const List*>(p_.get());
  }

 private:
  Type type_;
  std::int64_t i_;
  std::shared_ptr<const void> p_;
};

/// The total order of SPEC "The total order": negative, zero or positive.
int compare(const Value& a, const Value& b);

/// Deep structural equality.
bool equal(const Value& a, const Value& b);

/// A hash consistent with `equal`.
std::size_t hashValue(const Value& v);

/// Text of an `int`/`bool`/`str` as produced by interpolation and `str()`.
/// Must not be called with a list.
std::string toText(const Value& v);

}  // namespace kiln
