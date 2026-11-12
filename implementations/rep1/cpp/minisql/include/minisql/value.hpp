/// @file value.hpp
/// @brief Dynamically typed SQL values and their total order.
#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace minisql {

/// A SQL value: NULL, a 64-bit INTEGER, TEXT (UTF-8), or a REAL.
///
/// REAL values only arise from `AVG`; they are stored as a number of
/// hundredths (the result is always rounded to two decimals).
class Value {
 public:
  enum class Kind : std::uint8_t { Null, Integer, Text, Real };

  /// Constructs NULL.
  Value() = default;

  static Value null() { return Value(); }
  static Value integer(std::int64_t v);
  static Value text(std::string s);
  /// A REAL equal to `hundredths / 100`.
  static Value real_from_hundredths(std::int64_t hundredths);

  Kind kind() const noexcept { return kind_; }
  bool is_null() const noexcept { return kind_ == Kind::Null; }
  bool is_integer() const noexcept { return kind_ == Kind::Integer; }
  bool is_text() const noexcept { return kind_ == Kind::Text; }
  bool is_real() const noexcept { return kind_ == Kind::Real; }
  bool is_number() const noexcept {
    return kind_ == Kind::Integer || kind_ == Kind::Real;
  }

  /// Valid when `is_integer()`.
  std::int64_t as_integer() const noexcept { return num_; }
  /// Valid when `is_text()`.
  const std::string& as_text() const noexcept { return text_; }
  /// Valid when `is_real()`.
  std::int64_t as_hundredths() const noexcept { return num_; }

 private:
  Kind kind_ = Kind::Null;
  std::int64_t num_ = 0;
  std::string text_;
};

/// A table row.
using Row = std::vector<Value>;

/// Three-way comparison implementing the engine's total order: NULL is
/// smallest; numbers (INTEGER/REAL compared by value) precede all TEXT; TEXT
/// compares bytewise (= by code point for UTF-8). Returns <0, 0 or >0.
int compare(const Value& a, const Value& b);

/// Output format: `NULL`, decimal integers, raw text, reals with exactly two
/// decimals.
std::string to_string(const Value& v);

}  // namespace minisql
