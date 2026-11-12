/// \file primitives.hpp
/// The built-in procedures.
#pragma once

namespace scheme {

class Interpreter;

/// Install the standard primitives (arithmetic, lists, predicates, strings,
/// `apply`, `error`, `display`, `newline`) into the global environment.
void install_primitives(Interpreter& interp);

}  // namespace scheme
