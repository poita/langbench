module tests.test_strings;

import tests.helpers;
import toml;

private string str(string s) { return scalar("string", s); }

unittest // basic and literal strings
{
    assert(decode(`a = "hi\tthere"`) == `{"a":` ~ str(`hi\tthere`) ~ `}`);
    assert(decode(`a = 'C:\path'`) == `{"a":` ~ str(`C:\\path`) ~ `}`);
    assert(decode(`a = "\u00e9\U0001F600"`) == "{\"a\":" ~ str("é😀") ~ "}");
    assert(decode(`a = "\u0000"`) == `{"a":` ~ str(`\u0000`) ~ `}`);
    assert(rejects("a = \"\u007f\""));
    assert(decode(`a = ""`) == `{"a":` ~ str("") ~ `}`);
}

unittest // invalid strings
{
    foreach (bad; [`a = "\x41"`, `a = "\ud800"`, `a = "\U00110000"`, `a = "\u12"`, `a = "abc`,
                   "a = \"x\ny\"", "a = 'x\ny'", "a = \"\x01\"", "a = 'x\x7f'", "a = \"\\\n\"",
                   "a = \"x\ry\"", `a = "\q"`, `a = "\e"`])
        assert(rejects(bad), bad);
}

unittest // multi-line strings
{
    assert(decode("a = \"\"\"\nline1\nline2\"\"\"") == `{"a":` ~ str(`line1\nline2`) ~ `}`);
    assert(decode("a = \"\"\"\r\nx\r\ny\"\"\"") == `{"a":` ~ str(`x\ny`) ~ `}`);
    assert(decode("a = \"\"\"a \\\n   b\"\"\"") == `{"a":` ~ str("a b") ~ `}`);
    assert(decode("a = \"\"\"a \\  \n\n  b\"\"\"") == `{"a":` ~ str("a b") ~ `}`);
    assert(decode("a = \"\"\"x\"\"\"\"") == `{"a":` ~ str(`x\"`) ~ `}`);
    assert(decode("a = \"\"\"x\"\"\"\"\"") == `{"a":` ~ str(`x\"\"`) ~ `}`);
    assert(decode("a = '''\nraw \\n\n'''") == `{"a":` ~ str(`raw \\n\n`) ~ `}`);
    assert(decode("a = '''x'''''") == `{"a":` ~ str("x''") ~ `}`);
    assert(rejects("a = \"\"\"x\"\"\"\"\"\""));
    assert(rejects("a = '''x''''''"));
    assert(rejects("a = \"\"\"abc"));
}

unittest // keys are compared decoded
{
    assert(rejects("a = 1\n\"a\" = 2"));
    assert(rejects("a = 1\n'a' = 2"));
    assert(decode("\"\" = 1") == `{"":` ~ scalar("integer", "1") ~ `}`);
    assert(rejects(`"""a""" = 1`));
}
