module tests.value_test;

import minisql.value;

unittest // total order
{
    immutable n = Value.makeNull();
    immutable one = Value.makeInt(1);
    immutable two = Value.makeInt(2);
    immutable a = Value.makeText("a");
    immutable ab = Value.makeText("ab");
    assert(compareValues(n, one) < 0);
    assert(compareValues(n, n) == 0);
    assert(compareValues(one, two) < 0);
    assert(compareValues(Value.makeInt(100), Value.makeText("0")) < 0);
    assert(compareValues(a, ab) < 0);
    assert(compareValues(Value.makeText("B"), a) < 0);
    assert(compareValues(Value.makeText(""), a) < 0);
}

unittest // reals compare with integers by value
{
    assert(compareValues(Value.makeInt(2), Value.makeReal(200)) == 0);
    assert(compareValues(Value.makeInt(2), Value.makeReal(201)) < 0);
    assert(compareValues(Value.makeReal(150), Value.makeInt(1)) > 0);
    assert(compareValues(Value.makeReal(-150), Value.makeInt(-1)) < 0);
}

unittest // same value includes the type tag
{
    assert(!sameValue(Value.makeInt(1), Value.makeText("1")));
    assert(sameValue(Value.makeNull(), Value.makeNull()));
    assert(hashValue(Value.makeText("x")) == hashValue(Value.makeText("x")));
}

unittest // display
{
    assert(toDisplay(Value.makeNull()) == "NULL");
    assert(toDisplay(Value.makeInt(0)) == "0");
    assert(toDisplay(Value.makeInt(-42)) == "-42");
    assert(toDisplay(Value.makeInt(long.min)) == "-9223372036854775808");
    assert(toDisplay(Value.makeText("hi there")) == "hi there");
    assert(toDisplay(Value.makeReal(450)) == "4.50");
    assert(toDisplay(Value.makeReal(-113)) == "-1.13");
    assert(toDisplay(Value.makeReal(0)) == "0.00");
    assert(toDisplay(Value.makeReal(5)) == "0.05");
}
