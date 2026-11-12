// Pass 0: splitting the input into modules (SPEC.md section 2).
#pragma once

#include <string>
#include <string_view>
#include <vector>

namespace langvm {

struct ModuleSource {
  std::string name;
  // The module body: its lines joined with LF (CR before LF already removed).
  std::u32string text;
};

// Splits the stream; throws CompileError (bad-module / dup-module).
std::vector<ModuleSource> splitModules(std::string_view input);

// True if `s` is a legal identifier (SPEC.md section 3.3), not a keyword.
bool isIdentifier(std::string_view s);
bool isKeyword(std::string_view s);

}  // namespace langvm
