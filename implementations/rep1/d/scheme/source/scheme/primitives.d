/// The built-in procedures.
module scheme.primitives;

import std.array : appender;
import scheme.errors;
import scheme.numeric;
import scheme.output;
import scheme.printer;
import scheme.symbols;
import scheme.value;

/// What primitives may touch besides their arguments.
final class Context
{
    SymbolTable syms;
    Output output;

    this(SymbolTable s, Output o) { syms = s; output = o; }
}

/// Signature of a primitive implementation. Arity has already been checked.
alias PrimFn = Value function(Value[] args, Context cx);

/// A primitive's name, accepted argument counts (`maxArgs < 0`: no limit)
/// and implementation. `apply` has a null `fn`: the evaluator handles it.
struct PrimDef
{
    string name;
    int minArgs;
    int maxArgs;
    PrimFn fn;
}

/// Name of the one primitive the evaluator implements itself.
enum applyName = "apply";

/// The table of all primitives; the index is the primitive id.
PrimDef[] makePrimitives()
{
    return [
        PrimDef("+", 0, -1, &primAdd),
        PrimDef("*", 0, -1, &primMul),
        PrimDef("-", 1, -1, &primSub),
        PrimDef("quotient", 2, 2, &primQuotient),
        PrimDef("remainder", 2, 2, &primRemainder),
        PrimDef("=", 2, -1, &primNumEq),
        PrimDef("<", 2, -1, &primLt),
        PrimDef(">", 2, -1, &primGt),
        PrimDef("<=", 2, -1, &primLe),
        PrimDef(">=", 2, -1, &primGe),
        PrimDef("cons", 2, 2, &primCons),
        PrimDef("car", 1, 1, &primCar),
        PrimDef("cdr", 1, 1, &primCdr),
        PrimDef("list", 0, -1, &primList),
        PrimDef("null?", 1, 1, &primNullP),
        PrimDef("pair?", 1, 1, &primPairP),
        PrimDef("not", 1, 1, &primNot),
        PrimDef("number?", 1, 1, &primNumberP),
        PrimDef("boolean?", 1, 1, &primBooleanP),
        PrimDef("string?", 1, 1, &primStringP),
        PrimDef("symbol?", 1, 1, &primSymbolP),
        PrimDef("procedure?", 1, 1, &primProcedureP),
        PrimDef("eq?", 2, 2, &primEq),
        PrimDef("equal?", 2, 2, &primEqual),
        PrimDef(applyName, 2, -1, null),
        PrimDef("error", 0, -1, &primError),
        PrimDef("string-append", 0, -1, &primStringAppend),
        PrimDef("string-length", 1, 1, &primStringLength),
        PrimDef("number->string", 1, 1, &primNumberToString),
        PrimDef("symbol->string", 1, 1, &primSymbolToString),
        PrimDef("display", 1, 1, &primDisplay),
        PrimDef("newline", 0, 0, &primNewline),
    ];
}

/// `eq?`: numeric equality for integers, identity for everything else.
bool isEq(Value a, Value b)
{
    if (a.tag != b.tag)
        return false;
    final switch (a.tag)
    {
    case Tag.unbound:
    case Tag.nil:
    case Tag.voidValue:
        return true;
    case Tag.fixnum:
    case Tag.boolean:
    case Tag.symbol:
    case Tag.prim:
        return a.i == b.i;
    case Tag.pair:
    case Tag.str:
    case Tag.closure:
        return a.p == b.p;
    case Tag.big:
        return compare(a, b) == 0;
    }
}

/// `equal?`: structural on pairs and strings, `eq?` otherwise.
bool isEqual(Value a, Value b)
{
    for (;;)
    {
        if (a.tag == Tag.pair && b.tag == Tag.pair)
        {
            if (!isEqual(a.pair.car, b.pair.car))
                return false;
            a = a.pair.cdr;
            b = b.pair.cdr;
            continue;
        }
        if (a.tag == Tag.str && b.tag == Tag.str)
            return a.strObj.s == b.strObj.s;
        return isEq(a, b);
    }
}

private:

void checkInts(const Value[] args)
{
    foreach (a; args)
        if (!a.isInteger)
            typeError();
}

