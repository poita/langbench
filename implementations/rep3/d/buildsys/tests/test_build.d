/// Unit tests: steps, graph validation, commands, state file and scheduler.
module tests.test_build;

import kiln;
import tests.helpers;

private enum one = "step {\n out \"out/hello.txt\"\n cmd write(\"hello\\n\")\n}\ndefault \"out/hello.txt\"\n";

unittest // specification example 1 and 2: a step, then a cache hit
{
    Vfs v;
    auto log = logOf(["main.kiln": one], "build\nbuild\ntouch main.kiln\nbuild\n", &v);
    assert(log == "step 1: build (default) -j 1\n"
            ~ "  run 0 1 w0 out/hello.txt write(\"hello\\n\")\n"
            ~ "  ok ran=1 hit=0 time=1\n"
            ~ "step 2: build (default) -j 1\n  hit 0 out/hello.txt\n  ok ran=0 hit=1 time=0\n"
            ~ "step 3: touch main.kiln\n  ok\n"
            ~ "step 4: build (default) -j 1\n  hit 0 out/hello.txt\n  ok ran=0 hit=1 time=0\n");
    assert(v.read(".kiln-state") == "kiln-state 1\nstep out/hello.txt\ncmd write(\"hello\\n\")\n"
            ~ "out out/hello.txt a9bc80cca21f28b3\nend\n");
}

unittest // example 3: worker allocation and tie-breaking
{
    string main = "";
    foreach (i, c; ["3", "1", "4", "2"])
        main ~= "step {\n out \"out/" ~ cast(char)('a' + i) ~ ".txt\"\n cmd write(\"" ~ cast(char)('A' + i)
            ~ "\\n\")\n cost " ~ c ~ "\n}\n";
    main ~= "step {\n out \"out/all.txt\"\n in [\"out/a.txt\", \"out/b.txt\", \"out/c.txt\", \"out/d.txt\"]\n"
        ~ " cmd concat()\n cost 2\n}\ndefault \"out/all.txt\"\n";
    auto log = logOf(["main.kiln": main], "build -j 2\n");
    assert(log == "step 1: build (default) -j 2\n"
            ~ "  run 0 3 w0 out/a.txt write(\"A\\n\")\n  run 0 1 w1 out/b.txt write(\"B\\n\")\n"
            ~ "  run 1 5 w1 out/c.txt write(\"C\\n\")\n  run 3 5 w0 out/d.txt write(\"D\\n\")\n"
            ~ "  run 5 7 w0 out/all.txt concat()\n  ok ran=5 hit=0 time=7\n");
}

unittest // example 8: early cutoff
{
    auto main = "step {\n out \"out/mid.txt\"\n in \"src/a.txt\"\n cmd upper()\n}\n"
        ~ "step {\n out \"out/final.txt\"\n in \"out/mid.txt\"\n cmd number()\n}\ndefault \"out/final.txt\"\n";
    auto log = logOf(["main.kiln": main, "src/a.txt": "abc\n"], "build\nedit src/a.txt\nABC\n---\nbuild\n");
    assert(log == "step 1: build (default) -j 1\n  run 0 2 w0 out/mid.txt upper()\n"
            ~ "  run 2 4 w0 out/final.txt number()\n  ok ran=2 hit=0 time=4\n"
            ~ "step 2: edit src/a.txt\n  ok size=4\n"
            ~ "step 3: build (default) -j 1\n  run 0 2 w0 out/mid.txt upper()\n"
            ~ "  hit 2 out/final.txt\n  ok ran=1 hit=1 time=2\n");
}

