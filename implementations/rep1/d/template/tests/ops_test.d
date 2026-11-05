module tests.ops_test;

import jtemplate;
import jtemplate.ast : BinOp, CmpOp;
import jtemplate.ops;

private Value I(long n) { return Value.fromInt(n); }
private Value F(double d) { return Value.fromFloat(d); }
private Value S(string s) { return Value.fromString(s); }

private ErrorKind errorOf(lazy Value v)
{
    try v();
    catch (TemplateError e) return e.kind;
    assert(0, "expected an error");
}

unittest // integer arithmetic stays integral
{
    assert(binaryOp(BinOp.add, I(2), I(3)).i == 5);
    assert(binaryOp(BinOp.mul, I(4), Value.fromBool(true)).kind == Kind.integer);
    assert(binaryOp(BinOp.pow, I(2), I(10)).i == 1024);
    assert(binaryOp(BinOp.pow, I(2), I(-1)).d == 0.5);
}

unittest // division always floats; floor division and modulo follow the divisor
{
    assert(binaryOp(BinOp.div, I(6), I(3)).kind == Kind.floating);
    assert(binaryOp(BinOp.floorDiv, I(-7), I(2)).i == -4);
    assert(binaryOp(BinOp.mod, I(-7), I(3)).i == 2);
    assert(binaryOp(BinOp.mod, I(7), I(-3)).i == -2);
    assert(binaryOp(BinOp.floorDiv, F(7.0), I(2)).d == 3.0);
    assert(binaryOp(BinOp.mod, F(-7.5), I(2)).d == 0.5);
}

unittest // division by zero is a type error
{
    assert(errorOf(binaryOp(BinOp.div, I(1), I(0))) == ErrorKind.type);
    assert(errorOf(binaryOp(BinOp.floorDiv, I(1), F(0.0))) == ErrorKind.type);
    assert(errorOf(binaryOp(BinOp.mod, I(1), I(0))) == ErrorKind.type);
}

unittest // strings and lists
{
    assert(binaryOp(BinOp.add, S("a"), S("b")).s == "ab");
    assert(binaryOp(BinOp.mul, S("ab"), I(3)).s == "ababab");
    assert(binaryOp(BinOp.mul, I(-1), S("ab")).s == "");
    assert(binaryOp(BinOp.concat, I(1), S("x")).s == "1x");
    auto l = binaryOp(BinOp.add, Value.fromList([I(1)]), Value.fromList([I(2)]));
    assert(l.list.length == 2 && l.list[1].i == 2);
    assert(errorOf(binaryOp(BinOp.add, S("a"), I(1))) == ErrorKind.type);
}

unittest // undefined operands
{
    assert(errorOf(binaryOp(BinOp.add, Value.undef, I(1))) == ErrorKind.undefined);
    assert(errorOf(Value.fromBool(valuesEqual(Value.undef, I(1)))) == ErrorKind.undefined);
    assert(errorOf(Value.fromBool(truthy(Value.undef))) == ErrorKind.undefined);
}

unittest // equality
{
    assert(valuesEqual(I(1), F(1.0)));
    assert(valuesEqual(Value.fromBool(true), I(1)));
    assert(!valuesEqual(I(1), S("1")));
    assert(!valuesEqual(Value.nil, I(0)));
    assert(valuesEqual(Value.nil, Value.nil));
    assert(valuesEqual(Value.fromList([I(1), S("a")]), Value.fromList([F(1.0), S("a")])));
    assert(!valuesEqual(Value.fromList([I(1)]), Value.fromList([I(1), I(2)])));
}

unittest // ordering
{
    assert(compareOp(CmpOp.lt, I(1), F(1.5)));
    assert(compareOp(CmpOp.lt, S("ab"), S("abc")));
    assert(compareOp(CmpOp.ge, S("b"), S("a")));
    assert(errorOf(Value.fromBool(compareOp(CmpOp.lt, S("a"), I(1)))) == ErrorKind.type);
}

unittest // membership
{
    assert(compareOp(CmpOp.in_, S("b"), S("abc")));
    assert(compareOp(CmpOp.in_, S(""), S("abc")));
    assert(compareOp(CmpOp.notIn, I(3), Value.fromList([I(1), I(2)])));
    assert(errorOf(Value.fromBool(compareOp(CmpOp.in_, I(1), S("abc")))) == ErrorKind.type);
    assert(errorOf(Value.fromBool(compareOp(CmpOp.in_, I(1), I(2)))) == ErrorKind.type);
}

unittest // truthiness
{
    assert(!truthy(Value.nil) && !truthy(I(0)) && !truthy(F(0.0)) && !truthy(S("")));
    assert(!truthy(Value.fromList(null)) && !truthy(Value.fromDict(new DictObj)));
    assert(truthy(I(-1)) && truthy(S("x")) && truthy(Value.fromList([I(0)])));
}

unittest // subscripts
{
    auto l = Value.fromList([I(10), I(20), I(30)]);
    assert(getItem(l, I(-1)).i == 30);
    assert(getItem(l, I(3)).isUndefined);
    assert(getItem(l, S("a")).isUndefined);
    assert(getItem(S("héllo"), I(1)).s == "é");
    assert(getItem(S("héllo"), I(-1)).s == "o");
    assert(getItem(I(5), S("x")).isUndefined);
    assert(errorOf(getItem(Value.undef, S("x"))) == ErrorKind.undefined);
}

unittest // sequence views
{
    assert(sequenceView(S("aé")).length == 2);
    auto d = new DictObj;
    d.put("x", I(1)); d.put("y", I(2));
    auto keys = sequenceView(Value.fromDict(d));
    assert(keys[0].s == "x" && keys[1].s == "y");
    assert(errorOf(Value.fromList(sequenceView(I(3)))) == ErrorKind.type);
}
