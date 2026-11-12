/**
 * End-to-end tests: sessions run through `runSession`, mirroring the worked
 * examples of the language definition.  Compiled only for `dub test`.
 */
module kiln.examples_test;

version (unittest):

import kiln.session;
import kiln.vfs;

private struct Outcome
{
    string log;
    Vfs fs;
}

private Outcome play(string[string] files, string script)
{
    auto fs = new Vfs;
    foreach (k, v; files)
        fs.write(k, v);
    const log = runSession(fs, parseSession(script));
    return Outcome(log, fs);
}

// Example 4: variables, interpolation, `each`, `map`, phony targets.
unittest
{
    enum main = `let names = ["alpha", "beta", "gamma"]
let outs = map(names, "out/%.txt")
each i, n in names {
    step {
        out "out/{n}.txt"
        cmd write("{i}:{n}\n")
        cost 1
    }
}
step {
    out "out/index.txt"
    in outs
    cmd concat()
}
phony all = ["out/index.txt"]
default "@all"
`;
    auto r = play(["main.kiln": main], "build @all -j 3\n");
    assert(r.log == "step 1: build @all -j 3\n"
            ~ "  run 0 1 w0 out/alpha.txt write(\"0:alpha\\n\")\n"
            ~ "  run 0 1 w1 out/beta.txt write(\"1:beta\\n\")\n"
            ~ "  run 0 1 w2 out/gamma.txt write(\"2:gamma\\n\")\n"
            ~ "  run 1 3 w0 out/index.txt concat()\n"
            ~ "  ok ran=4 hit=0 time=3\n");
    assert(r.fs.read("out/index.txt") == "0:alpha\n1:beta\n2:gamma\n");
}

// Example 5: rule templates, keyword arguments and the state file.
unittest
{
    enum main = `rule bundle(name, parts, weight = 2) {
    step {
        out "out/{name}.txt"
        in parts
        cmd concat()
        cost weight
    }
}

let base = ["src/a.txt", "src/b.txt"]
use bundle("one", base)
use bundle(name = "two", parts = base ++ ["out/one.txt"], weight = 5)
phony all = ["out/one.txt", "out/two.txt"]
default "@all"
`;
    auto r = play(["main.kiln": main, "src/a.txt": "AAA\n", "src/b.txt": "BBB\n"], "build -j 2\n");
    assert(r.log == "step 1: build (default) -j 2\n  run 0 2 w0 out/one.txt concat()\n"
            ~ "  run 2 7 w0 out/two.txt concat()\n  ok ran=2 hit=0 time=7\n");
    assert(r.fs.read(".kiln-state") == "kiln-state 1\nstep out/one.txt\ncmd concat()\n"
            ~ "in src/a.txt 8943a78b9f342c58\nin src/b.txt c857dca71c36fafd\nout out/one.txt 5e52e06e8b405ae8\nend\n"
            ~ "step out/two.txt\ncmd concat()\nin src/a.txt 8943a78b9f342c58\nin src/b.txt c857dca71c36fafd\n"
            ~ "in out/one.txt 5e52e06e8b405ae8\nout out/two.txt f98ee131e7582add\nend\n");
}

// Example 6: glob, include, set, when/otherwise.
unittest
{
    enum main = `let mode = "fast"
let flags = []
include "tune.kiln"
when mode == "fast" {
    set flags = flags ++ ["F"]
} otherwise {
    set flags = flags ++ ["S"]
}
let srcs = glob("src/**/*.txt")
step {
    out "out/list.txt"
    in srcs
    cmd count_lines()
}
step {
    out "out/flags.txt"
    cmd write("{join(flags, ",")}\n")
}
default ["out/list.txt", "out/flags.txt"]
`;
    auto r = play(["main.kiln": main, "tune.kiln": "set mode = \"slow\"\nlet extra = 1\n",
            "src/a.txt": "a1\n", "src/b.txt": "b1\n", "src/sub/c.txt": "c1\n", "src/notes.md": "note\n"],
            "build -j 2\n");
    assert(r.log == "step 1: build (default) -j 2\n  run 0 2 w0 out/list.txt count_lines()\n"
            ~ "  run 0 1 w1 out/flags.txt write(\"S\\n\")\n  ok ran=2 hit=0 time=2\n");
    assert(r.fs.read("out/list.txt") == "1 src/a.txt\n1 src/b.txt\n1 src/sub/c.txt\n3 total\n");
}

// Example 7: preprocess, depfiles and discovered dependencies.
unittest
{
    enum main = "step {\n    out \"out/doc.txt\"\n    depfile \"out/doc.d\"\n    in \"src/main.txt\"\n"
        ~ "    cmd preprocess()\n}\ndefault \"out/doc.txt\"\n";
    auto r = play(["main.kiln": main, "src/main.txt": "title\n@need src/part.txt\nend\n",
            "src/part.txt": "PART-A\n@need src/deep.txt\n", "src/deep.txt": "DEEP\n"],
            "build\nbuild\nedit src/deep.txt\nDEEP2\n---\nbuild\n");
    assert(r.log == "step 1: build (default) -j 1\n  run 0 6 w0 out/doc.txt preprocess()\n  ok ran=1 hit=0 time=6\n"
            ~ "step 2: build (default) -j 1\n  hit 0 out/doc.txt\n  ok ran=0 hit=1 time=0\n"
            ~ "step 3: edit src/deep.txt\n  ok size=6\n"
            ~ "step 4: build (default) -j 1\n  run 0 6 w0 out/doc.txt preprocess()\n  ok ran=1 hit=0 time=6\n");
    assert(r.fs.read("out/doc.txt") == "title\nPART-A\nDEEP2\nend\n");
    assert(r.fs.read("out/doc.d") == "kiln-deps 1\nneed src/deep.txt\nneed src/part.txt\n");
    assert(r.fs.read(".kiln-state") == "kiln-state 1\nstep out/doc.txt\ncmd preprocess()\n"
            ~ "in src/main.txt 993a20756b253540\ndep src/deep.txt 06ae7bdd484568d7\n"
            ~ "dep src/part.txt a8442a790131f243\nout out/doc.txt f755eb555e1be12f\nout out/doc.d ea603661a409bc02\nend\n");
}

