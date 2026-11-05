module tests.script_test;

import std.file : exists, mkdirRecurse, readText, rmdirRecurse, write, dirEntries, SpanMode, tempDir;
import std.path : buildPath;
import std.conv : to;
import std.process : thisProcessID;
import std.array : array;
import std.algorithm : sort, map;
import linalg;

unittest // command-file parsing: comments, blanks and whitespace
{
    auto cmds = parseCommands("# hi\n\n  add a.mtx\tb.mtx  \r\n   # x\n\tdet   a.mtx\n");
    assert(cmds.length == 2);
    assert(cmds[0].op == "add" && cmds[0].args == ["a.mtx", "b.mtx"]);
    assert(cmds[1].op == "det" && cmds[1].args == ["a.mtx"]);
    assert(parseCommands("").length == 0);
}

unittest // arities
{
    assert(arity("add") == 2 && arity("lu") == 1 && arity("lstsq") == 2);
    assert(arity("bogus") == -1);
}

unittest // execute returns the right named outputs
{
    auto a = Matrix.fromRows([[1.0, 2.0], [3.0, 4.0]]);
    auto r = execute("lu", [a]);
    assert(r.length == 3 && r[0].suffix == "lu_P" && r[2].suffix == "lu_U");
    assert(execute("det", [a])[0].value[0, 0] == -2.0);
    assert(execute("svd", [a]).length == 3);
    assert(execute("eig", [Matrix.identity(2)])[0].value.rows == 2);
}

unittest // whole run: numbering skips comments, errors go to NNN_error.txt
{
    auto root = buildPath(tempDir, "linalg_script_test_" ~ to!string(thisProcessID));
    auto inDir = buildPath(root, "in");
    auto outDir = buildPath(root, "out");
    mkdirRecurse(inDir);
    mkdirRecurse(outDir);
    scope (exit) rmdirRecurse(root);

    write(buildPath(inDir, "commands.txt"),
        "# example\nadd a.mtx b.mtx\n\ndet a.mtx\nchol r.mtx\nchol s.mtx\n");
    write(buildPath(inDir, "a.mtx"),
        "%%MatrixMarket matrix array real general\n2 2\n1.0\n3.0\n2.0\n4.0\n");
    write(buildPath(inDir, "b.mtx"),
        "%%MatrixMarket matrix coordinate real general\n2 2 2\n1 1 0.5\n2 2 -1.5\n");
    write(buildPath(inDir, "r.mtx"),
        "%%MatrixMarket matrix array real general\n2 3\n1\n2\n3\n4\n5\n6\n");
    write(buildPath(inDir, "s.mtx"),
        "%%MatrixMarket matrix array real symmetric\n2 2\n4.0\n2.0\n5.0\n");

    runScript(inDir, outDir);

    auto names = dirEntries(outDir, SpanMode.shallow).map!(e => e.name[outDir.length + 1 .. $]).array;
    names.sort();
    assert(names == ["001_add.mtx", "002_det.mtx", "003_error.txt", "004_chol_L.mtx"]);
    assert(readText(buildPath(outDir, "001_add.mtx")) ==
        "%%MatrixMarket matrix array real general\n2 2\n1.5000000000e+00\n"
        ~ "3.0000000000e+00\n2.0000000000e+00\n2.5000000000e+00\n");
    assert(readText(buildPath(outDir, "002_det.mtx")) ==
        "%%MatrixMarket matrix array real general\n1 1\n-2.0000000000e+00\n");
    assert(readText(buildPath(outDir, "003_error.txt")) == "not_square\n");
}
