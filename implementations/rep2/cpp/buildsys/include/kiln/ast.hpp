// Syntax trees for KBL build files.
#pragma once

#include <memory>
#include <string>
#include <vector>

#include "kiln/value.hpp"

namespace kiln {

enum class ExprKind { Const, Interp, Var, List, Call, Index, Unary, Binary };

enum class Op { Or, And, Eq, Ne, Lt, Le, Gt, Ge, Concat, Tilde, Add, Sub, Mul, Div, Mod, Not, Neg };

/// Spelling of an operator, as used in `E_TYPE operator <op>` sites.
const char* opSpelling(Op op) noexcept;

struct Expr;
using ExprPtr = std::unique_ptr<Expr>;

/// A piece of a double-quoted literal: literal text, or an interpolated expression.
struct StrPart {
  std::string literal;
  ExprPtr expr;  // null for a literal part
};

struct Expr {
  ExprKind kind = ExprKind::Const;
  Value value;                  // Const
  std::string name;             // Var, Call
  Op op = Op::Add;              // Unary, Binary
  std::vector<ExprPtr> kids;    // List elements, Call args, Index {target, index}, operands
  std::vector<StrPart> parts;   // Interp
};

struct Stmt;
using Block = std::vector<std::unique_ptr<Stmt>>;

struct StepField {
  enum Kind { Out, In, After, Cost, Depfile, Cmd };
  Kind kind = Out;
  ExprPtr expr;                 // all but Cmd
  std::string cmdName;          // Cmd
  std::vector<ExprPtr> cmdArgs; // Cmd
};

struct UseArg {
  std::string keyword;  // empty for a positional argument
  ExprPtr expr;
};

struct Param {
  std::string name;
  ExprPtr defaultValue;  // may be null
};

struct Branch;

struct Stmt {
  enum Kind { Let, Set, Include, Abort, Default, Phony, Use, When, Each, Rule, Step };
  Kind kind = Let;
  std::string name;               // Let/Set/Phony/Use/Rule name; Each's element variable
  std::string indexName;          // Each (two-variable form)
  ExprPtr expr;                   // Let/Set/Include/Abort/Default/Phony/Each subject
  std::vector<UseArg> args;       // Use
  std::vector<Param> params;      // Rule
  Block body;                     // Each/Rule
  std::vector<Branch> branches;   // When
  std::vector<StepField> fields;  // Step

  Stmt();
  ~Stmt();
  Stmt(Stmt&&) noexcept;
  Stmt& operator=(Stmt&&) noexcept;
};

/// One arm of a `when` statement; a null condition is the `otherwise` arm.
struct Branch {
  ExprPtr cond;
  Block body;
};

/// A fully parsed build file.
struct ParsedFile {
  std::string path;
  Block statements;
};

}  // namespace kiln
