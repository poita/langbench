#include <ostream>

#include "bytecode.h"
#include "checker.h"
#include "compiler.h"
#include "langvm/langvm.h"
#include "lexer.h"
#include "model.h"
#include "parser.h"
#include "resolver.h"
#include "source.h"
#include "vm.h"

namespace langvm {

Program::Program(std::unique_ptr<Impl> impl) : impl_(std::move(impl)) {}
Program::~Program() = default;

CompileResult compile(std::string_view source) {
  CompileResult result;
  try {
    // Pass 0: module stream. Pass 1: lex every module. Pass 2: parse every module.
    std::vector<ModuleSource> sources = splitModules(source);
    std::vector<std::vector<Token>> tokens;
    for (const ModuleSource& m : sources) tokens.push_back(lex(m.text));
    std::vector<ModuleAst> asts;
    for (auto& t : tokens) asts.push_back(parseModule(std::move(t)));
    // Pass 3: items; pass 4: bodies.
    Model model;
    Resolver resolver(model);
    resolver.loadPrelude();
    resolver.resolve(sources, asts);
    Checker checker(model, resolver);
    checker.checkAll();
    result.program = std::make_unique<Program>(compileProgram(model));
  } catch (const CompileError& e) {
    result.diagnostic = e.diagnostic();
  }
  return result;
}

RunResult run(const Program& program, std::ostream& out) {
  VM vm(program.impl(), out);
  return vm.run();
}

void execute(std::string_view source, std::ostream& out) {
  CompileResult c = compile(source);
  if (!c.ok()) {
    out << c.diagnostic->toString() << "\n";
    return;
  }
  run(*c.program, out);
}

}  // namespace langvm
