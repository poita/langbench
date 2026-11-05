module test_commands;

import helpers;
import kiln;

// Runs `cmdText` over `input` (as src/i.txt) and returns the produced out/o.txt.
private string output(string cmdText, string input)
{
    auto v = workspace(["src/i.txt": input]);
    v.write("main.kiln", "step {\n out \"out/o.txt\"\n in \"src/i.txt\"\n cmd " ~ cmdText
            ~ "\n}\ndefault \"out/o.txt\"\n");
    auto rep = runBuild(v);
    assert(rep.ok, rep.error.render());
    return v.read("out/o.txt");
}

unittest
{
    assert(output("copy()", "a\r\nb") == "a\r\nb");
    assert(output("upper()", "abc é\n") == "ABC é\n");
    assert(output("lower()", "ABC É\n") == "abc É\n");
    assert(output("grep(\"b\")", "ab\nc\nbb") == "ab\nbb\n");
    assert(output("grep(\"\")", "a\nb") == "a\nb\n");
    assert(output("replace(\"a\", \"xx\")", "banana\nab") == "bxxnxxnxx\nxxb");
    assert(output("sort_lines()", "b\na\n\nB\n") == "\nB\na\nb\n");
    assert(output("reverse_lines()", "1\n2\n3") == "3\n2\n1\n");
    assert(output("dedup()", "a\nb\na\n\n\nb") == "a\nb\n\n");
    assert(output("number()", "x\n\ny\n") == "1: x\n2: \n3: y\n");
    assert(output("indent(2)", "x\n\n") == "  x\n  \n");
    assert(output("wrap(\"<\", \">\")", "mid") == "<mid>");
    assert(output("count_lines()", "a\nb") == "2 src/i.txt\n2 total\n");
    assert(output("hash()", "hello\n") == "a9bc80cca21f28b3 src/i.txt\n");
    assert(output("copy()", "") == "");
    assert(output("number()", "") == "");
}

unittest
{
    auto v = workspace(["a": "1\n2\n", "b": ""]);
    v.write("main.kiln", "step {\n out \"out/c\"\n in [\"a\", \"b\", \"a\"]\n cmd count_lines()\n}\n"
            ~ "step {\n out \"out/w\"\n cmd write(\"q\\0\\n\")\n}\ndefault [\"out/c\", \"out/w\"]\n");
    assert(runBuild(v).ok);
    assert(v.read("out/c") == "2 a\n0 b\n2 a\n4 total\n");
    assert(v.read("out/w") == "q\0\n");
}

unittest
{
    // preprocess: expansion, discovered set, depfile
    auto v = workspace(["src/main.txt": "title\n@need src/part.txt\nend\n",
            "src/part.txt": "PART\n@need src/deep.txt\n@need src/deep.txt\n", "src/deep.txt": "DEEP\n"]);
    v.write("main.kiln", "step {\n out \"out/doc.txt\"\n depfile \"out/doc.d\"\n in \"src/main.txt\"\n"
            ~ " cmd preprocess()\n}\ndefault \"out/doc.txt\"\n");
    auto rep = runBuild(v);
    assert(rep.ok);
    assert(v.read("out/doc.txt") == "title\nPART\nDEEP\nDEEP\nend\n");
    assert(v.read("out/doc.d") == "kiln-deps 1\nneed src/deep.txt\nneed src/part.txt\n");
}

unittest
{
    // preprocess errors are execution errors
    auto mk = (string main_, string[string] extra) {
        auto v = workspace(extra);
        v.write("src/main.txt", main_);
        v.write("main.kiln", "step {\n out \"out/doc.txt\"\n depfile \"out/doc.d\"\n in \"src/main.txt\"\n"
                ~ " cmd preprocess()\n}\ndefault \"out/doc.txt\"\n");
        return runBuild(v);
    };
    assert(mk("@need ../x\n", null).error.render() == "E_NEED_PATH ../x");
    assert(mk("@need src/gone.txt\n", null).error.render() == "E_NEED_MISSING src/gone.txt needed by src/main.txt");
    assert(mk("@need src/main.txt\n", null).error.render() == "E_NEED_CYCLE src/main.txt");
    assert(mk("@need src/a.txt\n", ["src/a.txt": "@need src/a.txt\n"]).error.render() == "E_NEED_CYCLE src/a.txt");
    // "@need" with an empty remainder is an ordinary line
    assert(mk("@need \n@needx\n", null).ok);
}
