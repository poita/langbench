/**
 * Runtime values, symbols and errors.
 *
 * A $(LREF Value) is a small tagged union (16 bytes). Small integers are held
 * inline; everything else refers to a heap object.
 */
module scheme.value;

import scheme.ast : LambdaInfo;
import scheme.bignum : BigNum;
import scheme.environment : Frame;
import scheme.output : Output;

/// Discriminator of a $(LREF Value).
enum Kind : ubyte
{
    nil, /// the empty list `()`
    boolean, /// `#t` / `#f`
    integer, /// integer that fits in a machine word
    bigInteger, /// integer held as a `BigNum` (never fits in a `long`)
    string, /// string
    symbol, /// interned symbol
    pair, /// cons cell
    closure, /// user-defined procedure
    primitive, /// built-in procedure
    void_, /// the unspecified value returned by `define`, `display`, ...
}

/// A Scheme value.
struct Value
{
    Kind kind;
    union
    {
        long i; /// `integer`, and 0/1 for `boolean`
        BigNum big;
        Str str;
        Symbol sym;
        Pair pair;
        Closure closure;
        Primitive prim;
    }

    /// The empty list.
    static Value nil() pure nothrow @nogc @trusted
    {
        Value v;
        v.kind = Kind.nil;
        return v;
    }

    /// The void value.
    static Value void_() pure nothrow @nogc @trusted
    {
        Value v;
        v.kind = Kind.void_;
        return v;
    }

    /// A boolean.
    static Value fromBool(bool b) pure nothrow @nogc @trusted
    {
        Value v;
        v.kind = Kind.boolean;
        v.i = b ? 1 : 0;
        return v;
    }

    /// A small integer.
    static Value fromInt(long n) pure nothrow @nogc @trusted
    {
        Value v;
        v.kind = Kind.integer;
        v.i = n;
        return v;
    }

    /// A string.
    static Value fromString(string s) pure nothrow @trusted
    {
        Value v;
        v.kind = Kind.string;
        v.str = new Str(s);
        return v;
    }

    /// A symbol.
    static Value fromSymbol(Symbol s) pure nothrow @nogc @trusted
    {
        Value v;
        v.kind = Kind.symbol;
        v.sym = s;
        return v;
    }

    /// A pair.
    static Value cons(Value car, Value cdr) pure nothrow @trusted
    {
        Value v;
        v.kind = Kind.pair;
        v.pair = new Pair(car, cdr);
        return v;
    }

    /// Wrap a closure.
    static Value fromClosure(Closure c) pure nothrow @nogc @trusted
    {
        Value v;
        v.kind = Kind.closure;
        v.closure = c;
        return v;
    }

    /// Wrap a primitive.
    static Value fromPrimitive(Primitive p) pure nothrow @nogc @trusted
    {
        Value v;
        v.kind = Kind.primitive;
        v.prim = p;
        return v;
    }

    /// Only `#f` is false.
    bool isTrue() const pure nothrow @nogc @trusted
    {
        return !(kind == Kind.boolean && i == 0);
    }

    /// Is this an integer (small or big)?
    bool isInteger() const pure nothrow @nogc @safe
    {
        return kind == Kind.integer || kind == Kind.bigInteger;
    }

    /// Is this a procedure (closure or primitive)?
    bool isProcedure() const pure nothrow @nogc @safe
    {
        return kind == Kind.closure || kind == Kind.primitive;
    }
}

/// Build a proper list from a slice of values.
Value listFromArray(const Value[] items, Value tail = Value.nil()) pure nothrow @safe
{
    Value r = tail;
    foreach_reverse (v; items)
        r = Value.cons(v, r);
    return r;
}

/// A string object (immutable contents).
final class Str
{
    string s;
    this(string s) pure nothrow @nogc @safe
    {
        this.s = s;
    }
}

