// Rendering of types in the canonical textual form.
#pragma once

#include <string>

#include "typeinfer/types.hpp"

namespace typeinfer {

/// Renders `t` with type variables named 'a, 'b, ... 'z, 'a1, 'b1, ... in
/// order of first appearance, and with parentheses only where needed.
/// Names are local to one call. Shared sub-terms are printed in full.
std::string print_type(TypeStore& store, Type* t);

}  // namespace typeinfer
