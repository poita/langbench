// Cell values: numbers, strings, errors, and "empty".
#pragma once

#include <string>
#include <utility>

namespace spreadsheet {

enum class ErrorCode { DivZero, Ref, Cycle, Value };

/// The display text of an error code, e.g. "#DIV/0!".
const char* error_text(ErrorCode code);

/// Formats a number as the spreadsheet displays it: "0" for zero, plain
/// integers below 1e15, otherwise printf("%.10g").
std::string format_number(double v);

/// A value produced by a cell or an intermediate expression result.
class Value {
 public:
  enum class Kind { Empty, Number, String, Error };

  Value() = default;
  static Value empty() { return Value(); }
  static Value number(double v) {
    Value r;
    r.kind_ = Kind::Number;
    r.num_ = v == 0 ? 0.0 : v;  // normalise -0
    return r;
  }
  static Value string(std::string s) {
    Value r;
    r.kind_ = Kind::String;
    r.str_ = std::move(s);
    return r;
  }
  static Value error(ErrorCode c) {
    Value r;
    r.kind_ = Kind::Error;
    r.err_ = c;
    return r;
  }

  Kind kind() const { return kind_; }
  bool is_empty() const { return kind_ == Kind::Empty; }
  bool is_number() const { return kind_ == Kind::Number; }
  bool is_string() const { return kind_ == Kind::String; }
  bool is_error() const { return kind_ == Kind::Error; }

  double as_number() const { return num_; }
  const std::string& as_string() const { return str_; }
  ErrorCode as_error() const { return err_; }

  /// The text shown for this value ("" for empty). Also the text form used by `&`.
  std::string display() const;

  friend bool operator==(const Value& a, const Value& b);
  friend bool operator!=(const Value& a, const Value& b) { return !(a == b); }

 private:
  Kind kind_ = Kind::Empty;
  double num_ = 0;
  ErrorCode err_ = ErrorCode::Value;
  std::string str_;
};

}  // namespace spreadsheet