unittest // example 12: an execution error cancels work in flight
{
    auto main = "step {\n out \"out/doc.txt\"\n depfile \"out/doc.d\"\n in \"src/main.txt\"\n cmd preprocess()\n}\n"
        ~ "step {\n out \"out/slow.txt\"\n cmd write(\"slow\\n\")\n cost 10\n}\n"
        ~ "step {\n out \"out/after.txt\"\n in \"out/doc.txt\"\n cmd copy()\n}\n"
        ~ "phony all = [\"out/doc.txt\", \"out/slow.txt\", \"out/after.txt\"]\ndefault \"@all\"\n";
    Vfs v;
    auto log = logOf(["main.kiln": main, "src/main.txt": "@need src/gone.txt\n"], "build -j 2\n", &v);
    assert(log == "step 1: build (default) -j 2\n  fail 0 6 w0 out/doc.txt preprocess()\n"
            ~ "  cancel 0 10 w1 out/slow.txt write(\"slow\\n\")\n"
            ~ "  error E_NEED_MISSING src/gone.txt needed by src/main.txt\n");
    assert(v.read(".kiln-state") == "kiln-state 1\n");
    assert(!v.exists("out/slow.txt"));
}

unittest // example 14: cost is not a change, the dependency list is
{
    string mk(string ins, string extra)
    {
        return "step {\n out \"out/j.txt\"\n in " ~ ins ~ "\n cmd concat()\n" ~ extra ~ "}\ndefault \"out/j.txt\"\n";
    }
    auto session = "build\nedit main.kiln\n" ~ mk(`["src/a.txt", "src/b.txt"]`, " cost 5\n")
        ~ "---\nbuild\nedit main.kiln\n" ~ mk(`["src/b.txt", "src/a.txt"]`, " cost 5\n") ~ "---\nbuild\n";
    auto log = logOf(["main.kiln": mk(`["src/a.txt", "src/b.txt"]`, ""), "src/a.txt": "a\n", "src/b.txt": "a\n"], session);
    assert(log.length > 0);
    import std.algorithm.searching : canFind;
    assert(log.canFind("step 3: build (default) -j 1\n  hit 0 out/j.txt"));
    assert(log.canFind("step 5: build (default) -j 1\n  run 0 5 w0 out/j.txt concat()"));
}

unittest // preprocess: depfile, discovered dependencies, cycles
{
    auto main = "step {\n out \"out/doc.txt\"\n depfile \"out/doc.d\"\n in \"src/main.txt\"\n cmd preprocess()\n}\n"
        ~ "default \"out/doc.txt\"\n";
    Vfs v;
    auto files = ["main.kiln": main, "src/main.txt": "title\n@need src/part.txt\nend\n",
        "src/part.txt": "PART-A\n@need src/deep.txt\n", "src/deep.txt": "DEEP\n"];
    auto log = logOf(files, "build\nbuild\nedit src/deep.txt\nDEEP2\n---\nbuild\n", &v);
    import std.algorithm.searching : canFind;
    assert(log.canFind("step 2: build (default) -j 1\n  hit 0 out/doc.txt"));
    assert(log.canFind("step 4: build (default) -j 1\n  run 0 6 w0 out/doc.txt preprocess()"));
    assert(v.read("out/doc.txt") == "title\nPART-A\nDEEP2\nend\n");
    assert(v.read("out/doc.d") == "kiln-deps 1\nneed src/deep.txt\nneed src/part.txt\n");

    files["src/deep.txt"] = "@need src/part.txt\n";
    log = logOf(files, "build\n");
    assert(log.canFind("error E_NEED_CYCLE src/part.txt"));
    files["src/deep.txt"] = "@need bad path\n";
    assert(logOf(files, "build\n").canFind("error E_NEED_PATH bad path"));
}

unittest // graph validation errors, in the documented order
{
    auto w = (string s) => ["main.kiln": s, "src/a.txt": "a\n"];
    assert(graphError(w("step {\n out \"out/z\"\n cmd write(\"1\")\n}\nstep {\n out \"out/z\"\n cmd write(\"2\")\n}\ndefault \"out/z\"\n"))
            == "E_DUP_OUTPUT out/z");
    assert(graphError(w("step {\n out \"out/z\"\n in [\"src/a.txt\", \"src/missing.txt\"]\n cmd concat()\n}\ndefault \"out/z\"\n"))
            == "E_MISSING_INPUT src/missing.txt required by out/z");
    assert(graphError(w("step {\n out \"out/z\"\n cmd write(\"1\")\n}\n")) == "E_NO_DEFAULT");
    assert(graphError(w("default \"nowhere\"\n"), ["src/a.txt"]) == "E_UNKNOWN_TARGET nowhere");
    assert(graphError(w("step {\n out \"out/x\"\n in \"out/y\"\n cmd copy()\n}\n"
            ~ "step {\n out \"out/y\"\n in \"out/x\"\n cmd copy()\n}\ndefault \"out/x\"\n"))
            == "E_CYCLE out/x -> out/y -> out/x");
    assert(graphError(w("step {\n out \"out/x\"\n in \"out/x\"\n cmd copy()\n}\ndefault \"out/x\"\n"))
            == "E_CYCLE out/x -> out/x");
    assert(graphError(w("phony p = [\"@q\"]\ndefault \"@p\"\n")) == "E_MISSING_INPUT @q required by @p");
    assert(graphError(w("phony p = []\nphony p = []\n")) == "E_DUP_PHONY p");
}

