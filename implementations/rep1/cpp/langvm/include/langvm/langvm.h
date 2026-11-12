// langvm: a compiler and stack virtual machine for the Vellum language.
//
// Typical use:
//
//   langvm::CompileResult c = langvm::compile(source);
//   if (!c.ok()) { std::cout << c.diagnostic->toString() << "\n"; }
//   else         { langvm::RunResult r = langvm::run(*c.program, std::cout); }
//
// or, in one step, `langvm::execute(source, std::cout)`.
#pragma once

#include <iosfwd>
#include <memory>
#include <optional>
#include <string>
#include <string_view>

#include "langvm/diagnostic.h"

namespace langvm {

// A compiled program: bytecode plus everything the VM needs to run it.
// Opaque; created by compile() and consumed by run().
class Program {
 public:
  ~Program();
  Program(const Program&) = delete;
  Program& operator=(const Program&) = delete;

  struct Impl;
  explicit Program(std::unique_ptr<Impl> impl);
  const Impl& impl() const { return *impl_; }

 private:
  std::unique_ptr<Impl> impl_;
};

struct CompileResult {
  // Set when the program was accepted.
  std::unique_ptr<Program> program;
  // Set when the program was rejected.
  std::optional<Diagnostic> diagnostic;

  bool ok() const { return program != nullptr; }
};

// Compiles a whole module stream (SPEC.md section 2). Never throws for a
// rejected program: the first diagnostic is returned instead.
CompileResult compile(std::string_view source);

struct RunResult {
  bool panicked = false;
  // The panic message (without the "panic: " prefix); empty if !panicked.
  std::string panicMessage;
};

// Runs `main`, writing everything the program prints to `out`. A panic is
// reported in the result *and* appended to `out` as the `panic: ...` line.
RunResult run(const Program& program, std::ostream& out);

// compile() + run(): writes either the one diagnostic line or the program's
// output (plus a panic line) to `out`. Always "succeeds" like the CLI does.
void execute(std::string_view source, std::ostream& out);

}  // namespace langvm
