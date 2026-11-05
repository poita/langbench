module test_state;

import helpers;
import kiln.hash;
import kiln.state;
import kiln.step;
import kiln.vfs;

private State parse(string text)
{
    auto v = new Vfs;
    v.write(".kiln-state", text);
    return parseState(v);
}

private enum h1 = "0123456789abcdef";

unittest
{
    auto s = parse("kiln-state 1\nstep out/a\ncmd copy()\nin src/a " ~ h1 ~ "\ndep src/b " ~ h1
            ~ "\nout out/a " ~ h1 ~ "\nend\n");
    assert(s.length == 1);
    auto e = s["out/a"];
    assert(e.cmd == "copy()" && e.ins.length == 1 && e.deps.length == 1 && e.outs.length == 1);
    assert(e.ins[0].hash == 0x0123456789abcdefUL);
    // canonical output is parsed back identically
    assert(renderState(s) == "kiln-state 1\nstep out/a\ncmd copy()\nin src/a " ~ h1 ~ "\ndep src/b " ~ h1
            ~ "\nout out/a " ~ h1 ~ "\nend\n");
}

unittest
{
    enum head = "kiln-state 1\n";
    // all of these are rejected as a whole
    string[] bad = [
        "",
        "kiln-state 2\n",
        head ~ "step out/a\ncmd x\nout out/a " ~ h1 ~ "\nend",              // unterminated last line
        head ~ "step out/a\ncmd x\nout out/a " ~ h1 ~ "\n",                  // missing end
        head ~ "step out/a\nout out/a " ~ h1 ~ "\nend\n",                    // no cmd
        head ~ "step out/a\ncmd x\nend\n",                                   // no out
        head ~ "step out/a\ncmd x\ncmd y\nout out/a " ~ h1 ~ "\nend\n",      // two cmds
        head ~ "step out/a\ncmd \nout out/a " ~ h1 ~ "\nend\n",              // empty cmd
        head ~ "step out/a\ncmd x\nout out/b " ~ h1 ~ "\nend\n",             // key != first out
        head ~ "step out/a\ncmd x\ndep p " ~ h1 ~ "\nin p " ~ h1 ~ "\nout out/a " ~ h1 ~ "\nend\n", // misordered
        head ~ "step out/a\ncmd x\nout out/a ABCDEF0123456789\nend\n",       // upper-case hash
        head ~ "step out/a\ncmd x\nout out/a " ~ h1 ~ "a\nend\n",            // long hash
        head ~ "step out/a\ncmd x\nout out/a  " ~ h1 ~ "\nend\n",            // extra space
        head ~ "step bad path\ncmd x\nout bad " ~ h1 ~ "\nend\n",
        head ~ "step out/a\ncmd x\nout out/a " ~ h1 ~ "\nend\nstep out/a\ncmd x\nout out/a " ~ h1 ~ "\nend\n",
        head ~ "stray\n",
        head ~ "end\n",
    ];
    foreach (b; bad)
        assert(parse(b).length == 0, "should be rejected: " ~ b);
    // unsorted entries and repeated paths within a section are accepted
    auto ok = parse(head ~ "step out/b\ncmd x\nout out/b " ~ h1 ~ "\nend\nstep out/a\ncmd x\ndep q " ~ h1
            ~ "\ndep a " ~ h1 ~ "\ndep a " ~ h1 ~ "\nout out/a " ~ h1 ~ "\nend\n");
    assert(ok.length == 2 && ok["out/a"].deps.length == 3);
    assert(renderState(ok)[0 .. 30] == "kiln-state 1\nstep out/a\ncmd x\n");
}

unittest
{
    assert(canonicalCommand(Cmd.write, [kiln.value.Value.ofStr("hello\n")]) == "write(\"hello\\n\")");
    assert(canonicalCommand(Cmd.replace, [kiln.value.Value.ofStr("a\\b"), kiln.value.Value.ofStr("c")])
            == "replace(\"a\\\\b\", \"c\")");
    assert(canonicalCommand(Cmd.indent, [kiln.value.Value.ofInt(4)]) == "indent(4)");
    assert(canonicalCommand(Cmd.grep, [kiln.value.Value.ofStr("ü")]) == "grep(\"ü\")");
    assert(canonicalCommand(Cmd.write, [kiln.value.Value.ofStr("\x01\x7f\t\r\"")]) == "write(\"\\x01\\x7f\\t\\r\\\"\")");
    assert(canonicalCommand(Cmd.preprocess, []) == "preprocess()");
}

import kiln.value;
