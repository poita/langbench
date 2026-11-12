// Pass 2: recursive-descent parser (SPEC.md section 4).
#pragma once

#include <vector>

#include "ast.h"
#include "lexer.h"

namespace langvm {

// Parses a module's token list (which must end with Eof). Throws CompileError
// (`parse`) at the first token that cannot be accepted.
ModuleAst parseModule(std::vector<Token> tokens);

}  // namespace langvm
