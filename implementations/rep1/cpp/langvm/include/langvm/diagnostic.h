// Compile-time diagnostics of the Vellum language (SPEC.md section 13).
#pragma once

#include <exception>
#include <string>

namespace langvm {

// X-macro list of every diagnostic kind: (enumerator, spelling in the output).
#define LANGVM_ERROR_KINDS(X)                      \
  X(BadModule, "bad-module")                       \
  X(DupModule, "dup-module")                       \
  X(BadToken, "bad-token")                         \
  X(IntRange, "int-range")                         \
  X(BadEscape, "bad-escape")                       \
  X(Unterminated, "unterminated")                  \
  X(Parse, "parse")                                \
  X(ReservedName, "reserved-name")                 \
  X(DupName, "dup-name")                           \
  X(UnknownModule, "unknown-module")               \
  X(UnknownType, "unknown-type")                   \
  X(UnknownTrait, "unknown-trait")                 \
  X(NotPublic, "not-public")                       \
  X(ArityType, "arity-type")                       \
  X(BadArity, "bad-arity")                         \
  X(BadKeyType, "bad-key-type")                    \
  X(SelfOutside, "self-outside")                   \
  X(BuiltinTraitImpl, "builtin-trait-impl")        \
  X(BadImplHead, "bad-impl-head")                  \
  X(UnusedParam, "unused-param")                   \
  X(DupImpl, "dup-impl")                           \
  X(MissingMethod, "missing-method")               \
  X(ExtraMethod, "extra-method")                   \
  X(SigMismatch, "sig-mismatch")                   \
  X(NoMain, "no-main")                             \
  X(UnknownName, "unknown-name")                   \
  X(TypeMismatch, "type-mismatch")                 \
  X(Arity, "arity")                                \
  X(NotCallable, "not-callable")                   \
  X(NotStruct, "not-struct")                       \
  X(UnknownField, "unknown-field")                 \
  X(MissingField, "missing-field")                 \
  X(DupField, "dup-field")                         \
  X(NotIndexable, "not-indexable")                 \
  X(NotIterable, "not-iterable")                   \
  X(NoMethod, "no-method")                         \
  X(AmbigMethod, "ambig-method")                   \
  X(UnsatisfiedBound, "unsatisfied-bound")         \
  X(NotEq, "not-eq")                               \
  X(NotOrd, "not-ord")                             \
  X(CannotInfer, "cannot-infer")                   \
  X(NonExhaustive, "non-exhaustive")               \
  X(Unreachable, "unreachable")                    \
  X(MissingReturn, "missing-return")               \
  X(BadValueRef, "bad-value-ref")                  \
  X(BadPattern, "bad-pattern")                     \
  X(RefutablePattern, "refutable-pattern")         \
  X(BreakOutside, "break-outside")                 \
  X(AssignImmutable, "assign-immutable")           \
  X(AssignCaptured, "assign-captured")             \
  X(BadTarget, "bad-target")

enum class ErrorKind {
#define X(name, text) name,
  LANGVM_ERROR_KINDS(X)
#undef X
};

// The spelling of a kind, e.g. "type-mismatch".
const char* kindName(ErrorKind kind);

// One rejected-program diagnostic: `error: <kind> at <line>:<col>`.
struct Diagnostic {
  ErrorKind kind;
  int line;
  int col;

  // The exact line printed for a rejected program, without the trailing LF.
  std::string toString() const;
};

// Thrown internally by the compiler phases; the public API catches it and
// returns the Diagnostic instead.
class CompileError : public std::exception {
 public:
  explicit CompileError(Diagnostic d) : diag_(d) {}
  CompileError(ErrorKind kind, int line, int col) : diag_{kind, line, col} {}
  const Diagnostic& diagnostic() const { return diag_; }
  const char* what() const noexcept override { return "compile error"; }

 private:
  Diagnostic diag_;
};

}  // namespace langvm
