// Session scripts: parsing, execution and the session log.
#pragma once

#include <string>
#include <string_view>
#include <vector>

#include "kiln/vfs.hpp"

namespace kiln {

/// One step of a session script.
struct SessionStep {
  enum Kind { Build, Create, Edit, Delete, Touch, Clean };
  Kind kind = Build;
  std::vector<std::string> targets;  // Build
  int jobs = 1;                      // Build
  std::string path;                  // Create/Edit/Delete/Touch
  std::string content;               // Create/Edit
};

/// Parses `session.txt`.
std::vector<SessionStep> parseSession(std::string_view script);

/// Runs a whole session against `vfs` and returns the text of `log.txt`.
std::string runSession(Vfs& vfs, const std::vector<SessionStep>& steps);

/// Convenience: parse, then run.
std::string runSession(Vfs& vfs, std::string_view script);

}  // namespace kiln
