#include "kiln/error.hpp"

namespace kiln {

Error::Error(std::string kind, std::string detail)
    : kind_(std::move(kind)), detail_(std::move(detail)) {
  message_ = kind_;
  if (!detail_.empty()) {
    message_ += ' ';
    message_ += detail_;
  }
}

Error typeError(const std::string& site, const std::string& expected,
                const std::string& actual) {
  return Error("E_TYPE", site + ": expected " + expected + ", got " + actual);
}

Error argError(const std::string& kind, const std::string& name,
               const std::string& reason) {
  return Error("E_ARG", kind + " " + name + ": " + reason);
}

}  // namespace kiln
