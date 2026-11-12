// Trait satisfaction: the built-in Eq / Ord / Key and user traits (SPEC.md sections 7 and 8.4).
#pragma once

#include "model.h"

namespace langvm {

bool hasEq(Model& m, Type* t);
bool hasOrd(Model& m, Type* t);
bool hasKey(Model& m, Type* t);
// Does `t` satisfy the trait `trait` (built-in or user)?
bool satisfies(Model& m, Type* t, int trait);

}  // namespace langvm
