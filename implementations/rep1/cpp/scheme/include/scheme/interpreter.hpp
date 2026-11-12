/// \file interpreter.hpp
/// The evaluator: a pre-analysing tree walker with proper tail calls.
#pragma once

#include <iosfwd>
#include <optional>
#include <string_view>
#include <vector>

#include "scheme/analyzer.hpp"
#include "scheme/errors.hpp"
#include "scheme/value.hpp"

namespace scheme {

/// Outcome of Interpreter::run.
struct RunResult {
  bool ok = true;                      ///< false if evaluation stopped on an error
  std::optional<ErrorKind> error;      ///< set when !ok
};

/// A Scheme interpreter with its own global environment.
///
/// Not thread-safe; independent Interpreters may be used on different threads
/// provided their Values are not shared. Deep non-tail recursion uses native
/// stack: run it on a thread with a large stack (see run_with_stack_size).
class Interpreter {
 public:
  Interpreter();
  Interpreter(const Interpreter&) = delete;
  Interpreter& operator=(const Interpreter&) = delete;

  /// Evaluate a whole program, printing each non-void top-level value (write
  /// form, then LF) and the output of `display`/`newline` to `out`. On a
  /// runtime error appends `error: <category>` + LF and stops. Never throws
  /// for Scheme-level errors.
  RunResult run(std::string_view source, std::ostream& out);

  /// Evaluate every form of `source` in the global environment and return the
  /// value of the last (void for an empty program). `display` output goes to
  /// the current output stream (std::cout by default, see set_output).
  /// Throws SchemeError on errors.
  Value eval_string(std::string_view source);

  /// Evaluate one already-read datum in the global environment.
  Value eval(const Value& datum);

  /// Where `display` and `newline` write.
  void set_output(std::ostream* out) { out_ = out; }
  std::ostream& output() { return *out_; }

  SymbolTable& symbols() { return symbols_; }

  /// Bind a native procedure globally. `max_args` of -1 means variadic.
  void define_primitive(const char* name, int min_args, int max_args, PrimitiveFn fn);
  /// Bind `name` globally to `value`.
  void define_global(std::string_view name, Value value);

 private:
  Value eval_node(const Node* node, Frame* env);
  Ref<Frame> bind_arguments(const Closure& c, std::vector<Value>& args);

  // Declaration order matters: the symbol table is destroyed last.
  SymbolTable symbols_;
  Analyzer analyzer_;
  std::ostream* out_;
};

}  // namespace scheme
