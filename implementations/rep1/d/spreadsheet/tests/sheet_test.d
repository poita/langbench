module tests.sheet_test;

import std.exception : assertThrown;

import spreadsheet;

/// Run a script and return what it prints.
private string run(string script)
{
    import std.array : appender;
    auto out_ = appender!string();
    executeScript(new Sheet, script, out_);
    return out_.data;
}

/// Evaluate a formula in cell Q1 of a sheet pre-loaded with `setup`.
private string eval(string formula, string setup = "")
{
    return run(setup ~ "set Q1 " ~ formula ~ "\nget Q1\n");
}

unittest // basics
{
    auto s = new Sheet;
    assert(s.get("A1").kind == Kind.empty);
    assert(s.display("A1") == "");
    s.set("A1", "10");
    s.set("A2", "32");
    s.set("A3", "=A1+A2");
    assert(s.display("A3") == "42");
    s.set("A1", "5");
    assert(s.display("A3") == "37");
    s.clear("A1");
    assert(s.display("A3") == "32");
    assert(s.isEmpty(CellRef(1, 1)));
    assert(s.length == 2);
}

unittest // literals
{
    assert(run("set A1 \"\"\nset A2 \" hi \"\nset A3 -0\nset A4 4.50\nget A1\nget A2\nget A3\nget A4\n")
        == "\n hi \n0\n4.5\n");
    assert(run("set A1 \"\"\ndump") == "A1 \n");
    assert(run("dump") == "");
}

unittest // example 1: cycles come and go
{
    assert(run("set A1 10\nset A2 32\nset A3 =A1+A2\nget A3\nset A1 =A3\nget A1\nget A3\n"
        ~ "set A1 5\nget A3\ndump\n") == "42\n#CYCLE!\n#CYCLE!\n37\nA1 5\nA2 32\nA3 37\n");
}

unittest // example 2: row-major dump, ranges, IF, error propagation
{
    string got = run(`set A1 "Total"
set B1 3
set B2 4.5
set B3 "x"
set C1 =SUM(B1:B3)
set C2 =A1&": "&C1
set C3 =IF(C1>7, "big", "small")
set C4 =AVG(B1:B3)
set C5 =COUNT(B1:B3)
set C6 =B1/(B2-4.5)
set C7 =C6+1
set C8 =1/3
dump
`);
    assert(got == "A1 Total\nB1 3\nC1 7.5\nB2 4.5\nC2 Total: 7.5\nB3 x\nC3 big\nC4 3.75\n"
        ~ "C5 2\nC6 #DIV/0!\nC7 #DIV/0!\nC8 0.3333333333\n");
}

unittest // precedence and associativity
{
    assert(eval("=1+2*3") == "7\n");
    assert(eval("=(1+2)*3") == "9\n");
    assert(eval("=-2*3-4") == "-10\n");
    assert(eval("=2*-3") == "-6\n");
    assert(eval("=1<2+3") == "1\n");
    assert(eval("=1+2&3") == "33\n");
    assert(eval("=--5") == "5\n");
    assert(eval("=10-4-3") == "3\n");
    assert(eval("=8/4/2") == "1\n");
    assert(eval("=1<2<3") == "1\n"); // (1<2)<3
    assert(eval("=  1  +  2 ") == "3\n");
}

unittest // arithmetic errors
{
    assert(eval("=1/0") == "#DIV/0!\n");
    assert(eval("=1/(0*-1)") == "#DIV/0!\n");
    assert(eval("=\"5\"+1") == "#VALUE!\n");
    assert(eval("=-\"a\"") == "#VALUE!\n");
    // overflow to infinity is #VALUE!
    import std.array : replicate;
    string big = "set A1 1" ~ "0".replicate(300) ~ "\nset A2 =A1*A1\n";
    assert(run(big ~ "get A2\n") == "#VALUE!\n");
    assert(run(big ~ "set A3 =A2+1\nget A3\nset A4 =SUM(A1,A1)*A1\nget A4\n") == "#VALUE!\n#VALUE!\n");
    // first problem in evaluation order wins
    assert(eval("=\"a\"+(1/0)") == "#VALUE!\n");
    assert(eval("=(1/0)+\"a\"") == "#DIV/0!\n");
}

