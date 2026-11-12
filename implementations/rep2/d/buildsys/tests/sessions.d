/**
 * End-to-end tests: whole sessions run against an in-memory workspace, with
 * the worked examples of the specification as the main cases.
 */
module tests.sessions;

version (unittest):

import kiln;
import std.exception : collectException;

/// Builds a workspace from alternating path/content arguments.
private Workspace workspaceOf(string[] files...)
{
    auto ws = new Workspace;
    for (size_t i = 0; i + 1 < files.length; i += 2)
        ws.write(files[i], files[i + 1]);
    return ws;
}

private string run(Workspace ws, string session)
{
    return runSession(ws, session);
}

private enum helloKiln = "step {\n    out \"out/hello.txt\"\n    cmd write(\"hello\\n\")\n}\ndefault \"out/hello.txt\"\n";

@system unittest // example 1: one step
{
    auto ws = workspaceOf("main.kiln", helloKiln);
    assert(run(ws, "build\n") == "step 1: build (default) -j 1\n"
            ~ "  run 0 1 w0 out/hello.txt write(\"hello\\n\")\n"
            ~ "  ok ran=1 hit=0 time=1\n");
    assert(ws.read("out/hello.txt") == "hello\n");
    assert(ws.read(".kiln-state") == "kiln-state 1\nstep out/hello.txt\ncmd write(\"hello\\n\")\n"
            ~ "out out/hello.txt a9bc80cca21f28b3\nend\n");
}

@system unittest // example 2: a cache hit; touch is not a change
{
    auto ws = workspaceOf("main.kiln", helloKiln);
    assert(run(ws, "build\nbuild\ntouch main.kiln\nbuild\n") == "step 1: build (default) -j 1\n"
            ~ "  run 0 1 w0 out/hello.txt write(\"hello\\n\")\n  ok ran=1 hit=0 time=1\n"
            ~ "step 2: build (default) -j 1\n  hit 0 out/hello.txt\n  ok ran=0 hit=1 time=0\n"
            ~ "step 3: touch main.kiln\n  ok\n"
            ~ "step 4: build (default) -j 1\n  hit 0 out/hello.txt\n  ok ran=0 hit=1 time=0\n");
}

@system unittest // example 3: parallel scheduling and tie-breaking
{
    auto ws = workspaceOf("main.kiln",
            "step {\n out \"out/a.txt\"\n cmd write(\"A\\n\")\n cost 3\n}\n"
            ~ "step {\n out \"out/b.txt\"\n cmd write(\"B\\n\")\n cost 1\n}\n"
            ~ "step {\n out \"out/c.txt\"\n cmd write(\"C\\n\")\n cost 4\n}\n"
            ~ "step {\n out \"out/d.txt\"\n cmd write(\"D\\n\")\n cost 2\n}\n"
            ~ "step {\n out \"out/all.txt\"\n in [\"out/a.txt\", \"out/b.txt\", \"out/c.txt\", \"out/d.txt\"]\n"
            ~ " cmd concat()\n cost 2\n}\ndefault \"out/all.txt\"\n");
    assert(run(ws, "build -j 2\n") == "step 1: build (default) -j 2\n"
            ~ "  run 0 3 w0 out/a.txt write(\"A\\n\")\n"
            ~ "  run 0 1 w1 out/b.txt write(\"B\\n\")\n"
            ~ "  run 1 5 w1 out/c.txt write(\"C\\n\")\n"
            ~ "  run 3 5 w0 out/d.txt write(\"D\\n\")\n"
            ~ "  run 5 7 w0 out/all.txt concat()\n  ok ran=5 hit=0 time=7\n");
    assert(ws.read("out/all.txt") == "A\nB\nC\nD\n");
}

