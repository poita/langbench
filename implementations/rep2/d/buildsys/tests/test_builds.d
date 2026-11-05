module test_builds;

import helpers;
import kiln;
import kiln.hash;

private string joinLog(string[] lines)
{
    string r;
    foreach (l; lines)
        r ~= l ~ "\n";
    return r;
}

unittest
{
    // Example 1/2: one step, cache hit, touch is not a change
    auto v = workspace(["main.kiln": "step {\n out \"out/hello.txt\"\n cmd write(\"hello\\n\")\n}\ndefault \"out/hello.txt\"\n"]);
    auto log = replay(v, "build\nbuild\ntouch main.kiln\nbuild\n");
    assert(log == joinLog([
        "step 1: build (default) -j 1",
        "  run 0 1 w0 out/hello.txt write(\"hello\\n\")",
        "  ok ran=1 hit=0 time=1",
        "step 2: build (default) -j 1",
        "  hit 0 out/hello.txt",
        "  ok ran=0 hit=1 time=0",
        "step 3: touch main.kiln",
        "  ok",
        "step 4: build (default) -j 1",
        "  hit 0 out/hello.txt",
        "  ok ran=0 hit=1 time=0",
    ]));
    assert(v.read(".kiln-state") == "kiln-state 1\nstep out/hello.txt\ncmd write(\"hello\\n\")\nout out/hello.txt a9bc80cca21f28b3\nend\n");
}

unittest
{
    // Example 3: worker allocation and tie-breaking
    string main_ = "step {\n out \"out/a.txt\"\n cmd write(\"A\\n\")\n cost 3\n}\n"
        ~ "step {\n out \"out/b.txt\"\n cmd write(\"B\\n\")\n cost 1\n}\n"
        ~ "step {\n out \"out/c.txt\"\n cmd write(\"C\\n\")\n cost 4\n}\n"
        ~ "step {\n out \"out/d.txt\"\n cmd write(\"D\\n\")\n cost 2\n}\n"
        ~ "step {\n out \"out/all.txt\"\n in [\"out/a.txt\", \"out/b.txt\", \"out/c.txt\", \"out/d.txt\"]\n cmd concat()\n cost 2\n}\n"
        ~ "default \"out/all.txt\"\n";
    auto v = workspace(["main.kiln": main_]);
    assert(replay(v, "build -j 2\n") == joinLog([
        "step 1: build (default) -j 2",
        "  run 0 3 w0 out/a.txt write(\"A\\n\")",
        "  run 0 1 w1 out/b.txt write(\"B\\n\")",
        "  run 1 5 w1 out/c.txt write(\"C\\n\")",
        "  run 3 5 w0 out/d.txt write(\"D\\n\")",
        "  run 5 7 w0 out/all.txt concat()",
        "  ok ran=5 hit=0 time=7",
    ]));
    assert(v.read("out/all.txt") == "A\nB\nC\nD\n");
}

unittest
{
    // Example 8: early cutoff
    auto v = workspace(["src/a.txt": "abc\n", "main.kiln":
        "step {\n out \"out/mid.txt\"\n in \"src/a.txt\"\n cmd upper()\n}\n"
        ~ "step {\n out \"out/final.txt\"\n in \"out/mid.txt\"\n cmd number()\n}\ndefault \"out/final.txt\"\n"]);
    assert(replay(v, "build\nedit src/a.txt\nABC\n---\nbuild\n") == joinLog([
        "step 1: build (default) -j 1",
        "  run 0 2 w0 out/mid.txt upper()",
        "  run 2 4 w0 out/final.txt number()",
        "  ok ran=2 hit=0 time=4",
        "step 2: edit src/a.txt",
        "  ok size=4",
        "step 3: build (default) -j 1",
        "  run 0 2 w0 out/mid.txt upper()",
        "  hit 2 out/final.txt",
        "  ok ran=1 hit=1 time=2",
    ]));
}

unittest
{
    // Example 9: a cycle is a configuration error and writes nothing
    auto v = workspace(["main.kiln": "step {\n out \"out/x.txt\"\n in \"out/y.txt\"\n cmd copy()\n}\n"
        ~ "step {\n out \"out/y.txt\"\n in \"out/x.txt\"\n cmd copy()\n}\ndefault \"out/x.txt\"\n"]);
    assert(replay(v, "build\n") == "step 1: build (default) -j 1\n  error E_CYCLE out/x.txt -> out/y.txt -> out/x.txt\n");
    assert(v.paths == ["main.kiln"]);
}

unittest
{
    // Example 12: an execution error cancels work in flight; state is still written
    auto v = workspace(["src/main.txt": "@need src/gone.txt\n", "main.kiln":
        "step {\n out \"out/doc.txt\"\n depfile \"out/doc.d\"\n in \"src/main.txt\"\n cmd preprocess()\n}\n"
        ~ "step {\n out \"out/slow.txt\"\n cmd write(\"slow\\n\")\n cost 10\n}\n"
        ~ "step {\n out \"out/after.txt\"\n in \"out/doc.txt\"\n cmd copy()\n}\n"
        ~ "phony all = [\"out/doc.txt\", \"out/slow.txt\", \"out/after.txt\"]\ndefault \"@all\"\n"]);
    assert(replay(v, "build -j 2\n") == joinLog([
        "step 1: build (default) -j 2",
        "  fail 0 6 w0 out/doc.txt preprocess()",
        "  cancel 0 10 w1 out/slow.txt write(\"slow\\n\")",
        "  error E_NEED_MISSING src/gone.txt needed by src/main.txt",
    ]));
    assert(v.read(".kiln-state") == "kiln-state 1\n");
    assert(!v.exists("out/slow.txt"));
}

