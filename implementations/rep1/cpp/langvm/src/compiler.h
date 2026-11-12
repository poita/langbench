// Bytecode generation from the checked syntax tree (SPEC.md section 16).
#pragma once

#include <memory>

#include "bytecode.h"
#include "model.h"

namespace langvm {

// Compiles every function body of a successfully checked program.
std::unique_ptr<Program::Impl> compileProgram(Model& model);

}  // namespace langvm
