// Helpers shared by the unit tests.
#pragma once

#include <sstream>
#include <string>

#include "langvm/langvm.h"

namespace testsupport {

// Everything the CLI would print for this module stream.
inline std::string runStream(const std::string& source) {
  std::ostringstream out;
  langvm::execute(source, out);
  return out.str();
}

// A single-module program: `body` is the content of module `main`.
inline std::string runMain(const std::string& body) { return runStream("@module main\n" + body); }

// The one-line diagnostic for a rejected program, or "" if it compiles.
inline std::string diagnosticOf(const std::string& source) {
  langvm::CompileResult r = langvm::compile(source);
  return r.ok() ? "" : r.diagnostic->toString();
}
inline std::string diagnosticOfMain(const std::string& body) { return diagnosticOf("@module main\n" + body); }

}  // namespace testsupport
