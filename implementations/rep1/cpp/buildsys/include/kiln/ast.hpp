// Syntax tree for KBL build files.
#pragma once

#include <cstdint>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "kiln/value.hpp"

namespace kiln {

struct Expr;
using ExprPtr = std::unique_ptr<Expr>;

enum class BinaryOp { Or, And, Eq, Ne, Lt, Le, Gt, Ge, ListConcat, StrConcat, Add, Sub, Mul, Div, Mod };
enum class UnaryOp { Not, Neg };

/// Source spelling of an operator, as used in `E_TYPE operator <op>` sites.
const char* op_spelling(BinaryOp op);
const char* op_spelling(UnaryOp op);

struct InterpPart {
  std::string literal;  ///< used when `expr` is null
  ExprPtr expr;
};

struct Expr {
  enum class Kind {
    Literal,   ///< `literal` holds an int, bool or str value
    Interp,    ///< double-quoted literal with interpolations: `parts`
    Var,       ///< `name`
    List,      ///< `args`
    Unary,     ///< `unary_op`, `args[0]`
    Binary,    ///< `binary_op`, `args[0]`, `args[1]`
    Call,      ///< `name`, `args` (pipes are desugared into calls)
    Index,     ///< `args[0]` target, `args[1]` index
  };
  Kind kind = Kind::Literal;
  Value literal;
  std::string name;
  UnaryOp unary_op = UnaryOp::Not;
  BinaryOp binary_op = BinaryOp::Or;
  std::vector<ExprPtr> args;
  std::vector<InterpPart> parts;
};

struct Stmt;
using StmtPtr = std::unique_ptr<Stmt>;
using Block = std::vector<StmtPtr>;

struct Param {
  std::string name;
  ExprPtr default_value;  ///< null when the parameter is required
};

struct KeywordArg {
  std::string name;
  ExprPtr value;
};

struct WhenBranch {
  ExprPtr condition;
  Block body;
};

struct StepField {
  enum class Kind { Out, In, After, Cost, Depfile, Cmd };
  Kind kind = Kind::Out;
  ExprPtr expr;                 ///< all but Cmd
  std::string command;          ///< Cmd: the command name
  std::vector<ExprPtr> args;    ///< Cmd: argument expressions
};

struct Stmt {
  enum class Kind { Let, Set, Include, Abort, Default, Phony, Use, When, Each, Rule, Step };
  Kind kind = Kind::Let;
  std::string name;  ///< Let/Set/Phony name, Use/Rule name, Each element variable
  ExprPtr expr;      ///< Let/Set/Include/Abort/Default/Phony value, Each subject

  // Use
  std::vector<ExprPtr> positional;
  std::vector<KeywordArg> keywords;

  // When
  std::vector<WhenBranch> branches;
  bool has_otherwise = false;
  Block otherwise;

  // Each (`index_name` empty in the one-variable form) and Rule
  std::string index_name;
  std::vector<Param> params;
  Block body;

  // Step
  std::vector<StepField> fields;
};

/// A parsed build file. Rules keep pointers into it, so it must outlive them.
struct Program {
  std::string path;
  Block statements;
};

}  // namespace kiln
