/// Unit tests for mdiff.protocol: the stdin/stdout contract of the CLI.
module tests.test_protocol;

import std.exception : assertThrown;
import mdiff.errors;
import mdiff.protocol;

unittest // mdiff paper example (cost 5 => 9 script lines with 4 keeps)
{
    auto out_ = process("diff\n7\na\nb\nc\na\nb\nb\na\n6\nc\nb\na\nb\na\nc\n");
    assert(out_[0 .. 2] == "9\n");
}

unittest // empty files
{
    assert(process("diff\n0\n0\n") == "0\n");
    assert(process("diff\n0\n2\nx\ny\n") == "2\n+x\n+y\n");
    assert(process("patch\n0\n0\n") == "0\n");
}

unittest // patch example from the specification
{
    auto got = process("patch\n5\na\nb\nc\nd\ne\n8\n a\n-b\n+B\n c\n+c2\n-d\n e\n+f\n");
    assert(got == "6\na\nB\nc\nc2\ne\nf\n");
}

unittest // whitespace is preserved byte for byte
{
    auto got = process("patch\n1\n  x \n3\n   x \n+ \n+\t\n");
    assert(got == "3\n  x \n \n\t\n");
}

unittest // leniencies: CRLF, no final newline, trailing blanks on counts, extra empty lines
{
    assert(process("diff\r\n1\r\na\r\n1 \t\r\nb") == "2\n-a\n+b\n");
    assert(process("diff\n1\na\n1\na\n\n\n") == "1\n a\n");
}

unittest // a content line that looks like a count is still content
{
    assert(process("diff\n2\n5\n1\n2\n1\n5\n") == "3\n-5\n 1\n+5\n"
        || process("diff\n2\n5\n1\n2\n1\n5\n") == "3\n 5\n-1\n+5\n");
}

unittest // errors
{
    assertThrown!FormatException(process(""));
    assertThrown!FormatException(process("merge\n0\n0\n"));
    assertThrown!FormatException(process("diff\n2\na\n"));
    assertThrown!FormatException(process("diff\n1\na\n1\nb\njunk\n"));
    assertThrown!FormatException(process("diff\n+1\na\n"));
    assertThrown!PatchException(process("patch\n1\na\n1\n-b\n"));
}
