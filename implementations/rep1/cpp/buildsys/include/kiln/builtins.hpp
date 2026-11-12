// The 39 KBL built-in functions.
#pragma once

#include <string>
#include <string_view>
#include <vector>

#include "kiln/value.hpp"
#include "kiln/vfs.hpp"

namespace kiln {

/// Raises `E_TYPE <site>: expected <expected>, got <actual>`.
[[noreturn]] void throw_type_error(std::string_view site, std::string_view expected, Type actual);

/// Raises `E_ARG <kind> <name>: <reason>`.
[[noreturn]] void throw_arg_error(std::string_view kind, std::string_view name, std::string_view reason);

/// Performs the call sequence's steps 3-5 for a built-in: arity check, argument
/// type checks (ascending), then the function itself. Step 1 (lookup) is
/// `is_builtin`; step 2 (argument evaluation) is the caller's job.
Value call_builtin(std::string_view name, const std::vector<Value>& args, const Vfs& vfs);

/// Whether `name` is one of the 39 built-ins.
bool is_builtin(std::string_view name);

/// Left-to-right non-overlapping replacement; `from` must be non-empty.
std::string replace_all(std::string_view s, std::string_view from, std::string_view to);

}  // namespace kiln
