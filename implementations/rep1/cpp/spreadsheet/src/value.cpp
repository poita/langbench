#include "spreadsheet/value.h"

#include <cmath>
#include <cstdio>

namespace spreadsheet {

const char* error_text(ErrorCode code) {
  switch (code) {
    case ErrorCode::DivZero: return "#DIV/0!";
    case ErrorCode::Ref: return "#REF!";
    case ErrorCode::Cycle: return "#CYCLE!";
    case ErrorCode::Value: return "#VALUE!";
  }
  return "#VALUE!";
}

std::string format_number(double v) {
  if (v == 0) return "0";
  char buf[64];
  if (v == std::floor(v) && std::fabs(v) < 1e15) {
    std::snprintf(buf, sizeof buf, "%lld", static_cast<long long>(v));
  } else {
    std::snprintf(buf, sizeof buf, "%.10g", v);
  }
  return buf;
}

std::string Value::display() const {
  switch (kind_) {
    case Kind::Empty: return std::string();
    case Kind::Number: return format_number(num_);
    case Kind::String: return str_;
    case Kind::Error: return error_text(err_);
  }
  return std::string();
}

bool operator==(const Value& a, const Value& b) {
  if (a.kind_ != b.kind_) return false;
  switch (a.kind_) {
    case Value::Kind::Empty: return true;
    case Value::Kind::Number: return a.num_ == b.num_;
    case Value::Kind::String: return a.str_ == b.str_;
    case Value::Kind::Error: return a.err_ == b.err_;
  }
  return false;
}

}  // namespace spreadsheet
