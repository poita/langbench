/// Unit tests for kiln.state and kiln.hash.
module state_test;

import kiln.hash;
import kiln.state;

unittest // FNV-1a known answers
{
    assert(toHex16(fnv1a("")) == "cbf29ce484222325");
    assert(toHex16(fnv1a("hello\n")) == "a9bc80cca21f28b3");
    assert(toHex16(fnv1a("abc\n")) == "fc17b183ee074373");
}

unittest // hex parsing accepts exactly 16 lowercase digits
{
    ulong v;
    assert(parseHex16("a9bc80cca21f28b3", v) && v == 0xa9bc80cca21f28b3UL);
    assert(!parseHex16("A9bc80cca21f28b3", v));
    assert(!parseHex16("a9bc80cca21f28b", v));
    assert(!parseHex16("a9bc80cca21f28b3 ", v));
}

private enum good = "kiln-state 1\nstep out/a\ncmd write(\"x y\")\nin src/q 0000000000000001\n"
    ~ "dep src/z 0000000000000002\ndep src/b 0000000000000003\nout out/a 0000000000000004\n"
    ~ "out out/a.d 0000000000000005\nend\nstep out/b\ncmd copy()\nout out/b 0000000000000006\nend\n";

unittest // a valid file round-trips (dep order is preserved by the reader)
{
    auto st = parseState(good);
    assert(st.length == 2);
    assert(st["out/a"].cmd == `write("x y")`);
    assert(st["out/a"].deps.length == 2 && st["out/a"].deps[0].path == "src/z");
    assert(renderState(st) == good);
}

unittest // the empty state is valid
{
    assert(parseState("kiln-state 1\n").length == 0);
    assert(renderState(parseState("kiln-state 1\n")) == "kiln-state 1\n");
}

private bool rejected(string s)
{
    return parseState(s).length == 0;
}

unittest // every deviation rejects the whole file
{
    assert(rejected(""));
    assert(rejected("kiln-state 2\n"));
    assert(rejected(good[0 .. $ - 1])); // missing final newline
    assert(rejected("kiln-state 1\nstep out/a\ncmd x\nout out/a 0000000000000004\n")); // unterminated
    assert(rejected("kiln-state 1\nstep out/a\nout out/a 0000000000000004\nend\n")); // no cmd
    assert(rejected("kiln-state 1\nstep out/a\ncmd x\ncmd y\nout out/a 0000000000000004\nend\n"));
    assert(rejected("kiln-state 1\nstep out/a\ncmd x\nend\n")); // no out
    assert(rejected("kiln-state 1\nstep out/a\ncmd x\nout out/b 0000000000000004\nend\n")); // key mismatch
    assert(rejected("kiln-state 1\nstep out/a\ncmd \nout out/a 0000000000000004\nend\n"));
    assert(rejected("kiln-state 1\nstep out/a\ncmd x\nout out/a 000000000000000G\nend\n"));
    assert(rejected("kiln-state 1\nstep out/a\ncmd x\nout out/a 000000000000000A\nend\n"));
    assert(rejected("kiln-state 1\nstep out/a\ncmd x\nout out/a  0000000000000004\nend\n"));
    assert(rejected("kiln-state 1\nstep out/a\ncmd x\nout out/a 0000000000000004\nin src/q 0000000000000001\nend\n")); // misordered
    assert(rejected("kiln-state 1\nstep out/a\ncmd x\nout out/a 0000000000000004\nend\nstep out/a\ncmd x\nout out/a 0000000000000004\nend\n"));
    assert(rejected("kiln-state 1\nstep ../a\ncmd x\nout ../a 0000000000000004\nend\n"));
    assert(rejected("kiln-state 1\nstray\n"));
}