@system unittest // example 4: variables, interpolation, each, map, phony
{
    auto ws = workspaceOf("main.kiln", "let names = [\"alpha\", \"beta\", \"gamma\"]\n"
            ~ "let outs = map(names, \"out/%.txt\")\n"
            ~ "each i, n in names {\n step {\n  out \"out/{n}.txt\"\n  cmd write(\"{i}:{n}\\n\")\n  cost 1\n }\n}\n"
            ~ "step {\n out \"out/index.txt\"\n in outs\n cmd concat()\n}\n"
            ~ "phony all = [\"out/index.txt\"]\ndefault \"@all\"\n");
    assert(run(ws, "build @all -j 3\n") == "step 1: build @all -j 3\n"
            ~ "  run 0 1 w0 out/alpha.txt write(\"0:alpha\\n\")\n"
            ~ "  run 0 1 w1 out/beta.txt write(\"1:beta\\n\")\n"
            ~ "  run 0 1 w2 out/gamma.txt write(\"2:gamma\\n\")\n"
            ~ "  run 1 3 w0 out/index.txt concat()\n  ok ran=4 hit=0 time=3\n");
    assert(ws.read("out/index.txt") == "0:alpha\n1:beta\n2:gamma\n");
}

@system unittest // example 5: rules with keyword arguments and defaults
{
    auto ws = workspaceOf("src/a.txt", "AAA\n", "src/b.txt", "BBB\n", "main.kiln",
            "rule bundle(name, parts, weight = 2) {\n step {\n  out \"out/{name}.txt\"\n  in parts\n"
            ~ "  cmd concat()\n  cost weight\n }\n}\n"
            ~ "let base = [\"src/a.txt\", \"src/b.txt\"]\nuse bundle(\"one\", base)\n"
            ~ "use bundle(name = \"two\", parts = base ++ [\"out/one.txt\"], weight = 5)\n"
            ~ "phony all = [\"out/one.txt\", \"out/two.txt\"]\ndefault \"@all\"\n");
    assert(run(ws, "build -j 2\n") == "step 1: build (default) -j 2\n"
            ~ "  run 0 2 w0 out/one.txt concat()\n  run 2 7 w0 out/two.txt concat()\n  ok ran=2 hit=0 time=7\n");
    assert(ws.read(".kiln-state") == "kiln-state 1\nstep out/one.txt\ncmd concat()\n"
            ~ "in src/a.txt 8943a78b9f342c58\nin src/b.txt c857dca71c36fafd\nout out/one.txt 5e52e06e8b405ae8\nend\n"
            ~ "step out/two.txt\ncmd concat()\nin src/a.txt 8943a78b9f342c58\nin src/b.txt c857dca71c36fafd\n"
            ~ "in out/one.txt 5e52e06e8b405ae8\nout out/two.txt f98ee131e7582add\nend\n");
}

@system unittest // example 6: glob, include, set, when/otherwise
{
    auto ws = workspaceOf("src/a.txt", "a1\n", "src/b.txt", "b1\n", "src/sub/c.txt", "c1\n",
            "src/notes.md", "note\n", "tune.kiln", "set mode = \"slow\"\nlet extra = 1\n", "main.kiln",
            "let mode = \"fast\"\nlet flags = []\ninclude \"tune.kiln\"\n"
            ~ "when mode == \"fast\" {\n set flags = flags ++ [\"F\"]\n} otherwise {\n set flags = flags ++ [\"S\"]\n}\n"
            ~ "let srcs = glob(\"src/**/*.txt\")\nstep {\n out \"out/list.txt\"\n in srcs\n cmd count_lines()\n}\n"
            ~ "step {\n out \"out/flags.txt\"\n cmd write(\"{join(flags, \",\")}\\n\")\n}\n"
            ~ "default [\"out/list.txt\", \"out/flags.txt\"]\n");
    assert(run(ws, "build -j 2\n") == "step 1: build (default) -j 2\n"
            ~ "  run 0 2 w0 out/list.txt count_lines()\n  run 0 1 w1 out/flags.txt write(\"S\\n\")\n"
            ~ "  ok ran=2 hit=0 time=2\n");
    assert(ws.read("out/list.txt") == "1 src/a.txt\n1 src/b.txt\n1 src/sub/c.txt\n3 total\n");
}

