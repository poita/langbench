// Helpers shared by the unit tests.
#pragma once

#include <initializer_list>
#include <string>
#include <utility>

#include "kiln/kiln.hpp"

namespace testing_support {

using Files = std::initializer_list<std::pair<const char*, const char*>>;

inline kiln::Vfs workspace(Files files) {
  kiln::Vfs ws;
  for (const auto& [path, content] : files) ws.write(path, std::string(content));
  return ws;
}

/// Runs a session script and returns log.txt's text.
inline std::string run(kiln::Vfs& ws, const std::string& script) { return kiln::run_session(ws, script); }

/// Evaluates `main.kiln` only and returns the error text (empty on success).
inline std::string eval_error(const std::string& main_kiln, Files extra = {}) {
  kiln::Vfs ws = workspace(extra);
  ws.write("main.kiln", main_kiln);
  try {
    kiln::evaluate_workspace(ws);
  } catch (const kiln::Error& e) {
    return e.text();
  }
  return {};
}

/// Runs one default build of `main_kiln` and returns the error text (empty on success).
inline std::string build_error(const std::string& main_kiln, Files extra = {}) {
  kiln::Vfs ws = workspace(extra);
  ws.write("main.kiln", main_kiln);
  kiln::BuildReport r = kiln::run_build(ws, {});
  return r.error ? r.error->text() : std::string();
}

/// Evaluates `expr` inside a one-line build file and returns its text: the
/// interpolated value for str/int/bool results, or the error text on failure.
inline std::string eval_text(const std::string& expr, Files extra = {}) {
  kiln::Vfs ws = workspace(extra);
  ws.write("main.kiln", "let r = " + expr + "\nabort \"{r}\"\n");
  try {
    kiln::evaluate_workspace(ws);
  } catch (const kiln::Error& e) {
    return e.kind() == kiln::ErrorKind::Abort ? e.detail() : e.text();
  }
  return "<no error>";
}

}  // namespace testing_support
