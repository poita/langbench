/// Unit tests: session scripts and log formatting.
module tests.test_session;

import kiln;
import tests.helpers;

unittest // parsing the session grammar
{
    auto s = parseSession("# comment\n\n  build a b -j 4\nbuild -j\nbuild -j 3\ncreate x/y\nl1\n\n  l2\n---\n"
            ~ "edit z\n---\ndelete q\ntouch r\nclean\n");
    assert(s.length == 8);
    assert(s[0].kind == StepKind.build && s[0].targets == ["a", "b"] && s[0].workers == 4);
    assert(s[1].targets == ["-j"] && s[1].workers == 1); // "-j" as the last word is a target
    assert(s[2].targets.length == 0 && s[2].workers == 3);
    assert(s[3].kind == StepKind.create && s[3].path == "x/y" && s[3].content == "l1\n\n  l2\n");
    assert(s[4].kind == StepKind.edit && s[4].content == "");
    assert(s[5].kind == StepKind.del && s[6].kind == StepKind.touch && s[7].kind == StepKind.clean);
}

unittest // mutations and clean
{
    Vfs v;
    auto log = logOf(["main.kiln": "", "a": "x"], "create b\nhi\n---\nedit b\nhello\n---\ntouch a\ndelete a\nclean\n", &v);
    assert(log == "step 1: create b\n  ok size=3\nstep 2: edit b\n  ok size=6\nstep 3: touch a\n  ok\n"
            ~ "step 4: delete a\n  ok\nstep 5: clean\n  ok removed=0\n");
    assert(v.read("b") == "hello\n" && !v.exists("a"));
}

unittest // clean removes the generated tree and the state file
{
    auto main = "step {\n out \"out/hello.txt\"\n cmd write(\"hello\\n\")\n}\ndefault \"out/hello.txt\"\n";
    auto log = logOf(["main.kiln": main], "build\nclean\nbuild\n");
    import std.algorithm.searching : canFind;
    assert(log.canFind("step 2: clean\n  remove .kiln-state\n  remove out/hello.txt\n  ok removed=2\n"));
}

unittest // an unknown build target is a configuration error
{
    auto main = "step {\n out \"out/a\"\n cmd write(\"\")\n}\ndefault \"out/a\"\n";
    auto log = logOf(["main.kiln": main], "build @nope out/a -j 2\n");
    assert(log == "step 1: build @nope out/a -j 2\n  error E_UNKNOWN_TARGET @nope\n");
}