@system unittest // example 7: preprocess, depfiles and discovered dependencies
{
    auto ws = workspaceOf("src/main.txt", "title\n@need src/part.txt\nend\n", "src/part.txt",
            "PART-A\n@need src/deep.txt\n", "src/deep.txt", "DEEP\n", "main.kiln",
            "step {\n out \"out/doc.txt\"\n depfile \"out/doc.d\"\n in \"src/main.txt\"\n cmd preprocess()\n}\n"
            ~ "default \"out/doc.txt\"\n");
    auto log = run(ws, "build\nbuild\nedit src/deep.txt\nDEEP2\n---\nbuild\n");
    assert(log == "step 1: build (default) -j 1\n  run 0 6 w0 out/doc.txt preprocess()\n  ok ran=1 hit=0 time=6\n"
            ~ "step 2: build (default) -j 1\n  hit 0 out/doc.txt\n  ok ran=0 hit=1 time=0\n"
            ~ "step 3: edit src/deep.txt\n  ok size=6\n"
            ~ "step 4: build (default) -j 1\n  run 0 6 w0 out/doc.txt preprocess()\n  ok ran=1 hit=0 time=6\n");
    assert(ws.read("out/doc.txt") == "title\nPART-A\nDEEP2\nend\n");
    assert(ws.read("out/doc.d") == "kiln-deps 1\nneed src/deep.txt\nneed src/part.txt\n");
}

@system unittest // example 8: early cutoff
{
    auto ws = workspaceOf("src/a.txt", "abc\n", "main.kiln",
            "step {\n out \"out/mid.txt\"\n in \"src/a.txt\"\n cmd upper()\n}\n"
            ~ "step {\n out \"out/final.txt\"\n in \"out/mid.txt\"\n cmd number()\n}\ndefault \"out/final.txt\"\n");
    assert(run(ws, "build\nedit src/a.txt\nABC\n---\nbuild\n") == "step 1: build (default) -j 1\n"
            ~ "  run 0 2 w0 out/mid.txt upper()\n  run 2 4 w0 out/final.txt number()\n  ok ran=2 hit=0 time=4\n"
            ~ "step 2: edit src/a.txt\n  ok size=4\n"
            ~ "step 3: build (default) -j 1\n  run 0 2 w0 out/mid.txt upper()\n  hit 2 out/final.txt\n"
            ~ "  ok ran=1 hit=1 time=2\n");
}

@system unittest // example 9: cycles are configuration errors and write nothing
{
    auto ws = workspaceOf("main.kiln",
            "step {\n out \"out/x.txt\"\n in \"out/y.txt\"\n cmd copy()\n}\n"
            ~ "step {\n out \"out/y.txt\"\n in \"out/x.txt\"\n cmd copy()\n}\ndefault \"out/x.txt\"\n");
    assert(run(ws, "build\n") == "step 1: build (default) -j 1\n"
            ~ "  error E_CYCLE out/x.txt -> out/y.txt -> out/x.txt\n");
    assert(ws.paths == ["main.kiln"]);
}

@system unittest // example 12: an execution error cancels work in flight
{
    auto ws = workspaceOf("src/main.txt", "@need src/gone.txt\n", "main.kiln",
            "step {\n out \"out/doc.txt\"\n depfile \"out/doc.d\"\n in \"src/main.txt\"\n cmd preprocess()\n}\n"
            ~ "step {\n out \"out/slow.txt\"\n cmd write(\"slow\\n\")\n cost 10\n}\n"
            ~ "step {\n out \"out/after.txt\"\n in \"out/doc.txt\"\n cmd copy()\n}\n"
            ~ "phony all = [\"out/doc.txt\", \"out/slow.txt\", \"out/after.txt\"]\ndefault \"@all\"\n");
    assert(run(ws, "build -j 2\n") == "step 1: build (default) -j 2\n"
            ~ "  fail 0 6 w0 out/doc.txt preprocess()\n  cancel 0 10 w1 out/slow.txt write(\"slow\\n\")\n"
            ~ "  error E_NEED_MISSING src/gone.txt needed by src/main.txt\n");
    assert(ws.read(".kiln-state") == "kiln-state 1\n");
    assert(!ws.exists("out/slow.txt"));
}