unittest // step field and shape errors
{
    string st(string body) { return "step {\n" ~ body ~ "}\n"; }
    assert(configError(["main.kiln": st(" cmd write(\"x\")\n")]) == "E_STEP_FIELD missing out");
    assert(configError(["main.kiln": st(" out \"out/a\"\n")]) == "E_STEP_FIELD missing cmd");
    assert(configError(["main.kiln": st(" out \"out/a\"\n cost 1\n cost zzz\n cmd write(\"\")\n")])
            == "E_STEP_FIELD duplicate cost");
    assert(configError(["main.kiln": st(" out \"src/a\"\n cmd write(\"\")\n")]) == "E_OUTPUT_PATH src/a");
    assert(configError(["main.kiln": st(" out \"out/a b\"\n cmd write(\"\")\n")]) == "E_BAD_PATH out/a b");
    assert(configError(["main.kiln": st(" out \"out/a\"\n cmd nope()\n")]) == "E_UNKNOWN_CMD nope");
    assert(configError(["main.kiln": st(" out \"out/a\"\n cmd grep()\n")]) == "E_ARITY cmd grep: expected 1, got 0");
    assert(configError(["main.kiln": st(" out \"out/a\"\n cmd indent(\"x\")\n")])
            == "E_TYPE cmd indent argument 1: expected int, got str");
    assert(configError(["main.kiln": st(" out \"out/a\"\n in \"src/a\"\n cmd write(\"\")\n")])
            == "E_CMD_SHAPE write: expected inputs 0-0, got 1");
    assert(configError(["main.kiln": st(" out \"out/a\"\n cmd preprocess()\n in \"src/a\"\n")])
            == "E_CMD_SHAPE preprocess: depfile required");
    assert(configError(["main.kiln": st(" out \"out/a\"\n depfile \"out/d\"\n in \"s\"\n cmd copy()\n")])
            == "E_CMD_SHAPE copy: depfile not allowed");
    assert(configError(["main.kiln": st(" out [\"out/a\", \"out/b\"]\n in \"s\"\n cmd copy()\n")])
            == "E_CMD_SHAPE copy: expected outputs 1, got 2");
    assert(configError(["main.kiln": st(" out \"out/a\"\n in \"s\"\n cmd replace(\"\", \"x\")\n")])
            == "E_ARG cmd replace: empty pattern");
    assert(configError(["main.kiln": st(" out 5\n cmd write(\"\")\n")]) == "E_TYPE field out: expected strlist, got int");
    assert(configError(["main.kiln": st(" out [\"out/a\", 5]\n cmd write(\"\")\n")]) == "E_TYPE field out: expected strlist, got int");
}

private string runCmd(string cmd, string input, CmdArg[] args = null)
{
    auto v = new Vfs;
    auto r = runCommand(cmd, args, [ReadFile("in.txt", input, fnv1a(input))], v);
    assert(r.error is null);
    return r.output;
}

