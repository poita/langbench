module test_vec;

import textbuffer.vec;

unittest
{
    CharBuf b;
    b.put("abc");
    b.put('d');
    b.putDecimal(0);
    b.putDecimal(1234567);
    assert(b[] == "abcd01234567");
    b.clear();
    assert(b.empty);
    b.put("x");
    assert(b[] == "x");
}

unittest
{
    Vec!int v;
    foreach (i; 0 .. 1000)
        v.put(i);
    assert(v.length == 1000);
    assert(v[999] == 999);
    v.truncate(10);
    assert(v.length == 10);
    v.put([7, 8, 9]);
    assert(v[] == [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 7, 8, 9]);
}