@system unittest // example 13: after is order-only
{
    auto ws = workspaceOf("src/a.txt", "a\n", "main.kiln",
            "step {\n out \"out/gen.txt\"\n in \"src/a.txt\"\n cmd copy()\n}\n"
            ~ "step {\n out \"out/rep.txt\"\n after \"out/gen.txt\"\n cmd write(\"report\\n\")\n}\n"
            ~ "phony all = [\"out/rep.txt\"]\ndefault \"@all\"\n");
    assert(run(ws, "build\nedit src/a.txt\nb\n---\nbuild\n") == "step 1: build (default) -j 1\n"
            ~ "  run 0 1 w0 out/gen.txt copy()\n  run 1 2 w0 out/rep.txt write(\"report\\n\")\n  ok ran=2 hit=0 time=2\n"
            ~ "step 2: edit src/a.txt\n  ok size=2\n"
            ~ "step 3: build (default) -j 1\n  run 0 1 w0 out/gen.txt copy()\n  hit 1 out/rep.txt\n"
            ~ "  ok ran=1 hit=1 time=1\n");
}

@system unittest // example 14: cost is not a change, the dependency set is
{
    enum head = "step {\n    out \"out/j.txt\"\n    in ";
    enum tail = "\n    cmd concat()\n";
    enum plain = head ~ "[\"src/a.txt\", \"src/b.txt\"]" ~ tail ~ "}\ndefault \"out/j.txt\"\n";
    enum costly = head ~ "[\"src/a.txt\", \"src/b.txt\"]" ~ tail ~ "    cost 5\n}\ndefault \"out/j.txt\"\n";
    enum swapped = head ~ "[\"src/b.txt\", \"src/a.txt\"]" ~ tail ~ "    cost 5\n}\ndefault \"out/j.txt\"\n";
    static assert(plain.length == 100);
    auto ws = workspaceOf("src/a.txt", "a\n", "src/b.txt", "a\n", "main.kiln", plain);
    auto log = run(ws, "build\nedit main.kiln\n" ~ costly ~ "---\nbuild\nedit main.kiln\n" ~ swapped ~ "---\nbuild\n");
    assert(log == "step 1: build (default) -j 1\n  run 0 2 w0 out/j.txt concat()\n  ok ran=1 hit=0 time=2\n"
            ~ "step 2: edit main.kiln\n  ok size=111\n"
            ~ "step 3: build (default) -j 1\n  hit 0 out/j.txt\n  ok ran=0 hit=1 time=0\n"
            ~ "step 4: edit main.kiln\n  ok size=111\n"
            ~ "step 5: build (default) -j 1\n  run 0 5 w0 out/j.txt concat()\n  ok ran=1 hit=0 time=5\n");
}

@system unittest // example 15 and clean: outputs are verified
{
    auto ws = workspaceOf("main.kiln", helloKiln);
    auto log = run(ws, "build\nedit out/hello.txt\ntampered\n---\nbuild\ndelete out/hello.txt\nbuild\nclean\nbuild\n");
    assert(log == "step 1: build (default) -j 1\n  run 0 1 w0 out/hello.txt write(\"hello\\n\")\n  ok ran=1 hit=0 time=1\n"
            ~ "step 2: edit out/hello.txt\n  ok size=9\n"
            ~ "step 3: build (default) -j 1\n  run 0 1 w0 out/hello.txt write(\"hello\\n\")\n  ok ran=1 hit=0 time=1\n"
            ~ "step 4: delete out/hello.txt\n  ok\n"
            ~ "step 5: build (default) -j 1\n  run 0 1 w0 out/hello.txt write(\"hello\\n\")\n  ok ran=1 hit=0 time=1\n"
            ~ "step 6: clean\n  remove .kiln-state\n  remove out/hello.txt\n  ok removed=2\n"
            ~ "step 7: build (default) -j 1\n  run 0 1 w0 out/hello.txt write(\"hello\\n\")\n  ok ran=1 hit=0 time=1\n");
}

