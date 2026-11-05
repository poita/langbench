/// Unit tests for regexvm.compiler: the shape of the emitted programs.
module regexvm.test_compiler;

import std.algorithm : canFind, count;
import regexvm.compiler;
import regexvm.parser;
import regexvm.program;

private Program prog(string p) { return compile(parse(p)); }

private size_t countOp(const Program p, Op op)
{
    return p.code.count!(i => i.op == op);
}

unittest // plain sequence
{
    auto p = prog("ab");
    assert(disassemble(p) == "0: char a\n1: char b\n2: match\n");
}

unittest // alternation: preferred branch first
{
    auto p = prog("a|b");
    assert(disassemble(p) ==
        "0: split 1, 3\n1: char a\n2: jmp 4\n3: char b\n4: match\n");
}

unittest // groups save both ends
{
    auto p = prog("(a)");
    assert(disassemble(p) == "0: save 0\n1: char a\n2: save 1\n3: match\n");
    assert(p.groupCount == 1);
}

unittest // single-character atoms compile to one loop instruction
{
    assert(disassemble(prog("a*")) == "0: charloop a {0,-1}\n1: match\n");
    assert(disassemble(prog(".+")) == "0: anyloop {1,-1}\n1: match\n");
    assert(disassemble(prog("[a-c]{2,5}")) == "0: setloop 0 {2,5}\n1: match\n");
    assert(disassemble(prog("a{0}b")) == "0: char b\n1: match\n");
}

unittest // mark/check only for bodies that can match empty
{
    auto plain = prog("(ab)*");
    assert(countOp(plain, Op.mark) == 0 && countOp(plain, Op.check) == 0);
    assert(plain.registerCount == 0);

    auto guarded = prog("(a*)*");
    assert(countOp(guarded, Op.mark) == 1 && countOp(guarded, Op.check) == 1);
    assert(guarded.registerCount == 1);
}

unittest // counted repetition of a group expands
{
    auto p = prog("(ab){3}");
    assert(countOp(p, Op.save) == 6);
    assert(countOp(p, Op.split) == 0);

    auto q = prog("(ab){1,3}");
    assert(countOp(q, Op.save) == 6);
    assert(countOp(q, Op.split) == 2);

    auto z = prog("(ab){0}");
    assert(z.code.length == 1);
}

unittest // start filters
{
    auto p = prog("^abc");
    assert(p.anchored && !p.filterStarts);

    p = prog("abc|xyz");
    assert(!p.anchored && p.filterStarts);
    assert(p.first.count == 2 && p.first.contains('a') && p.first.contains('x'));

    p = prog("a*");      // nullable: every position can match
    assert(!p.filterStarts);
    p = prog(".a");      // first set is "any": no point filtering
    assert(!p.filterStarts);
}

unittest // runaway expansion is rejected
{
    import std.exception : assertThrown;
    import regexvm.errors;
    assertThrown!RegexException(prog("((((a{100}){100}){100}){100}){100}"));
}
