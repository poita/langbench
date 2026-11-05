/// End-to-end tests of builds and sessions.
module build_test;

import helpers;
import kiln.build;
import kiln.session;
import kiln.vfs;

private enum chain = "step {\n out \"out/a\"\n in \"src/a\"\n cmd upper()\n}\n"
    ~ "step {\n out \"out/b\"\n in \"out/a\"\n cmd number()\n}\ndefault \"out/b\"\n";

unittest // first build, cache hit, early cutoff
{
    Vfs v;
    auto log = session(["main.kiln": chain, "src/a": "abc\n"], "build\nbuild\nedit src/a\nABC\n---\nbuild\n", &v);
    assert(log == "step 1: build (default) -j 1\n  run 0 2 w0 out/a upper()\n  run 2 4 w0 out/b number()\n  ok ran=2 hit=0 time=4\n"
            ~ "step 2: build (default) -j 1\n  hit 0 out/a\n  hit 0 out/b\n  ok ran=0 hit=2 time=0\n"
            ~ "step 3: edit src/a\n  ok size=4\n"
            ~ "step 4: build (default) -j 1\n  run 0 2 w0 out/a upper()\n  hit 2 out/b\n  ok ran=1 hit=1 time=2\n");
    assert(v.content("out/b") == "1: ABC\n");
}

unittest // touch never rebuilds; clean removes generated files and the state
{
    auto log = session(["main.kiln": chain, "src/a": "abc\n"], "build\ntouch src/a\nbuild\nclean\nbuild -j 2\n");
    assert(log == "step 1: build (default) -j 1\n  run 0 2 w0 out/a upper()\n  run 2 4 w0 out/b number()\n  ok ran=2 hit=0 time=4\n"
            ~ "step 2: touch src/a\n  ok\n"
            ~ "step 3: build (default) -j 1\n  hit 0 out/a\n  hit 0 out/b\n  ok ran=0 hit=2 time=0\n"
            ~ "step 4: clean\n  remove .kiln-state\n  remove out/a\n  remove out/b\n  ok removed=3\n"
            ~ "step 5: build (default) -j 2\n  run 0 2 w0 out/a upper()\n  run 2 4 w0 out/b number()\n  ok ran=2 hit=0 time=4\n");
}

unittest // parallel scheduling: lowest worker first, ties by serial
{
    enum m = "step {\n out \"out/a\"\n cmd write(\"A\")\n cost 3\n}\n"
        ~ "step {\n out \"out/b\"\n cmd write(\"B\")\n cost 1\n}\n"
        ~ "step {\n out \"out/c\"\n cmd write(\"C\")\n cost 4\n}\n"
        ~ "step {\n out \"out/d\"\n cmd write(\"D\")\n cost 2\n}\n"
        ~ "step {\n out \"out/all\"\n in [\"out/a\", \"out/b\", \"out/c\", \"out/d\"]\n cmd concat()\n cost 2\n}\n"
        ~ "default \"out/all\"\n";
    auto log = session(["main.kiln": m], "build -j 2\n");
    assert(log == "step 1: build (default) -j 2\n  run 0 3 w0 out/a write(\"A\")\n  run 0 1 w1 out/b write(\"B\")\n"
            ~ "  run 1 5 w1 out/c write(\"C\")\n  run 3 5 w0 out/d write(\"D\")\n  run 5 7 w0 out/all concat()\n"
            ~ "  ok ran=5 hit=0 time=7\n");
}

unittest // cost 0 is still dispatched and logged
{
    auto log = session(["main.kiln": "step {\n out \"out/z\"\n cmd write(\"\")\n cost 0\n}\ndefault \"out/z\"\n"], "build\n");
    assert(log == "step 1: build (default) -j 1\n  run 0 0 w0 out/z write(\"\")\n  ok ran=1 hit=0 time=0\n");
}

unittest // configuration errors leave the workspace untouched
{
    Vfs v;
    auto log = session(["main.kiln": "step {\n out \"out/x\"\n in \"out/y\"\n cmd copy()\n}\n"
            ~ "step {\n out \"out/y\"\n in \"out/x\"\n cmd copy()\n}\ndefault \"out/x\"\n"], "build\n", &v);
    assert(log == "step 1: build (default) -j 1\n  error E_CYCLE out/x -> out/y -> out/x\n");
    assert(v.length == 1);
}

