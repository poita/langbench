/// Unit tests for scheme.reader and scheme.printer.
module reader_test;

import scheme.output;
import scheme.printer;
import scheme.reader;
import scheme.symbols;
import scheme.value;

private string[] readAll(string src, bool display = false)
{
    auto syms = new SymbolTable;
    auto rd = Reader(src, syms);
    string[] r;
    Value v;
    while (rd.next(v))
    {
        auto o = new Output;
        print(o, syms, v, display);
        r ~= o.data.idup;
    }
    return r;
}

unittest
{
    assert(readAll("") == []);
    assert(readAll("  ; just a comment\n  ") == []);
    assert(readAll("42 -7 +5 007 -0") == ["42", "-7", "5", "7", "0"]);
    assert(readAll("#t #f") == ["#t", "#f"]);
    assert(readAll("+ - ... 1+ a.b Foo foo") == ["+", "-", "...", "1+", "a.b", "Foo", "foo"]);
}

unittest // big integers
{
    assert(readAll("123456789012345678901234567890")
            == ["123456789012345678901234567890"]);
    assert(readAll("-9223372036854775808") == ["-9223372036854775808"]);
    assert(readAll("9223372036854775808") == ["9223372036854775808"]);
}

unittest // lists and quote
{
    assert(readAll("()") == ["()"]);
    assert(readAll("(1 2 3)") == ["(1 2 3)"]);
    assert(readAll("(1 2 . 3)") == ["(1 2 . 3)"]);
    assert(readAll("((1 2) (3 . 4) ())") == ["((1 2) (3 . 4) ())"]);
    assert(readAll("'a") == ["(quote a)"]);
    assert(readAll("''a") == ["(quote (quote a))"]);
    assert(readAll("'(1 . (2 . (3 . ())))") == ["(quote (1 2 3))"]);
    assert(readAll("(a;comment\n b)") == ["(a b)"]);
}

unittest // strings
{
    assert(readAll(`"a\"b\\c\nd\te"`) == [`"a\"b\\c\nd\te"`]);
    assert(readAll(`"a\"b\\c\nd\te"`, true) == ["a\"b\\c\nd\te"]);
    assert(readAll("\"raw\nnewline\"", true) == ["raw\nnewline"]);
    assert(readAll(`'("x" y)`, true) == ["(quote (x y))"]);
}
