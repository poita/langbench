// Error vocabulary shared by every Kiln module.
#pragma once

#include <exception>
#include <string>
#include <string_view>

namespace kiln {

/// The thirty documented error kinds. `kind_name()` gives the `E_...` spelling.
enum class ErrorKind {
  Parse,
  UnknownVar,
  Redefine,
  SetUndefined,
  Type,
  Arity,
  UnknownFunc,
  UnknownRule,
  UnknownCmd,
  Arg,
  IncludeMissing,
  IncludeCycle,
  BadPath,
  OutputPath,
  StepField,
  CmdShape,
  DupOutput,
  DupPhony,
  MissingInput,
  UnknownTarget,
  Cycle,
  NoDefault,
  RuleRecursion,
  DivZero,
  Interp,
  Abort,
  NoBuildFile,
  NeedPath,
  NeedMissing,
  NeedCycle,
};

/// `E_PARSE`, `E_TYPE`, ...
std::string_view kind_name(ErrorKind kind) noexcept;

/// Whether the kind carries a detail text (`E_NO_DEFAULT` and `E_DIV_ZERO` do not).
bool kind_has_detail(ErrorKind kind) noexcept;

/// A build error: a kind plus a detail string. Thrown by the evaluator and by
/// commands, and stored in a `BuildReport` when a build fails.
class Error : public std::exception {
 public:
  Error(ErrorKind kind, std::string detail = {});

  ErrorKind kind() const noexcept { return kind_; }
  const std::string& detail() const noexcept { return detail_; }

  /// `E_KIND detail`, exactly as it appears after `error ` in log.txt.
  const std::string& text() const noexcept { return text_; }
  const char* what() const noexcept override { return text_.c_str(); }

 private:
  ErrorKind kind_;
  std::string detail_;
  std::string text_;
};

}  // namespace kiln
