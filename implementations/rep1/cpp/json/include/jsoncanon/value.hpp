// The JSON document tree.
#pragma once

#include <cstddef>
#include <string>
#include <string_view>
#include <variant>
#include <vector>

namespace jsoncanon {

class Value;

/// One `key: value` entry of an object.
struct Member;

/// A JSON number kept as text. The parser stores the lexeme in canonical form
/// (see SPEC: the exponent is normalised, everything else is verbatim), so
/// integers of any size and any number of digits are preserved exactly.
struct Number {
  std::string text;
};

enum class Type { Null, Bool, Number, String, Array, Object };

/// A JSON value. Strings are stored decoded, as UTF-8. Objects keep every
/// member, duplicates included, in input order; deduplication and ordering
/// are applied by the serializer.
class Value {
 public:
  using Array = std::vector<Value>;
  using Object = std::vector<Member>;

  Value() noexcept;  // null
  Value(std::nullptr_t) noexcept;
  Value(bool b) noexcept;
  Value(Number n);
  Value(std::string s);
  Value(const char* s);
  Value(Array a);
  Value(Object o);

  Value(const Value&);
  Value(Value&&) noexcept;
  Value& operator=(const Value&);
  Value& operator=(Value&&) noexcept;
  ~Value();

  /// Builds a number value from an already-valid JSON number lexeme.
  static Value number(std::string lexeme);

  Type type() const noexcept;
  bool is_null() const noexcept { return type() == Type::Null; }
  bool is_bool() const noexcept { return type() == Type::Bool; }
  bool is_number() const noexcept { return type() == Type::Number; }
  bool is_string() const noexcept { return type() == Type::String; }
  bool is_array() const noexcept { return type() == Type::Array; }
  bool is_object() const noexcept { return type() == Type::Object; }

  /// Accessors; throw std::bad_variant_access if the type does not match.
  bool as_bool() const;
  const std::string& as_number_text() const;
  const std::string& as_string() const;
  const Array& as_array() const;
  Array& as_array();
  const Object& as_object() const;
  Object& as_object();

 private:
  using Storage = std::variant<std::nullptr_t, bool, Number, std::string, Array, Object>;
  Storage v_;
};

struct Member {
  std::string key;  // decoded, UTF-8
  Value value;
};

}  // namespace jsoncanon