unittest // the line and text commands
{
    assert(runCmd("upper", "aé\n") == "Aé\n");
    assert(runCmd("lower", "AB\n") == "ab\n");
    assert(runCmd("sort_lines", "b\na\nc") == "a\nb\nc\n");
    assert(runCmd("reverse_lines", "a\nb\n") == "b\na\n");
    assert(runCmd("dedup", "a\nb\na\n") == "a\nb\n");
    assert(runCmd("number", "a\n\nb") == "1: a\n2: \n3: b\n");
    assert(runCmd("indent", "a\n\n", [CmdArg.ofInt(2)]) == "  a\n  \n");
    assert(runCmd("grep", "ab\ncd\nabc\n", [CmdArg.ofStr("ab")]) == "ab\nabc\n");
    assert(runCmd("grep", "x\ny", [CmdArg.ofStr("")]) == "x\ny\n");
    assert(runCmd("wrap", "mid", [CmdArg.ofStr("<<"), CmdArg.ofStr(">>")]) == "<<mid>>");
    assert(runCmd("replace", "aaa", [CmdArg.ofStr("aa"), CmdArg.ofStr("b")]) == "ba");
    assert(runCmd("count_lines", "a\nb\n") == "2 in.txt\n2 total\n");
    assert(runCmd("hash", "hello\n") == "a9bc80cca21f28b3 in.txt\n");
}

unittest // canonical command strings
{
    assert(renderCommand("write", [CmdArg.ofStr("a\"b\\\n\t\r\x01\x7f\u00fc")]) == `write("a\"b\\\n\t\r\x01\x7fü")`);
    assert(renderCommand("indent", [CmdArg.ofInt(-4)]) == "indent(-4)");
    assert(renderCommand("concat", null) == "concat()");
    assert(renderCommand("wrap", [CmdArg.ofStr("<<"), CmdArg.ofStr(">>")]) == `wrap("<<", ">>")`);
}

unittest // state file reading is strict and writing is canonical
{
    auto good = "kiln-state 1\nstep out/a\ncmd copy()\nin src/a 0123456789abcdef\ndep src/b 0123456789abcdef\n"
        ~ "out out/a 0123456789abcdef\nend\n";
    auto st = parseState(good);
    assert(st.length == 1 && st["out/a"].ins.length == 1 && st["out/a"].deps.length == 1);
    assert(writeState(st) == good);
    assert(parseState(good[0 .. $ - 1]).length == 0);                       // unterminated
    assert(parseState("kiln-state 2\n").length == 0);                       // bad header
    assert(parseState("kiln-state 1\n").length == 0 && parseState("kiln-state 1\n") is null);
    assert(parseState("kiln-state 1\nstep out/a\ncmd x\nend\n") is null);   // no out line
    assert(parseState("kiln-state 1\nstep out/a\ncmd x\nout out/b 0123456789abcdef\nend\n") is null); // key mismatch
    assert(parseState("kiln-state 1\nstep out/a\ncmd x\nout out/a 0123456789ABCDEF\nend\n") is null);  // uppercase hash
    assert(parseState("kiln-state 1\nstep out/a\ncmd x\nout out/a 0123456789abcdef\nin s 0123456789abcdef\nend\n") is null); // misordered
    assert(parseState("kiln-state 1\nstep out/a\ncmd \nout out/a 0123456789abcdef\nend\n") is null);   // empty cmd
    auto two = "kiln-state 1\nstep out/a\ncmd x\nout out/a 0123456789abcdef\nend\n";
    assert(parseState(two ~ two["kiln-state 1\n".length .. $]) is null);    // duplicate key
}

unittest // a corrupt state file simply rebuilds everything
{
    Vfs v;
    auto log = logOf(["main.kiln": one, ".kiln-state": "garbage\n"], "build\n", &v);
    assert(log == "step 1: build (default) -j 1\n  run 0 1 w0 out/hello.txt write(\"hello\\n\")\n  ok ran=1 hit=0 time=1\n");
    assert(parseState(cast(string) v.read(".kiln-state")).length == 1);
}

unittest // configuration errors leave the workspace untouched
{
    Vfs v;
    auto log = logOf(["main.kiln": "abort \"no\"\n"], "build\n", &v);
    assert(log == "step 1: build (default) -j 1\n  error E_ABORT no\n");
    assert(!v.exists(".kiln-state"));
    log = logOf(null, "build\n");
    assert(log == "step 1: build (default) -j 1\n  error E_NO_BUILD_FILE main.kiln\n");
}