/// A cons cell.
final class Pair
{
    Value car, cdr;
    this(Value car, Value cdr) pure nothrow @nogc @safe
    {
        this.car = car;
        this.cdr = cdr;
    }
}

/// Which special form (if any) a symbol names. Special-form names are reserved.
enum SpecialForm : ubyte
{
    none,
    quote,
    if_,
    define,
    set,
    lambda,
    let,
    letStar,
    letrec,
    begin,
    cond,
    and,
    or,
    else_,
}

/**
 * An interned symbol. Symbols also carry the global binding of the variable
 * of the same name, which makes global lookups O(1).
 */
final class Symbol
{
    string name;
    SpecialForm special;
    bool bound; /// does the global environment bind this symbol?
    Value value; /// the global value, valid when `bound`

    this(string name, SpecialForm special = SpecialForm.none) pure nothrow @nogc @safe
    {
        this.name = name;
        this.special = special;
    }
}

/// Interns symbols: one `Symbol` object per distinct name.
final class SymbolTable
{
    private Symbol[string] table;

    /// Symbols used by the analyzer.
    Symbol quoteSym;

    this()
    {
        enum SpecialForm[string] specials = [
            "quote": SpecialForm.quote, "if": SpecialForm.if_, "define": SpecialForm.define,
            "set!": SpecialForm.set, "lambda": SpecialForm.lambda, "let": SpecialForm.let,
            "let*": SpecialForm.letStar, "letrec": SpecialForm.letrec,
            "begin": SpecialForm.begin, "cond": SpecialForm.cond, "and": SpecialForm.and,
            "or": SpecialForm.or, "else": SpecialForm.else_,
        ];
        foreach (name, sf; specials)
            table[name] = new Symbol(name, sf);
        quoteSym = table["quote"];
    }

    /// Return the unique symbol called `name`, creating it if necessary.
    Symbol intern(string name) nothrow
    {
        if (auto p = name in table)
            return *p;
        auto s = new Symbol(name);
        table[name] = s;
        return s;
    }
}

/// Signature of built-in procedures. Arity has been checked by the caller.
alias PrimFn = Value function(Value[] args, Output output);

/// A built-in procedure.
final class Primitive
{
    string name;
    PrimFn fn;
    size_t minArgs;
    /// Maximum number of arguments, or `size_t.max` for "any number".
    size_t maxArgs;
    /// `apply` is special: the evaluator performs its call as a tail call.
    bool isApply;

    this(string name, PrimFn fn, size_t minArgs, size_t maxArgs, bool isApply = false) pure nothrow @nogc @safe
    {
        this.name = name;
        this.fn = fn;
        this.minArgs = minArgs;
        this.maxArgs = maxArgs;
        this.isApply = isApply;
    }
}

/// A user-defined procedure: code plus the environment it closed over.
final class Closure
{
    LambdaInfo info;
    Frame env;
    this(LambdaInfo info, Frame env) pure nothrow @nogc @safe
    {
        this.info = info;
        this.env = env;
    }
}

/// The categories of runtime error named in the specification.
enum ErrorKind
{
    unboundVariable,
    typeError,
    arityError,
    divisionByZero,
    userError,
}

/// The text printed after `error: ` for an $(LREF ErrorKind).
string categoryName(ErrorKind k) pure nothrow @nogc @safe
{
    final switch (k)
    {
    case ErrorKind.unboundVariable:
        return "unbound-variable";
    case ErrorKind.typeError:
        return "type-error";
    case ErrorKind.arityError:
        return "arity-error";
    case ErrorKind.divisionByZero:
        return "division-by-zero";
    case ErrorKind.userError:
        return "user-error";
    }
}

/// Thrown when a Scheme program hits a runtime error.
class SchemeError : Exception
{
    ErrorKind kind;
    this(ErrorKind kind, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(categoryName(kind), file, line);
        this.kind = kind;
    }
}

/// Thrown by the reader/analyzer for malformed programs.
class SyntaxError : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}
