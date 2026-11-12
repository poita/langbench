// The 39 KBL built-in functions.
#pragma once

#include <string>
#include <string_view>
#include <vector>

#include "kiln/value.hpp"
#include "kiln/vfs.hpp"

namespace kiln {

/// Static description of a built-in function.
struct Builtin {
  using Fn = Value (*)(const std::vector<Value>& args, const Vfs& vfs);
  const char* name;
  int minArgs;
  int maxArgs;
  /// Allowed-type mask per argument position (see `TypeMask`).
  std::vector<unsigned> argMasks;
  Fn fn;
};

/// Looks a built-in up by name; nullptr if there is none.
const Builtin* findBuiltin(std::string_view name);

/// Calls `fn` with already evaluated arguments: checks the arity (`E_ARITY`),
/// then the argument types (`E_TYPE`), then runs the function.
Value callBuiltin(const Builtin& fn, const std::vector<Value>& args, const Vfs& vfs);

}  // namespace kiln
