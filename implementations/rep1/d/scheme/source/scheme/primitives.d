/**
 * The built-in procedures.
 *
 * Each primitive receives its evaluated arguments; the evaluator has already
 * checked the argument count, so a primitive only checks argument types.
 */
module scheme.primitives;

import scheme.numeric;
import scheme.output;
import scheme.printer;
import scheme.value;

private enum anyCount = size_t.max;

/// Define every standard primitive in the global environment of `symbols`.
void installPrimitives(SymbolTable symbols)
{
    void def(string name, PrimFn fn, size_t lo, size_t hi = anyCount, bool isApply = false)
    {
        auto sym = symbols.intern(name);
        sym.value = Value.fromPrimitive(new Primitive(name, fn, lo, hi, isApply));
        sym.bound = true;
    }

    def("+", &plus, 0);
    def("*", &times, 0);
    def("-", &minus, 1);
    def("quotient", &quotientPrim, 2, 2);
    def("remainder", &remainderPrim, 2, 2);
    def("=", &compareChain!"==", 2);
    def("<", &compareChain!"<", 2);
    def(">", &compareChain!">", 2);
    def("<=", &compareChain!"<=", 2);
    def(">=", &compareChain!">=", 2);

    def("cons", &consPrim, 2, 2);
    def("car", &carPrim, 1, 1);
    def("cdr", &cdrPrim, 1, 1);
    def("list", &listPrim, 0);
    def("null?", &isNull, 1, 1);
    def("pair?", &isPair, 1, 1);

    def("not", &notPrim, 1, 1);
    def("number?", &isNumber, 1, 1);
    def("boolean?", &isBoolean, 1, 1);
    def("string?", &isString, 1, 1);
    def("symbol?", &isSymbol, 1, 1);
    def("procedure?", &isProcedure, 1, 1);
    def("eq?", &eqPrim, 2, 2);
    def("equal?", &equalPrim, 2, 2);

    def("apply", &applyPrim, 2, anyCount, true);
    def("error", &errorPrim, 0);

    def("string-append", &stringAppend, 0);
    def("string-length", &stringLength, 1, 1);
    def("number->string", &numberToString, 1, 1);
    def("symbol->string", &symbolToString, 1, 1);

    def("display", &displayPrim, 1, 1);
    def("newline", &newlinePrim, 0, 0);
}

private SchemeError typeError()
{
    return new SchemeError(ErrorKind.typeError);
}

private void requireIntegers(Value[] args)
{
    foreach (a; args)
        if (!a.isInteger)
            throw typeError();
}

private Value plus(Value[] args, Output)
{
    requireIntegers(args);
    Value acc = Value.fromInt(0);
    foreach (a; args)
        acc = add(acc, a);
    return acc;
}

private Value times(Value[] args, Output)
{
    requireIntegers(args);
    Value acc = Value.fromInt(1);
    foreach (a; args)
        acc = mul(acc, a);
    return acc;
}

private Value minus(Value[] args, Output)
{
    requireIntegers(args);
    if (args.length == 1)
        return sub(Value.fromInt(0), args[0]);
    Value acc = args[0];
    foreach (a; args[1 .. $])
        acc = sub(acc, a);
    return acc;
}

private Value quotientPrim(Value[] args, Output)
{
    requireIntegers(args);
    if (isZero(args[1]))
        throw new SchemeError(ErrorKind.divisionByZero);
    return quotient(args[0], args[1]);
}

private Value remainderPrim(Value[] args, Output)
{
    requireIntegers(args);
    if (isZero(args[1]))
        throw new SchemeError(ErrorKind.divisionByZero);
    return remainder(args[0], args[1]);
}

private Value compareChain(string op)(Value[] args, Output)
{
    requireIntegers(args);
    foreach (i; 0 .. args.length - 1)
        if (!mixin("compare(args[i], args[i + 1]) " ~ op ~ " 0"))
            return Value.fromBool(false);
    return Value.fromBool(true);
}

private Value consPrim(Value[] args, Output)
{
    return Value.cons(args[0], args[1]);
}

private Value carPrim(Value[] args, Output)
{
    if (args[0].kind != Kind.pair)
        throw typeError();
    return args[0].pair.car;
}

