module tests.format_test;

import jtemplate;
import jtemplate.buffer : OutBuf;

private string fmt(double x)
{
    OutBuf b;
    putFloat(b, x);
    return b.take();
}

unittest // positional notation
{
    assert(fmt(3.0) == "3.0");
    assert(fmt(0.5) == "0.5");
    assert(fmt(-2.25) == "-2.25");
    assert(fmt(1000000000000000.0) == "1000000000000000.0");
    assert(fmt(0.0001) == "0.0001");
    assert(fmt(0.1 + 0.2) == "0.30000000000000004");
    assert(fmt(123456789.12345679) == "123456789.12345679");
}

unittest // zero and negative zero
{
    assert(fmt(0.0) == "0.0");
    assert(fmt(-0.0) == "-0.0");
}

unittest // scientific notation
{
    assert(fmt(1e16) == "1e+16");
    assert(fmt(1e-5) == "1e-05");
    assert(fmt(1.5e300) == "1.5e+300");
    assert(fmt(2.5e-5) == "2.5e-05");
    assert(fmt(1.7976931348623157e308) == "1.7976931348623157e+308");
    assert(fmt(double.min_normal / 4503599627370496.0) == "5e-324");
}

unittest // shortest round-trip digits
{
    assert(fmt(100.0 / 3) == "33.333333333333336");
    assert(fmt(0.3) == "0.3");
    assert(fmt(2.0 / 3) == "0.6666666666666666");
    assert(fmt(9007199254740993.0) == "9007199254740992.0");
}

unittest // printing of values
{
    auto d = new DictObj;
    d.put("k", Value.fromList([Value.fromFloat(2.0), Value.nil, Value.fromBool(true)]));
    assert(toStr(Value.fromDict(d)) == "{'k': [2.0, None, True]}");
    assert(toStr(Value.fromString("x")) == "x");
    assert(toStr(Value.fromInt(-7)) == "-7");
}

unittest // repr of strings picks the quote like Python
{
    auto l = (string s) => toStr(Value.fromList([Value.fromString(s)]));
    assert(l("plain") == "['plain']");
    assert(l("it's") == `["it's"]`);
    assert(l(`say "hi"`) == `['say "hi"']`);
    assert(l(`both ' and "`) == `['both \' and "']`);
    assert(l("a\\b\n\r\t") == `['a\\b\n\r\t']`);
}

unittest // the undefined value cannot be printed
{
    bool threw;
    try toStr(Value.undef);
    catch (TemplateError e) threw = e.kind == ErrorKind.undefined;
    assert(threw);
}
