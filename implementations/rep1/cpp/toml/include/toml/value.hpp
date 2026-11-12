// toml/value.hpp - the document tree.
#pragma once

#include <cstdint>
#include <map>
#include <stdexcept>
#include <string>
#include <string_view>
#include <variant>
#include <vector>

namespace toml {

/// The type of a scalar value. The names match the `"type"` tags used by the
/// toml-test tagged JSON format (see `type_name`).
enum class Type {
  String,
  Integer,
  Float,
  Bool,
  DateTime,       ///< date, time and UTC offset
  DateTimeLocal,  ///< date and time, no offset
  DateLocal,
  TimeLocal,
};

/// The tagged-JSON name of a type, e.g. "datetime-local".
std::string_view type_name(Type type);

/// Inverse of `type_name`; returns false when `name` is not a type name.
bool type_from_name(std::string_view name, Type& out);

/// How a table (or array) came into existence. The parser uses this to enforce
/// the TOML redefinition rules; it is also exposed for inspection.
enum class Origin {
  Literal,        ///< scalars and array literals (the default)
  Implicit,       ///< created as an intermediate segment of a header
  Explicit,       ///< opened by a [header] line (or built programmatically)
  Dotted,         ///< created by an intermediate segment of a dotted key
  Inline,         ///< an inline table literal `{ ... }`
  ArrayOfTables,  ///< an array created by [[header]] lines
};

/// Thrown by the typed accessors when a value has a different type.
class TypeError : public std::logic_error {
 public:
  using std::logic_error::logic_error;
};

/// A node of a TOML document: a scalar, an array or a table.
///
/// Scalars are stored as their *canonical text* (e.g. a float is kept as
/// "1.0000000000000000e+00"); the `as_*` accessors convert on demand. Tables
/// keep their keys sorted by byte order, which for UTF-8 equals code point
/// order.
class Value {
 public:
  using Array = std::vector<Value>;
  using Table = std::map<std::string, Value, std::less<>>;
  enum class Kind { Scalar, Array, Table };

  /// Creates an empty table.
  Value() : data_(Table{}), origin_(Origin::Explicit) {}

  static Value scalar(Type type, std::string text);
  static Value string(std::string text) { return scalar(Type::String, std::move(text)); }
  static Value integer(std::int64_t v);
  static Value boolean(bool v) { return scalar(Type::Bool, v ? "true" : "false"); }
  static Value array(Array items = {}, Origin origin = Origin::Literal);
  static Value table(Table members = {}, Origin origin = Origin::Explicit);

  Kind kind() const;
  bool is_scalar() const { return kind() == Kind::Scalar; }
  bool is_array() const { return kind() == Kind::Array; }
  bool is_table() const { return kind() == Kind::Table; }
  Origin origin() const { return origin_; }
  void set_origin(Origin o) { origin_ = o; }

  /// Scalar accessors. These throw `TypeError` unless the value is a scalar
  /// of the matching type.
  Type type() const;
  const std::string& text() const;
  const std::string& as_string() const;
  std::int64_t as_integer() const;
  double as_float() const;
  bool as_bool() const;

  /// Container accessors; throw `TypeError` on a kind mismatch.
  const Array& items() const;
  Array& items();
  const Table& members() const;
  Table& members();

  /// Table lookup; nullptr when this is not a table or has no such key.
  const Value* find(std::string_view key) const;

  /// Structural equality. Origins are ignored.
  friend bool operator==(const Value& a, const Value& b) { return a.data_ == b.data_; }
  friend bool operator!=(const Value& a, const Value& b) { return !(a == b); }

 private:
  struct Scalar {
    Type type;
    std::string text;
    friend bool operator==(const Scalar& a, const Scalar& b) {
      return a.type == b.type && a.text == b.text;
    }
  };
  std::variant<Scalar, Array, Table> data_;
  Origin origin_ = Origin::Literal;
};

}  // namespace toml
