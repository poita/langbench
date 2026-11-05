/// Unit tests for kiln.commands, kiln.step (canonical strings) and kiln.bytes.
module command_test;

import kiln.bytes;
import kiln.commands;
import kiln.step;
import kiln.value;
import kiln.vfs;

private string exec(string name, Value[] args, string[] inputs, Vfs vfs = null)
{
    auto info = findCommand(name);
    assert(info !is null);
    string[] paths;
    foreach (i; 0 .. inputs.length)
        paths ~= "src/f" ~ decimal(cast(long) i);
    auto r = executeCommand(info, args, paths, inputs, vfs);
    assert(r.ok);
    return r.outputs[0];
}

private Value s(string x)
{
    return Value.ofStr(x);
}

unittest // line splitting
{
    assert(splitLines("") == []);
    assert(splitLines("a\nb\n") == ["a", "b"]);
    assert(splitLines("a\nb") == ["a", "b"]);
    assert(splitLines("a\n\nb\n") == ["a", "", "b"]);
    assert(splitLines("\n") == [""]);
    assert(splitLines("a\r\n") == ["a\r"]);
}

unittest // text commands
{
    assert(exec("write", [s("x\0y")], []) == "x\0y");
    assert(exec("concat", [], ["a", "b", "a"]) == "aba");
    assert(exec("upper", [], ["aZé"]) == "AZé");
    assert(exec("lower", [], ["AzQ"]) == "azq");
    assert(exec("grep", [s("b")], ["ab\ncd\nb"]) == "ab\nb\n");
    assert(exec("grep", [s("")], ["a\nb"]) == "a\nb\n");
    assert(exec("replace", [s("a"), s("bb")], ["xax"]) == "xbbx");
    assert(exec("sort_lines", [], ["b\na\nb\n"]) == "a\nb\nb\n");
    assert(exec("reverse_lines", [], ["1\n2\n3"]) == "3\n2\n1\n");
    assert(exec("dedup", [], ["a\nb\na\nb\nc\n"]) == "a\nb\nc\n");
    assert(exec("number", [], ["a\nb\nc\n"]) == "1: a\n2: b\n3: c\n");
    assert(exec("indent", [Value.ofInt(2)], ["a\n\nb"]) == "  a\n  \n  b\n");
    assert(exec("wrap", [s("<"), s(">")], ["mid"]) == "<mid>");
}

unittest // summary commands
{
    assert(exec("count_lines", [], ["a\nb\n", ""]) == "2 src/f0\n0 src/f1\n2 total\n");
    assert(exec("hash", [], ["hello\n"]) == "a9bc80cca21f28b3 src/f0\n");
}

unittest // preprocess expands needs and records the discovered set
{
    auto v = new Vfs;
    v.put("src/part.txt", "PART\n@need src/deep.txt\n");
    v.put("src/deep.txt", "DEEP");
    auto info = findCommand("preprocess");
    auto r = executeCommand(info, [], ["src/main.txt"], ["top\n@need src/part.txt\nend\n"], v);
    assert(r.ok);
    assert(r.outputs[0] == "top\nPART\nDEEP\nend\n");
    assert(r.outputs[1] == "kiln-deps 1\nneed src/deep.txt\nneed src/part.txt\n");
    assert(r.deps == ["src/deep.txt", "src/part.txt"]);
}

unittest // preprocess failures
{
    auto v = new Vfs;
    v.put("src/a.txt", "@need src/b.txt\n");
    v.put("src/b.txt", "@need src/a.txt\n");
    auto info = findCommand("preprocess");
    auto r = executeCommand(info, [], ["src/main.txt"], ["@need src/gone.txt\n"], v);
    assert(!r.ok && r.error.render == "E_NEED_MISSING src/gone.txt needed by src/main.txt");
    r = executeCommand(info, [], ["src/main.txt"], ["@need bad path\n"], v);
    assert(!r.ok && r.error.render == "E_NEED_PATH bad path");
    r = executeCommand(info, [], ["src/main.txt"], ["@need src/a.txt\n"], v);
    assert(!r.ok && r.error.render == "E_NEED_CYCLE src/a.txt");
    // "@need" without the trailing space or content is an ordinary line
    r = executeCommand(info, [], ["src/main.txt"], ["@need\n@need \n"], v);
    assert(r.ok && r.outputs[0] == "@need\n@need \n");
}

unittest // canonical command rendering
{
    assert(canonicalCommand("write", [s("hello\n")]) == `write("hello\n")`);
    assert(canonicalCommand("replace", [s("a\\b"), s("c")]) == `replace("a\\b", "c")`);
    assert(canonicalCommand("indent", [Value.ofInt(4)]) == "indent(4)");
    assert(canonicalCommand("preprocess", []) == "preprocess()");
    assert(canonicalCommand("write", [s("\x01\x7f\"\t\rü")]) == "write(\"\\x01\\x7f\\\"\\t\\rü\")");
}

unittest // byte helpers
{
    assert(replaceAll("aaa", "aa", "b") == "ba");
    assert(replaceAll("abc", "x", "y") == "abc");
    assert(findBytes("abcabc", "ca") == 2);
    assert(containsBytes("abc", ""));
    assert(decimal(-42) == "-42" && decimal(0) == "0");
}

unittest // command table
{
    assert(findCommand("nope") is null);
    assert(findCommand("preprocess").depfile);
    assert(findCommand("concat").maxIn == -1);
    assert(findCommand("sort_lines").cost == 4);
}
