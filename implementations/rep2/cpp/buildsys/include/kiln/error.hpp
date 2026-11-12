// The single error type of the Kiln engine.
#pragma once

#include <exception>
#include <string>

namespace kiln {

/// A Kiln build error: a kind such as `E_TYPE` and a (possibly empty) detail.
///
/// `message()` renders the text used in the session log: `KIND detail`, or just
/// `KIND` when there is no detail.
class Error : public std::exception {
 public:
  explicit Error(std::string kind, std::string detail = {});

  const std::string& kind() const noexcept { return kind_; }
  const std::string& detail() const noexcept { return detail_; }
  const std::string& message() const noexcept { return message_; }
  const char* what() const noexcept override { return message_.c_str(); }

 private:
  std::string kind_;
  std::string detail_;
  std::string message_;
};

/// Builds `E_TYPE <site>: expected <expected>, got <actual>`.
Error typeError(const std::string& site, const std::string& expected,
                const std::string& actual);

/// Builds `E_ARG <kind> <name>: <reason>`.
Error argError(const std::string& kind, const std::string& name,
               const std::string& reason);

}  // namespace kiln