// Example 13: `after` is order-only.
unittest
{
    enum main = "step {\n    out \"out/gen.txt\"\n    in \"src/a.txt\"\n    cmd copy()\n}\n"
        ~ "step {\n    out \"out/rep.txt\"\n    after \"out/gen.txt\"\n    cmd write(\"report\\n\")\n}\n"
        ~ "phony all = [\"out/rep.txt\"]\ndefault \"@all\"\n";
    auto r = play(["main.kiln": main, "src/a.txt": "a\n"], "build\nedit src/a.txt\nb\n---\nbuild\n");
    assert(r.log == "step 1: build (default) -j 1\n  run 0 1 w0 out/gen.txt copy()\n  run 1 2 w0 out/rep.txt write(\"report\\n\")\n"
            ~ "  ok ran=2 hit=0 time=2\nstep 2: edit src/a.txt\n  ok size=2\n"
            ~ "step 3: build (default) -j 1\n  run 0 1 w0 out/gen.txt copy()\n  hit 1 out/rep.txt\n  ok ran=1 hit=1 time=1\n");
}

// Example 14: cost is not a change; the dependency set is.
unittest
{
    enum v1 = "step {\n    out \"out/j.txt\"\n    in [\"src/a.txt\", \"src/b.txt\"]\n    cmd concat()\n}\ndefault \"out/j.txt\"\n";
    enum v2 = "step {\n    out \"out/j.txt\"\n    in [\"src/a.txt\", \"src/b.txt\"]\n    cmd concat()\n    cost 5\n}\ndefault \"out/j.txt\"\n";
    enum v3 = "step {\n    out \"out/j.txt\"\n    in [\"src/b.txt\", \"src/a.txt\"]\n    cmd concat()\n    cost 5\n}\ndefault \"out/j.txt\"\n";
    auto r = play(["main.kiln": v1, "src/a.txt": "a\n", "src/b.txt": "a\n"],
            "build\nedit main.kiln\n" ~ v2 ~ "---\nbuild\nedit main.kiln\n" ~ v3 ~ "---\nbuild\n");
    assert(r.log == "step 1: build (default) -j 1\n  run 0 2 w0 out/j.txt concat()\n  ok ran=1 hit=0 time=2\n"
            ~ "step 2: edit main.kiln\n  ok size=111\n"
            ~ "step 3: build (default) -j 1\n  hit 0 out/j.txt\n  ok ran=0 hit=1 time=0\n"
            ~ "step 4: edit main.kiln\n  ok size=111\n"
            ~ "step 5: build (default) -j 1\n  run 0 5 w0 out/j.txt concat()\n  ok ran=1 hit=0 time=5\n");
}

// Example 15: tampering with and deleting an output.
unittest
{
    enum main = "step {\n    out \"out/hello.txt\"\n    cmd write(\"hello\\n\")\n}\ndefault \"out/hello.txt\"\n";
    auto r = play(["main.kiln": main], "build\nedit out/hello.txt\ntampered\n---\nbuild\ndelete out/hello.txt\nbuild\n");
    enum runLine = "  run 0 1 w0 out/hello.txt write(\"hello\\n\")\n  ok ran=1 hit=0 time=1\n";
    assert(r.log == "step 1: build (default) -j 1\n" ~ runLine ~ "step 2: edit out/hello.txt\n  ok size=9\n"
            ~ "step 3: build (default) -j 1\n" ~ runLine ~ "step 4: delete out/hello.txt\n  ok\n"
            ~ "step 5: build (default) -j 1\n" ~ runLine);
}

// Configuration errors leave the workspace untouched and write no state.
unittest
{
    auto r = play(["main.kiln": "let n = 3\nwhen n > 2 {\n    abort \"n too large: {n}\"\n}\n"], "build\n");
    assert(r.log == "step 1: build (default) -j 1\n  error E_ABORT n too large: 3\n");
    assert(!r.fs.exists(".kiln-state"));

    r = play(["main.kiln": "let x = 1\nlet = 2\n"], "build\n");
    assert(r.log == "step 1: build (default) -j 1\n  error E_PARSE main.kiln:2\n");

    r = play(null, "build\n");
    assert(r.log == "step 1: build (default) -j 1\n  error E_NO_BUILD_FILE main.kiln\n");
}

// A corrupt state file is ignored and then replaced.
unittest
{
    enum main = "step {\n    out \"out/hello.txt\"\n    cmd write(\"hello\\n\")\n}\ndefault \"out/hello.txt\"\n";
    auto r = play(["main.kiln": main, ".kiln-state": "kiln-state 1\nstep out/hello.txt\n"], "build\nbuild\n");
    assert(r.log == "step 1: build (default) -j 1\n  run 0 1 w0 out/hello.txt write(\"hello\\n\")\n  ok ran=1 hit=0 time=1\n"
            ~ "step 2: build (default) -j 1\n  hit 0 out/hello.txt\n  ok ran=0 hit=1 time=0\n");
}