unittest // empty cells
{
    assert(eval("=Z1+1") == "1\n");
    assert(eval("=Z1") == "0\n");
    assert(eval("=(Z1)&\"x\"") == "x\n");
    assert(eval("=IF(1,Z1,7)&\"x\"") == "x\n");
    assert(eval("=(Z1)=\"\"") == "1\n");
    assert(eval("=Z1=0") == "1\n");
    assert(eval("=Z1=Y1") == "1\n");
    assert(eval("=COUNT((Z1))") == "0\n");
    assert(eval("=-Z1&\"x\"") == "0x\n");
    assert(eval("=IF(Z1,1,2)") == "2\n");
}

unittest // comparisons
{
    assert(eval("=1=1") == "1\n");
    assert(eval("=1<>1") == "0\n");
    assert(eval("=\"a\"<\"b\"") == "1\n");
    assert(eval("=\"B\"<\"a\"") == "1\n");
    assert(eval("=\"ab\">\"a\"") == "1\n");
    assert(eval("=\"a\"<=\"a\"") == "1\n");
    assert(eval("=\"a\">=\"b\"") == "0\n");
    assert(eval("=1=\"1\"") == "0\n");
    assert(eval("=1<>\"1\"") == "1\n");
    assert(eval("=1<\"1\"") == "#VALUE!\n");
    assert(eval("=\"1\">=1") == "#VALUE!\n");
    // code point order, not UTF-16 code unit order
    assert(eval("=\"\U0001F600\">\"ｚ\"") == "1\n");
}

unittest // concatenation
{
    assert(eval("=1&2") == "12\n");
    assert(eval("=0.5&\"x\"") == "0.5x\n");
    assert(eval("=1/3&\"\"") == "0.3333333333\n");
    assert(eval("=A1&A1", "set A1 \"ab\"\n") == "abab\n");
    assert(eval("=A1&\"x\"", "set A1 =1/0\n") == "#DIV/0!\n");
}

unittest // IF is lazy for evaluation but not for dependencies
{
    assert(eval("=IF(1,5,1/0)") == "5\n");
    assert(eval("=IF(0,1/0,6)") == "6\n");
    assert(eval("=IF(\"a\",1,2)") == "#VALUE!\n");
    assert(eval("=IF(1/0,1,2)") == "#DIV/0!\n");
    assert(eval("=IF(1,\"s\",2)") == "s\n");
    // the unselected branch still makes a cycle
    assert(run("set A1 =IF(1,5,A1)\nget A1\n") == "#CYCLE!\n");
    // but an unselected cyclic read does not propagate
    assert(run("set B1 =B1\nset A1 =IF(1,5,B1)\nget A1\nget B1\n") == "5\n#CYCLE!\n");
}

unittest // aggregates
{
    string setup = "set A1 1\nset A2 2\nset A3 \"s\"\nset A4 4\n";
    assert(eval("=SUM(A1:A4)", setup) == "7\n");
    assert(eval("=SUM(A4:A1)", setup) == "7\n"); // either corner order
    assert(eval("=MIN(A1:A4)", setup) == "1\n");
    assert(eval("=MAX(A1:A4)", setup) == "4\n");
    assert(eval("=COUNT(A1:A4)", setup) == "3\n");
    assert(eval("=AVG(A1:A4)", setup) == "2.333333333\n");
    assert(eval("=SUM(A1:A2, 10, A4)", setup) == "17\n");
    assert(eval("=SUM(B1:B4)") == "0\n");
    assert(eval("=MIN(B1:B4)") == "0\n");
    assert(eval("=MAX(B1:B4)") == "0\n");
    assert(eval("=AVG(B1:B4)") == "#DIV/0!\n");
    assert(eval("=SUM(A3)", setup) == "#VALUE!\n");      // string expression
    assert(eval("=SUM(\"x\")") == "#VALUE!\n");
    assert(eval("=MAX(-3,-5)") == "-3\n");
    assert(eval("=SUM(A1:B2)", "set A1 1\nset B2 5\n") == "6\n");
    assert(eval("=SUM(B2:A1)", "set A1 1\nset B2 5\n") == "6\n");
    // an error inside a range wins
    assert(eval("=SUM(A1:A3)", "set A1 =1/0\nset A2 \"s\"\nset A3 5\n") == "#DIV/0!\n");
}

