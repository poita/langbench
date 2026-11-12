// Helpers shared by the unit tests.
#pragma once

#include <initializer_list>
#include <string>
#include <utility>

#include "kiln/kiln.hpp"

namespace kiln::testing {

/// Builds a workspace from (path, content) pairs.
inline Vfs makeVfs(std::initializer_list<std::pair<std::string, std::string>> files) {
  Vfs vfs;
  for (const auto& [p, c] : files) vfs.write(p, c);
  return vfs;
}

/// Runs a session script and returns the log.
inline std::string runLog(Vfs& vfs, const std::string& script) { return runSession(vfs, script); }

/// Evaluates a build file and returns the error message ("" if none).
inline std::string evalError(const std::string& mainKiln) {
  Vfs vfs = makeVfs({{"main.kiln", mainKiln}});
  try {
    Evaluator(vfs).evaluate();
  } catch (const Error& e) {
    return e.message();
  }
  return "";
}

/// Evaluates `expr` by writing it into a one-step build file and returning the
/// resulting `write` argument.
inline std::string evalToString(const std::string& expr, const std::string& prelude = "") {
  Vfs vfs = makeVfs({{"main.kiln", prelude + "\nstep {\n out \"out/x\"\n cmd write(" + expr + ")\n}\n"}});
  BuildPlan plan = Evaluator(vfs).evaluate();
  return plan.steps.at(0).call.args.at(0).asStr();
}

}  // namespace kiln::testing
