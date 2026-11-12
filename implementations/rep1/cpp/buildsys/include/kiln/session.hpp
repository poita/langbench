// Session scripts: a scripted sequence of builds and workspace mutations.
#pragma once

#include <string>
#include <string_view>
#include <vector>

#include "kiln/vfs.hpp"

namespace kiln {

/// One parsed step of `session.txt`.
struct SessionStep {
  enum class Kind { Build, Create, Edit, Delete, Touch, Clean };
  Kind kind = Kind::Build;
  std::vector<std::string> targets;  ///< Build: targets as written
  int workers = 1;                   ///< Build: `-j` value (default 1)
  std::string path;                  ///< Create/Edit/Delete/Touch
  std::string content;               ///< Create/Edit: new file content
};

/// Parses a session script. Throws `std::runtime_error` on a malformed script
/// (the specification guarantees test scripts are well formed).
std::vector<SessionStep> parse_session(std::string_view script);

/// Runs the steps against `vfs` and returns the complete `log.txt` text.
std::string run_session(Vfs& vfs, const std::vector<SessionStep>& steps);

/// Convenience: parse and run.
std::string run_session(Vfs& vfs, std::string_view script);

}  // namespace kiln
