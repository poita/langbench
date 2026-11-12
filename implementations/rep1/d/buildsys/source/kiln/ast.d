/**
 * Syntax trees for KBL build files.
 */
module kiln.ast;

import kiln.value : Value;

/// An expression node.
final class Expr
{
    /// Node kinds.
    enum Kind : ubyte
    {
        literal,  /// a constant `Value` (`lit`)
        interp,   /// a double-quoted string with interpolations (`parts`)
        variable, /// a variable reference (`name`)
        list,     /// a list display (`args`)
        unary,    /// `!x` / `-x` (`name` is the operator, `args[0]` the operand)
        binary,   /// `a op b` (`name` is the operator, `args` the two operands)
        call,     /// `f(args...)` (`name`); also the desugaring of `x |> f(...)`
        index,    /// `x[i]` (`args[0]` is x, `args[1]` is i)
    }

    /// One piece of an interpolated string: either literal bytes or an expression.
    struct Part
    {
        string literal;
        Expr expr;
    }

    ///
    Kind kind;
    ///
    Value lit;
    ///
    string name;
    ///
    Expr[] args;
    ///
    Part[] parts;
}

/// A rule parameter.
struct Param
{
    ///
    string name;
    /// Default value expression, or null.
    Expr defaultValue;
}

/// An argument of a `use` statement.
struct UseArg
{
    /// The keyword, or null for a positional argument.
    string keyword;
    ///
    Expr value;
}

/// One field of a `step` block.
struct StepField
{
    /// Field kinds.
    enum Kind : ubyte { out_, in_, after, cost, depfile, cmd }

    ///
    Kind kind;
    ///
    Expr expr;
    /// For `cmd`: the command name.
    string cmdName;
    /// For `cmd`: the argument expressions.
    Expr[] cmdArgs;
}

/// A statement node.
final class Stmt
{
    /// Statement kinds.
    enum Kind : ubyte { let, set, include, abort, default_, phony, use, when, each, rule, step }

    ///
    Kind kind;
    /// 1-based line of the statement's first physical line.
    int line;
    /// The bound name (`let`, `set`, `phony`, `each` value variable, `rule` name, `use` rule name).
    string name;
    /// `each`: the index variable, or null.
    string indexName;
    /// The expression of simple statements, the `each` subject.
    Expr expr;
    /// `when`: conditions of the `when` and `elsewhen` branches.
    Expr[] conds;
    /// `when`: bodies, one per condition, then the `otherwise` body if `hasOtherwise`.
    Stmt[][] bodies;
    ///
    bool hasOtherwise;
    /// `each` / `rule`: the body.
    Stmt[] body_;
    /// `rule`: parameters.
    Param[] params;
    /// `use`: arguments.
    UseArg[] useArgs;
    /// `step`: fields in source order.
    StepField[] fields;
}

/// A parsed build file.
final class BuildFile
{
    ///
    string path;
    ///
    Stmt[] statements;
}