unittest // a range containing its own cell is a cycle
{
    assert(run("set A1 =SUM(A1:A3)\nget A1\n") == "#CYCLE!\n");
    assert(run("set A2 =SUM(A1:A3)\nget A2\nset A2 1\nget A2\n") == "#CYCLE!\n1\n");
}

unittest // invalid references
{
    foreach (f; ["=AAA1", "=A0", "=A10000", "=A01", "=1+AAA1", "=SUM(A1:AAA1)", "=IF(1,2,A0)", "=SUM(A0:A1)"])
        assert(eval(f) == "#REF!\n", f);
    // an invalid formula has no dependencies and so can't be cyclic
    assert(run("set A1 =A1+A0\nget A1\n") == "#REF!\n");
}

unittest // cycles
{
    assert(run("set A1 =A1+1\nget A1\n") == "#CYCLE!\n");
    // A1 <-> A2 cycle, A3 reads it, A4 doesn't
    string s = "set A1 =A2\nset A2 =A1\nset A3 =A1+1\nset A4 5\nget A1\nget A2\nget A3\nget A4\n";
    assert(run(s) == "#CYCLE!\n#CYCLE!\n#CYCLE!\n5\n");
    // breaking the cycle revives everything
    assert(run(s ~ "set A2 7\nget A1\nget A2\nget A3\n") == "#CYCLE!\n#CYCLE!\n#CYCLE!\n5\n7\n7\n8\n");
    // clearing breaks the cycle too
    assert(run(s ~ "clear A2\nget A1\nget A3\n") == "#CYCLE!\n#CYCLE!\n#CYCLE!\n5\n0\n1\n");
    // a cycle created through a long chain
    string chain;
    foreach (i; 2 .. 50)
    {
        import std.conv : to;
        chain ~= "set A" ~ i.to!string ~ " =A" ~ (i - 1).to!string ~ "+1\n";
    }
    assert(run("set A1 1\n" ~ chain ~ "get A49\nset A1 =A49\nget A25\nset A1 0\nget A49\n") == "49\n#CYCLE!\n48\n");
}

unittest // dump order and clearing
{
    auto s = new Sheet;
    s.set("B2", "1");
    s.set("A2", "2");
    s.set("ZZ1", "3");
    s.set("A1", "4");
    s.set("AA1", "5");
    assert(s.dump() == "A1 4\nAA1 5\nZZ1 3\nA2 2\nB2 1\n");
    s.clear("A1");
    s.set("C3", "6");
    assert(s.dump() == "AA1 5\nZZ1 3\nA2 2\nB2 1\nC3 6\n");
    s.clear("C3");
    s.clear("C3");
    s.clear("Y99");
    assert(s.length == 4);
}

unittest // errors are reported, and leave the sheet unchanged
{
    auto s = new Sheet;
    s.set("A1", "1");
    assertThrown!SyntaxError(s.set("A1", "=1+"));
    assertThrown!SyntaxError(s.set("A1", "hello"));
    assertThrown!SyntaxError(s.set("A1", "=FOO(1)"));
    assertThrown!SyntaxError(s.set("A1", "=(1"));
    assertThrown!InvalidCellName(s.set("a1", "1"));
    assertThrown!InvalidCellName(s.get("A0"));
    assert(s.display("A1") == "1");
    assertThrown!CommandError(run("frobnicate A1\n"));
}

unittest // sheet edits leave unrelated cells untouched and chains update
{
    auto s = new Sheet;
    s.set("A1", "1");
    foreach (i; 2 .. 2001)
    {
        import std.conv : to;
        s.set("A" ~ i.to!string, "=A" ~ (i - 1).to!string ~ "+1");
    }
    assert(s.display("A2000") == "2000");
    s.set("A1", "10");
    assert(s.display("A2000") == "2009");
    s.set("A1", "=A2000");
    assert(s.display("A2000") == "#CYCLE!");
    s.clear("A1");
    assert(s.display("A2000") == "1999");
}

unittest // reusing a cell for a different kind of content drops old dependencies
{
    auto s = new Sheet;
    s.set("B1", "=A1");
    s.set("A1", "=B1"); // cycle
    assert(s.display("B1") == "#CYCLE!");
    s.set("A1", "\"text\"");
    assert(s.display("B1") == "text");
    s.set("B1", "3");   // B1 no longer reads A1
    s.set("A1", "=B1+1");
    assert(s.display("A1") == "4");
    assert(s.display("B1") == "3");
}