Value primAdd(Value[] args, Context)
{
    checkInts(args);
    Value acc = Value.fixnum(0);
    foreach (a; args)
        acc = add(acc, a);
    return acc;
}

Value primMul(Value[] args, Context)
{
    checkInts(args);
    Value acc = Value.fixnum(1);
    foreach (a; args)
        acc = mul(acc, a);
    return acc;
}

Value primSub(Value[] args, Context)
{
    checkInts(args);
    if (args.length == 1)
        return sub(Value.fixnum(0), args[0]);
    Value acc = args[0];
    foreach (a; args[1 .. $])
        acc = sub(acc, a);
    return acc;
}

Value primQuotient(Value[] args, Context)
{
    checkInts(args);
    if (isZero(args[1]))
        raise(ErrorKind.divisionByZero);
    return quotient(args[0], args[1]);
}

Value primRemainder(Value[] args, Context)
{
    checkInts(args);
    if (isZero(args[1]))
        raise(ErrorKind.divisionByZero);
    return remainder(args[0], args[1]);
}

Value chain(string op)(Value[] args)
{
    checkInts(args);
    foreach (k; 1 .. args.length)
        if (!mixin("compare(args[k - 1], args[k]) " ~ op ~ " 0"))
            return Value.false_;
    return Value.true_;
}

Value primNumEq(Value[] args, Context) { return chain!"=="(args); }
Value primLt(Value[] args, Context) { return chain!"<"(args); }
Value primGt(Value[] args, Context) { return chain!">"(args); }
Value primLe(Value[] args, Context) { return chain!"<="(args); }
Value primGe(Value[] args, Context) { return chain!">="(args); }

Value primCons(Value[] args, Context) { return Value.cons(args[0], args[1]); }

Value primCar(Value[] args, Context)
{
    if (args[0].tag != Tag.pair)
        typeError();
    return args[0].pair.car;
}

Value primCdr(Value[] args, Context)
{
    if (args[0].tag != Tag.pair)
        typeError();
    return args[0].pair.cdr;
}

Value primList(Value[] args, Context) { return listFrom(args); }
Value primNullP(Value[] args, Context) { return Value.boolean(args[0].tag == Tag.nil); }
Value primPairP(Value[] args, Context) { return Value.boolean(args[0].tag == Tag.pair); }
Value primNot(Value[] args, Context) { return Value.boolean(!args[0].truthy); }
Value primNumberP(Value[] args, Context) { return Value.boolean(args[0].isInteger); }
Value primBooleanP(Value[] args, Context) { return Value.boolean(args[0].tag == Tag.boolean); }
Value primStringP(Value[] args, Context) { return Value.boolean(args[0].tag == Tag.str); }
Value primSymbolP(Value[] args, Context) { return Value.boolean(args[0].tag == Tag.symbol); }
Value primProcedureP(Value[] args, Context)
{
    return Value.boolean(args[0].tag == Tag.prim || args[0].tag == Tag.closure);
}
Value primEq(Value[] args, Context) { return Value.boolean(isEq(args[0], args[1])); }
Value primEqual(Value[] args, Context) { return Value.boolean(isEqual(args[0], args[1])); }

Value primError(Value[] args, Context) { raise(ErrorKind.userError); }

Value primStringAppend(Value[] args, Context)
{
    foreach (a; args)
        if (a.tag != Tag.str)
            typeError();
    if (args.length == 1)
        return args[0];
    auto buf = appender!string();
    foreach (a; args)
        buf.put(a.strObj.s);
    return Value.str(buf.data);
}

Value primStringLength(Value[] args, Context)
{
    if (args[0].tag != Tag.str)
        typeError();
    return Value.fixnum(cast(long) args[0].strObj.s.length);
}

Value primNumberToString(Value[] args, Context)
{
    if (!args[0].isInteger)
        typeError();
    return Value.str(toDecimal(args[0]));
}

Value primSymbolToString(Value[] args, Context cx)
{
    if (args[0].tag != Tag.symbol)
        typeError();
    return Value.str(cx.syms.name(cast(int) args[0].i));
}

Value primDisplay(Value[] args, Context cx)
{
    print(cx.output, cx.syms, args[0], true);
    return Value.voidValue;
}

Value primNewline(Value[] args, Context cx)
{
    cx.output.put('\n');
    return Value.voidValue;
}
