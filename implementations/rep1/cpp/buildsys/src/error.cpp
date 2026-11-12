#include "kiln/error.hpp"

#include <array>

namespace kiln {

namespace {
constexpr std::array<std::string_view, 30> kNames = {
    "E_PARSE",         "E_UNKNOWN_VAR",    "E_REDEFINE",     "E_SET_UNDEFINED",
    "E_TYPE",          "E_ARITY",          "E_UNKNOWN_FUNC", "E_UNKNOWN_RULE",
    "E_UNKNOWN_CMD",   "E_ARG",            "E_INCLUDE_MISSING", "E_INCLUDE_CYCLE",
    "E_BAD_PATH",      "E_OUTPUT_PATH",    "E_STEP_FIELD",   "E_CMD_SHAPE",
    "E_DUP_OUTPUT",    "E_DUP_PHONY",      "E_MISSING_INPUT", "E_UNKNOWN_TARGET",
    "E_CYCLE",         "E_NO_DEFAULT",     "E_RULE_RECURSION", "E_DIV_ZERO",
    "E_INTERP",        "E_ABORT",          "E_NO_BUILD_FILE", "E_NEED_PATH",
    "E_NEED_MISSING",  "E_NEED_CYCLE",
};
}  // namespace

std::string_view kind_name(ErrorKind kind) noexcept {
  return kNames[static_cast<std::size_t>(kind)];
}

bool kind_has_detail(ErrorKind kind) noexcept {
  return kind != ErrorKind::NoDefault && kind != ErrorKind::DivZero;
}

Error::Error(ErrorKind kind, std::string detail) : kind_(kind), detail_(std::move(detail)) {
  text_ = std::string(kind_name(kind_));
  if (kind_has_detail(kind_)) {
    text_ += ' ';
    text_ += detail_;
  }
}

}  // namespace kiln
