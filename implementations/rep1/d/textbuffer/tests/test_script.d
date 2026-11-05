module test_script;

import std.string : join;

import textbuffer.script;
import textbuffer.vec;

private string run(string input)
{
    CharBuf out_;
    runScript(input, out_);
    return out_[].idup;
}

unittest // decodeInsert
{
    CharBuf scratch;
    assert(decodeInsert("plain text", scratch) == "plain text");
    assert(decodeInsert(`a\nb`, scratch) == "a\nb");
    assert(decodeInsert(`back\\slash`, scratch) == `back\slash`);
    assert(decodeInsert(`\\n`, scratch) == `\n`);
    assert(decodeInsert(` x `, scratch) == " x ");
}

unittest // the document header
{
    const(char)[][] lines;
    immutable off = parseDocument("2\nfoo\n  bar \nmove end\n", lines);
    assert(lines == ["foo", "  bar "]);
    assert("2\nfoo\n  bar \nmove end\n"[off .. $] == "move end\n");

    parseDocument("0\nprint\n", lines);
    assert(lines.length == 0);

    // A document line may look like a command.
    parseDocument("1\nprint", lines);
    assert(lines == ["print"]);
}

unittest // malformed input
{
    import std.exception : assertThrown;
    assertThrown!ScriptException(run("1\nx\nfrobnicate\n"));
    assertThrown!ScriptException(run("1\nx\nmove sideways\n"));
    assertThrown!ScriptException(run("1\nx\ngoto 1\n"));
    assertThrown!ScriptException(run("abc\n"));
}

unittest // no print, no output
{
    assert(run("1\nabc\ninsert x\n") == "");
    assert(run("") == "");
}

unittest // spec example 1
{
    assert(run(join([
        "2", "hello world", "second line", "move end", "insert !", "move down",
        "insert  (edited)", "goto 0 5", "insert ,", "print", "delete", "delete", "print", ""], "\n"))
        == join([
        "hello, world!", "second line (edited)", "cursor 0 6", "--",
        "hell world!", "second line (edited)", "cursor 0 4", "--", ""], "\n"));
}

unittest // spec example 2
{
    assert(run(join([
        "3", "alpha", "beta", "gamma", "add-cursor 1 0", "add-cursor 2 0", "insert - ", "print",
        "move end select", "insert X", "print", "goto 0 1", "move right select",
        "move right select", "delete", "print", ""], "\n"))
        == join([
        "- alpha", "- beta", "- gamma", "cursor 0 2", "cursor 1 2", "cursor 2 2", "--",
        "- X", "- X", "- X", "cursor 0 3", "cursor 1 3", "cursor 2 3", "--",
        "-", "- X", "- X", "cursor 0 1", "--", ""], "\n"));
}

unittest // spec example 3
{
    assert(run(join([
        "1", "abc", "move end", `insert d\ne`, "print", "delete", "delete", "print", "undo", "print",
        "undo", "print", "redo", "print", "insert Z", "redo", "print", ""], "\n"))
        == join([
        "abcd", "e", "cursor 1 1", "--",
        "abcd", "cursor 0 4", "--",
        "abcd", "", "cursor 1 0", "--",
        "abcd", "e", "cursor 1 1", "--",
        "abcd", "", "cursor 1 0", "--",
        "abcd", "Z", "cursor 1 1", "--", ""], "\n"));
}

unittest // final command without a newline; empty document
{
    assert(run("0\ninsert a\\nb\nprint") == "a\nb\ncursor 1 1\n--\n");
}

unittest // backslashes
{
    assert(run("0\ninsert a\\\\b\nprint\n") == "a\\b\ncursor 0 3\n--\n");
}