@system unittest // configuration errors (example 10) and a missing build file
{
    string errorOf(string mainKiln, string[] extra = [])
    {
        auto ws = workspaceOf(extra ~ ["main.kiln", mainKiln]);
        auto log = run(ws, "build\n");
        assert(!ws.exists(".kiln-state"), "configuration errors must not write state");
        return log;
    }

    assert(errorOf("step {\n out \"out/z.txt\"\n cmd write(\"1\")\n}\nstep {\n out \"out/z.txt\"\n cmd write(\"2\")\n}\n"
            ~ "default \"out/z.txt\"\n") == "step 1: build (default) -j 1\n  error E_DUP_OUTPUT out/z.txt\n");
    assert(errorOf("step {\n out \"out/z.txt\"\n in [\"src/a.txt\", \"src/missing.txt\"]\n cmd concat()\n}\n"
            ~ "default \"out/z.txt\"\n", ["src/a.txt", "a\n"])
            == "step 1: build (default) -j 1\n  error E_MISSING_INPUT src/missing.txt required by out/z.txt\n");
    assert(errorOf("step {\n out \"out/z.txt\"\n cmd write(greeting)\n}\ndefault \"out/z.txt\"\n")
            == "step 1: build (default) -j 1\n  error E_UNKNOWN_VAR greeting\n");
    assert(errorOf("let n = 3\nwhen n > 2 {\n abort \"n too large: {n}\"\n}\n")
            == "step 1: build (default) -j 1\n  error E_ABORT n too large: 3\n");
    assert(errorOf("step {\n out \"out/z.txt\"\n cmd write(\"ok\")\n}\n")
            == "step 1: build (default) -j 1\n  error E_NO_DEFAULT\n");

    auto ws = new Workspace;
    assert(run(ws, "build -j 3\n") == "step 1: build (default) -j 3\n  error E_NO_BUILD_FILE main.kiln\n");
}

@system unittest // build targets, -j parsing and unreachable steps
{
    auto ws = workspaceOf("main.kiln",
            "step {\n out \"out/a.txt\"\n cmd write(\"A\")\n}\nstep {\n out \"out/b.txt\"\n cmd write(\"B\")\n}\n"
            ~ "default \"out/b.txt\"\n");
    assert(run(ws, "build out/a.txt -j\nbuild out/a.txt out/a.txt -j 4\nbuild\n")
            == "step 1: build out/a.txt -j -j 1\n  error E_UNKNOWN_TARGET -j\n"
            ~ "step 2: build out/a.txt out/a.txt -j 4\n  run 0 1 w0 out/a.txt write(\"A\")\n  ok ran=1 hit=0 time=1\n"
            ~ "step 3: build (default) -j 1\n  run 0 1 w0 out/b.txt write(\"B\")\n  ok ran=1 hit=0 time=1\n");
}

@system unittest // a corrupt state file is treated as empty
{
    auto ws = workspaceOf("main.kiln", helloKiln, ".kiln-state", "garbage\n");
    auto log = run(ws, "build\n");
    assert(log == "step 1: build (default) -j 1\n  run 0 1 w0 out/hello.txt write(\"hello\\n\")\n  ok ran=1 hit=0 time=1\n");
    assert(ws.read(".kiln-state").length > 20);
}

@system unittest // session parsing
{
    auto steps = parseSession("# comment\n\n  build a b -j 4\ncreate x/y.txt\nline\n\n---\nclean\n");
    assert(steps.length == 3);
    assert(steps[0].kind == StepKind.build && steps[0].targets == ["a", "b"] && steps[0].workers == 4);
    assert(steps[1].kind == StepKind.create && steps[1].content == "line\n\n");
    assert(steps[2].kind == StepKind.clean);
}

@system unittest // the library API reports structured results
{
    auto ws = workspaceOf("main.kiln", helloKiln);
    auto first = runBuild(ws, [], 2);
    assert(first.ok && first.ran == 1 && first.hits == 0 && first.time == 1 && first.events.length == 1);
    auto second = runBuild(ws, ["out/hello.txt"], 2);
    assert(second.ok && second.ran == 0 && second.hits == 1 && second.events[0].kind == EventKind.hit);
    auto bad = runBuild(ws, ["@nope"], 1);
    assert(!bad.ok && !bad.executed && bad.error.kind == "E_UNKNOWN_TARGET");
}