unittest
{
    // Example 13/14: `after` is order-only; cost is not a change, the dependency set is
    auto v = workspace(["src/a.txt": "a\n", "main.kiln":
        "step {\n out \"out/gen.txt\"\n in \"src/a.txt\"\n cmd copy()\n}\n"
        ~ "step {\n out \"out/rep.txt\"\n after \"out/gen.txt\"\n cmd write(\"report\\n\")\n}\n"
        ~ "phony all = [\"out/rep.txt\"]\ndefault \"@all\"\n"]);
    assert(replay(v, "build\nedit src/a.txt\nb\n---\nbuild\n") == joinLog([
        "step 1: build (default) -j 1",
        "  run 0 1 w0 out/gen.txt copy()",
        "  run 1 2 w0 out/rep.txt write(\"report\\n\")",
        "  ok ran=2 hit=0 time=2",
        "step 2: edit src/a.txt",
        "  ok size=2",
        "step 3: build (default) -j 1",
        "  run 0 1 w0 out/gen.txt copy()",
        "  hit 1 out/rep.txt",
        "  ok ran=1 hit=1 time=1",
    ]));

    auto w = workspace(["src/a.txt": "a\n", "src/b.txt": "a\n", "main.kiln":
        "step {\n out \"out/j.txt\"\n in [\"src/a.txt\", \"src/b.txt\"]\n cmd concat()\n}\ndefault \"out/j.txt\"\n"]);
    auto log = replay(w, "build\nedit main.kiln\nstep {\n out \"out/j.txt\"\n in [\"src/a.txt\", \"src/b.txt\"]\n"
            ~ " cmd concat()\n cost 5\n}\ndefault \"out/j.txt\"\n---\nbuild\n"
            ~ "edit main.kiln\nstep {\n out \"out/j.txt\"\n in [\"src/b.txt\", \"src/a.txt\"]\n"
            ~ " cmd concat()\n cost 5\n}\ndefault \"out/j.txt\"\n---\nbuild\n");
    import std.algorithm : canFind, endsWith;

    assert(log.endsWith("step 5: build (default) -j 1\n  run 0 5 w0 out/j.txt concat()\n  ok ran=1 hit=0 time=5\n"));
    assert(log.canFind("step 3: build (default) -j 1\n  hit 0 out/j.txt\n  ok ran=0 hit=1 time=0\n"));
}

unittest
{
    // Example 15: hand-modified and deleted outputs are rebuilt; clean removes out/ and state
    auto v = workspace(["main.kiln": "step {\n out \"out/hello.txt\"\n cmd write(\"hello\\n\")\n}\ndefault \"out/hello.txt\"\n"]);
    auto log = replay(v, "build\nedit out/hello.txt\ntampered\n---\nbuild\ndelete out/hello.txt\nbuild\nclean\nbuild\n");
    enum runLine = "  run 0 1 w0 out/hello.txt write(\"hello\\n\")\n  ok ran=1 hit=0 time=1\n";
    assert(log == "step 1: build (default) -j 1\n" ~ runLine
        ~ "step 2: edit out/hello.txt\n  ok size=9\n"
        ~ "step 3: build (default) -j 1\n" ~ runLine
        ~ "step 4: delete out/hello.txt\n  ok\n"
        ~ "step 5: build (default) -j 1\n" ~ runLine
        ~ "step 6: clean\n  remove .kiln-state\n  remove out/hello.txt\n  ok removed=2\n"
        ~ "step 7: build (default) -j 1\n" ~ runLine);
}

unittest
{
    // configuration errors
    auto v = workspace(null);
    assert(replay(v, "build\n") == "step 1: build (default) -j 1\n  error E_NO_BUILD_FILE main.kiln\n");
    v.write("main.kiln", "step {\n out \"out/z.txt\"\n cmd write(\"ok\\n\")\n}\n");
    assert(replay(v, "build\nbuild out/nope\nbuild @nope\n") ==
        "step 1: build (default) -j 1\n  error E_NO_DEFAULT\n"
        ~ "step 2: build out/nope -j 1\n  error E_UNKNOWN_TARGET out/nope\n"
        ~ "step 3: build @nope -j 1\n  error E_UNKNOWN_TARGET @nope\n");
    assert(!v.exists(".kiln-state"));
}

unittest
{
    // session parsing
    auto s = parseSession("# c\n\nbuild a b -j 4\nbuild -j 2\nbuild -j\ncreate x/y\nl1\n\n  l3\n---\nclean\n");
    assert(s.length == 5);
    assert(s[0].targets == ["a", "b"] && s[0].workers == 4);
    assert(s[1].targets.length == 0 && s[1].workers == 2);
    assert(s[2].targets == ["-j"] && s[2].workers == 1);
    assert(s[3].kind == StepKind.create && s[3].content == "l1\n\n  l3\n");
    assert(s[4].kind == StepKind.clean);
}
