#pragma once
/// \file value.hpp
/// SQLite storage classes: values, ordering, affinity and text formatting.

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>

namespace sqlitefile {

/// The five SQLite storage classes.
enum class Type { Null, Integer, Real, Text, Blob };

/// A dynamically typed SQLite value.
///
/// TEXT and BLOB values both keep their bytes in a `std::string`; TEXT is
/// expected to be UTF-8 but is never validated.
class Value {
 public:
  Value() = default;
  static Value null() { return Value(); }
  static Value integer(std::int64_t v);
  static Value real(double v);
  static Value text(std::string bytes);
  static Value blob(std::string bytes);

  Type type() const { return type_; }
  bool isNull() const { return type_ == Type::Null; }
  bool isNumber() const { return type_ == Type::Integer || type_ == Type::Real; }

  /// Valid when `type() == Type::Integer`.
  std::int64_t asInteger() const { return int_; }
  /// Valid when `type() == Type::Real`.
  double asReal() const { return real_; }
  /// Valid for `Type::Text` and `Type::Blob`: the raw bytes.
  const std::string& bytes() const { return bytes_; }

  /// Numeric value as a double (INTEGER or REAL only).
  double toDouble() const;

  friend bool operator==(const Value& a, const Value& b);

 private:
  Type type_ = Type::Null;
  std::int64_t int_ = 0;
  double real_ = 0;
  std::string bytes_;
};

/// Three-way comparison implementing the SQLite ordering (NULL < numbers <
/// TEXT < BLOB; numbers by value; TEXT and BLOB by unsigned bytes).
/// Returns a negative number, zero or a positive number.
int compare(const Value& a, const Value& b);

/// Column type affinity, derived from the declared type name.
enum class Affinity { Integer, Text, Blob, Real, Numeric };

/// Applies SQLite's five affinity rules, in order, to a declared type name.
Affinity affinityFromDeclaredType(std::string_view declared_type);

/// Parses text that is entirely a numeric constant (surrounding spaces and
/// tabs allowed; see SPEC.md Part 3). Gives an INTEGER when the text has no
/// '.' or exponent and fits in 64 bits, otherwise a REAL. Returns nullopt
/// when the text is not a numeric constant.
std::optional<Value> parseNumericConstant(std::string_view text);

/// Converts a query literal according to the affinity of the column it is
/// compared against.
Value applyAffinityToLiteral(const Value& literal, Affinity affinity);

/// Formats a REAL like `%.15g`, with ".0" added to a mantissa that has no
/// point and zero printed as `0.0`.
std::string formatReal(double v);

/// Appends the shell-style text form of a value (NULL, decimal, REAL,
/// raw text, uppercase hex for blobs) to `out`.
void appendFormatted(std::string& out, const Value& v);

/// Convenience wrapper around appendFormatted().
std::string format(const Value& v);

}  // namespace sqlitefile