unittest // execution error: failure, cancellation, state still written
{
    Vfs v;
    auto m = "step {\n out \"out/doc\"\n depfile \"out/doc.d\"\n in \"src/m\"\n cmd preprocess()\n}\n"
        ~ "step {\n out \"out/slow\"\n cmd write(\"s\")\n cost 10\n}\n"
        ~ "step {\n out \"out/after\"\n in \"out/doc\"\n cmd copy()\n}\n"
        ~ "phony all = [\"out/doc\", \"out/slow\", \"out/after\"]\ndefault \"@all\"\n";
    auto log = session(["main.kiln": m, "src/m": "@need src/gone\n"], "build -j 2\n", &v);
    assert(log == "step 1: build (default) -j 2\n  fail 0 6 w0 out/doc preprocess()\n"
            ~ "  cancel 0 10 w1 out/slow write(\"s\")\n  error E_NEED_MISSING src/gone needed by src/m\n");
    assert(v.content(".kiln-state") == "kiln-state 1\n");
    assert(!v.exists("out/slow"));
}

unittest // order-only dependencies delay a step but never make it stale
{
    enum m = "step {\n out \"out/gen\"\n in \"src/a\"\n cmd copy()\n}\n"
        ~ "step {\n out \"out/rep\"\n after \"out/gen\"\n cmd write(\"r\")\n}\ndefault \"out/rep\"\n";
    auto log = session(["main.kiln": m, "src/a": "a\n"], "build\nedit src/a\nb\n---\nbuild\n");
    assert(log == "step 1: build (default) -j 1\n  run 0 1 w0 out/gen copy()\n  run 1 2 w0 out/rep write(\"r\")\n  ok ran=2 hit=0 time=2\n"
            ~ "step 2: edit src/a\n  ok size=2\n"
            ~ "step 3: build (default) -j 1\n  run 0 1 w0 out/gen copy()\n  hit 1 out/rep\n  ok ran=1 hit=1 time=1\n");
}

unittest // a build line that names -j as a target
{
    auto log = session(["main.kiln": chain, "src/a": "abc\n"], "build out/b -j\n");
    assert(log == "step 1: build out/b -j -j 1\n  error E_UNKNOWN_TARGET -j\n");
}

unittest // corrupt state is ignored and overwritten
{
    auto log = session(["main.kiln": chain, "src/a": "abc\n", ".kiln-state": "garbage\n"], "build\n");
    assert(log == "step 1: build (default) -j 1\n  run 0 2 w0 out/a upper()\n  run 2 4 w0 out/b number()\n  ok ran=2 hit=0 time=4\n");
}

unittest // error reporting order inside a build
{
    assert(buildOnce("").error == "E_NO_DEFAULT");
    assert(buildOnce("abort 1\n").error == "E_TYPE abort message: expected str, got int");
    assert(buildOnce("let x = \"abc\n").error == "E_PARSE main.kiln:1");
    assert(buildOnce("step {\n out \"x\"\n cmd write(\"\")\n}\n").error == "E_OUTPUT_PATH x");
    assert(buildOnce("step {\n out \"out/x\"\n}\n").error == "E_STEP_FIELD missing cmd");
    assert(buildOnce("step {\n cmd write(\"\")\n}\n").error == "E_STEP_FIELD missing out");
    assert(buildOnce("step {\n out \"out/x\"\n cmd copy()\n}\n").error == "E_CMD_SHAPE copy: expected inputs 1-1, got 0");
    assert(buildOnce("step {\n out \"out/x\"\n cmd write(\"\")\n depfile \"out/d\"\n}\n").error
            == "E_CMD_SHAPE write: depfile not allowed");
    assert(buildOnce("phony a = []\nphony a = []\n").error == "E_DUP_PHONY a");
    assert(buildOnce("default \"nope\"\n").error == "E_UNKNOWN_TARGET nope");
}
