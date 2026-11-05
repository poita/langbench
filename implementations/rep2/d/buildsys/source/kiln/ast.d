/**
 * The abstract syntax tree produced by the parser and walked by the evaluator.
 */
module kiln.ast;

/// Expression node kinds.
enum EK : ubyte
{
    intLit,
    strLit,
    interp,
    boolLit,
    variable,
    list,
    neg,
    not,
    binary,
    and,
    or,
    call,
    index,
}

/// Binary operators (other than the short-circuit `&&` and `||`).
enum BinOp : ubyte
{
    add,
    sub,
    mul,
    div,
    mod,
    strCat,
    listCat,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
}

/// The spelling of a binary operator, used as the error site.
string spelling(BinOp op) @safe pure nothrow @nogc
{
    static immutable string[] names = ["+", "-", "*", "/", "%", "~", "++", "==", "!=", "<", "<=", ">", ">="];
    return names[op];
}

/// One piece of an interpolated string: literal text or an expression.
struct InterpPart
{
    string literal;
    Expr expr; // null for a literal piece
}

/// An expression node.
final class Expr
{
    EK kind;
    BinOp op;
    long intValue;
    /// String literal value, variable name or function name.
    string text;
    /// Operands, list elements or call arguments.
    Expr[] kids;
    InterpPart[] parts;
    /// Built-in function id for calls; -1 when unknown.
    int fn = -1;

    this(EK kind)
    {
        this.kind = kind;
    }
}

/// Statement kinds.
enum SK : ubyte
{
    let,
    set,
    include,
    abort,
    default_,
    phony,
    use,
    when,
    each,
    rule,
    step,
}

/// Step field kinds.
enum FK : ubyte
{
    out_,
    in_,
    after,
    cost,
    depfile,
    cmd,
}

/// A field of a `step` block.
struct StepField
{
    FK kind;
    Expr expr;
    string cmdName;
    Expr[] cmdArgs;
}

/// A rule parameter with an optional default.
struct Param
{
    string name;
    Expr defaultValue; // null when required
}

/// A statement node.
final class Stmt
{
    SK kind;
    int line;
    /// Variable / phony / rule name, or the `each` element name.
    string name;
    /// The `each` index variable, if any.
    string indexName;
    Expr expr;
    /// `use` arguments; `argNames[i]` is empty for a positional argument.
    Expr[] args;
    string[] argNames;
    /// `each` / `rule` block.
    Stmt[] block;
    /// `when` / `elsewhen` conditions and bodies; `bodies` has one more entry
    /// than `conds` when an `otherwise` branch exists.
    Expr[] conds;
    Stmt[][] bodies;
    Param[] params;
    StepField[] fields;

    this(SK kind, int line)
    {
        this.kind = kind;
        this.line = line;
    }
}