private Value cdrPrim(Value[] args, Output)
{
    if (args[0].kind != Kind.pair)
        throw typeError();
    return args[0].pair.cdr;
}

private Value listPrim(Value[] args, Output)
{
    return listFromArray(args);
}

private Value isNull(Value[] args, Output)
{
    return Value.fromBool(args[0].kind == Kind.nil);
}

private Value isPair(Value[] args, Output)
{
    return Value.fromBool(args[0].kind == Kind.pair);
}

private Value notPrim(Value[] args, Output)
{
    return Value.fromBool(!args[0].isTrue);
}

private Value isNumber(Value[] args, Output)
{
    return Value.fromBool(args[0].isInteger);
}

private Value isBoolean(Value[] args, Output)
{
    return Value.fromBool(args[0].kind == Kind.boolean);
}

private Value isString(Value[] args, Output)
{
    return Value.fromBool(args[0].kind == Kind.string);
}

private Value isSymbol(Value[] args, Output)
{
    return Value.fromBool(args[0].kind == Kind.symbol);
}

private Value isProcedure(Value[] args, Output)
{
    return Value.fromBool(args[0].isProcedure);
}

/// `eq?` semantics: numeric equality for integers, identity for heap objects.
bool isEq(Value a, Value b) @trusted
{
    if (a.isInteger && b.isInteger)
        return compare(a, b) == 0;
    if (a.kind != b.kind)
        return false;
    final switch (a.kind)
    {
    case Kind.nil:
    case Kind.void_:
        return true;
    case Kind.boolean:
        return a.i == b.i;
    case Kind.integer:
    case Kind.bigInteger:
        assert(false);
    case Kind.string:
        return a.str is b.str;
    case Kind.symbol:
        return a.sym is b.sym;
    case Kind.pair:
        return a.pair is b.pair;
    case Kind.closure:
        return a.closure is b.closure;
    case Kind.primitive:
        return a.prim is b.prim;
    }
}

/// `equal?` semantics: structural on pairs and strings, `eq?` otherwise.
bool isEqual(Value a, Value b) @trusted
{
    for (;;)
    {
        if (a.kind == Kind.pair && b.kind == Kind.pair)
        {
            if (a.pair is b.pair)
                return true;
            if (!isEqual(a.pair.car, b.pair.car))
                return false;
            a = a.pair.cdr;
            b = b.pair.cdr;
            continue;
        }
        if (a.kind == Kind.string && b.kind == Kind.string)
            return a.str.s == b.str.s;
        return isEq(a, b);
    }
}

private Value eqPrim(Value[] args, Output)
{
    return Value.fromBool(isEq(args[0], args[1]));
}

private Value equalPrim(Value[] args, Output)
{
    return Value.fromBool(isEqual(args[0], args[1]));
}

private Value applyPrim(Value[] args, Output)
{
    // The evaluator performs `apply` itself so that the call is a tail call;
    // this body is only reached if someone invokes the function pointer directly.
    assert(false, "apply is handled by the evaluator");
}

private Value errorPrim(Value[] args, Output)
{
    throw new SchemeError(ErrorKind.userError);
}

private Value stringAppend(Value[] args, Output)
{
    string r;
    foreach (a; args)
    {
        if (a.kind != Kind.string)
            throw typeError();
        r ~= a.str.s;
    }
    return Value.fromString(r);
}

private Value stringLength(Value[] args, Output)
{
    if (args[0].kind != Kind.string)
        throw typeError();
    return Value.fromInt(cast(long) args[0].str.s.length);
}

private Value numberToString(Value[] args, Output)
{
    if (!args[0].isInteger)
        throw typeError();
    return Value.fromString(integerToString(args[0]));
}

private Value symbolToString(Value[] args, Output)
{
    if (args[0].kind != Kind.symbol)
        throw typeError();
    return Value.fromString(args[0].sym.name);
}

private Value displayPrim(Value[] args, Output output)
{
    printValue(output, args[0], true);
    return Value.void_();
}

private Value newlinePrim(Value[] args, Output output)
{
    output.put('\n');
    return Value.void_();
}
