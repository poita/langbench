/// Abstract syntax tree of KBL.
module kiln.ast;

/// Expression node kinds.
enum ExprKind : ubyte
{
    intLit, strLit, boolLit, variable, list, unary, binary, call, index,
}

/// A piece of a double-quoted string literal.
struct StrPart
{
    string literal; /// used when `expr` is null
    Expr expr;      /// an interpolation
}

/// An expression. One class with a kind tag keeps the tree walk simple.
final class Expr
{
    ExprKind kind;
    long num;          /// intLit value, boolLit (0/1)
    string name;       /// variable or function name
    string op;         /// operator spelling for unary/binary
    Expr[] kids;       /// operands / elements / call arguments
    StrPart[] parts;   /// strLit parts
    int fn = -1;       /// resolved built-in index for calls (-1 = unknown)

    this(ExprKind k)
    {
        kind = k;
    }
}

/// Statement kinds.
enum StmtKind : ubyte
{
    let, set, include, abort, def /* default */, phony, use, when, each, rule, step,
}

/// A `use` argument (positional when `name` is empty).
struct Arg
{
    string name;
    Expr expr;
}

/// A rule parameter.
struct Param
{
    string name;
    Expr defaultExpr; /// null when the parameter is required
}

/// A `when`/`elsewhen` branch.
struct Branch
{
    Expr cond;
    Stmt[] body;
}

/// Step field kinds.
enum FieldKind : ubyte { out_, in_, after, cost, depfile, cmd }

/// A field inside a `step` block.
struct Field
{
    FieldKind kind;
    Expr expr;        /// for all but `cmd`
    string cmdName;   /// for `cmd`
    Expr[] cmdArgs;
}

/// A statement.
final class Stmt
{
    StmtKind kind;
    int line;
    string name;          /// let/set/phony/use/rule name; each: value variable
    string indexName;     /// each: optional index variable
    Expr expr;            /// let/set/include/abort/default/phony/each subject
    Arg[] args;           /// use
    Param[] params;       /// rule
    Stmt[] body;          /// each/rule body, `otherwise` body
    Branch[] branches;    /// when
    bool hasOtherwise;
    Field[] fields;       /// step

    this(StmtKind k, int line)
    {
        kind = k;
        this.line = line;
    }
}
