/**
 * The command-script driver: parses `commands.txt`, runs each operation
 * and writes one result file per output matrix.
 *
 * `execute` is the pure dispatcher from an operation name and matrix
 * arguments to named result matrices; `runScript` adds the file handling
 * described in the specification.
 */
module linalg.script;

import std.array : array;
import std.conv : to;
import std.file : exists, write;
import std.format : format;
import std.path : buildPath;
import std.string : split, strip;

import linalg.cholesky;
import linalg.eigen;
import linalg.errors;
import linalg.lu;
import linalg.matrix;
import linalg.mmio;
import linalg.ops;
import linalg.qr;
import linalg.svd;

/// One output matrix of a command; the file is `NNN_<suffix>.mtx`.
struct Output
{
    /// File-name suffix, e.g. `lu_P`.
    string suffix;
    /// The result.
    Matrix matrix;
}

/// One parsed command line.
struct Command
{
    /// Operation name.
    string op;
    /// Matrix file names.
    string[] args;
}

/// Number of arguments an operation takes, or -1 if the operation is unknown.
int arity(string op) @safe pure nothrow @nogc
{
    switch (op)
    {
    case "add", "mul", "solve", "lstsq":
        return 2;
    case "transpose", "lu", "det", "inv", "qr", "chol", "eig", "svd",
            "norm1", "norminf", "normfro", "cond":
        return 1;
    default:
        return -1;
    }
}

/**
 * Parses the text of `commands.txt`. Lines are stripped; blank lines and
 * `#` comments are dropped, so the returned index + 1 is the command number.
 */
Command[] parseCommands(string text) @safe pure
{
    Command[] result;
    foreach (line; text.split('\n'))
    {
        const s = line.strip(" \t\r");
        if (s.length == 0 || s[0] == '#')
            continue;
        const tokens = s.split();
        result ~= Command(tokens[0].idup, tokens[1 .. $].dup);
    }
    return result;
}

private Matrix scalar(double v) @safe pure nothrow
{
    auto m = Matrix(1, 1);
    m.data[0] = v;
    return m;
}

/**
 * Runs one operation on already loaded matrices.
 *
 * Returns: the output matrices in file order.
 * Throws: `LinAlgException` for the failures listed in the specification;
 * `Exception` for an unknown operation or wrong argument count.
 */
Output[] execute(string op, const(Matrix)[] a) @safe
{
    if (arity(op) < 0 || a.length != arity(op))
        throw new Exception("invalid command: " ~ op);
    switch (op)
    {
    case "add":
        return [Output("add", add(a[0], a[1]))];
    case "mul":
        return [Output("mul", mul(a[0], a[1]))];
    case "transpose":
        return [Output("transpose", transpose(a[0]))];
    case "lu":
        {
            enforceCode(a[0].isSquare, ErrorCode.notSquare);
            const f = luFactor(a[0]);
            return [Output("lu_P", f.permutationMatrix), Output("lu_L", f.lower),
                Output("lu_U", f.upper)];
        }
    case "det":
        return [Output("det", scalar(determinant(a[0])))];
    case "inv":
        return [Output("inv", inverse(a[0]))];
    case "solve":
        return [Output("solve", solve(a[0], a[1]))];
    case "qr":
        {
            auto f = qrDecompose(a[0]);
            return [Output("qr_Q", f.q), Output("qr_R", f.r)];
        }
    case "chol":
        return [Output("chol_L", cholesky(a[0]))];
    case "eig":
        {
            auto e = symmetricEigen(a[0]);
            return [Output("eig_w", Matrix(e.w.length, 1, e.w)), Output("eig_V", e.v)];
        }
    case "svd":
        {
            auto f = svd(a[0]);
            return [Output("svd_U", f.u), Output("svd_S", Matrix(f.s.length, 1, f.s)),
                Output("svd_V", f.v)];
        }
    case "lstsq":
        return [Output("lstsq", leastSquares(a[0], a[1]))];
    case "norm1":
        return [Output("norm1", scalar(norm1(a[0])))];
    case "norminf":
        return [Output("norminf", scalar(normInf(a[0])))];
    case "normfro":
        return [Output("normfro", scalar(normFro(a[0])))];
    case "cond":
        return [Output("cond", scalar(condition(a[0])))];
    default:
        assert(0);
    }
}

/**
 * Runs `<inputDir>/commands.txt` and writes results into `outputDir`.
 *
 * Each matrix file is parsed once, on first use. A failing command writes
 * `NNN_error.txt` (the error code and a newline) and the script goes on.
 */
void runScript(string inputDir, string outputDir) @safe
{
    import std.file : readText;

    const commands = parseCommands(readText(buildPath(inputDir, "commands.txt")));
    Matrix[string] cache;

    foreach (idx, cmd; commands)
    {
        const stem = format("%03d", idx + 1);
        try
        {
            const(Matrix)[] args;
            foreach (name; cmd.args)
            {
                if (auto p = name in cache)
                    args ~= *p;
                else
                {
                    auto m = readMatrixMarket(buildPath(inputDir, name));
                    cache[name] = m;
                    args ~= m;
                }
            }
            foreach (o; execute(cmd.op, args))
                writeMatrixMarket(buildPath(outputDir, stem ~ "_" ~ o.suffix ~ ".mtx"), o.matrix);
        }
        catch (LinAlgException e)
            write(buildPath(outputDir, stem ~ "_error.txt"), cast(string) e.code ~ "\n");
        catch (Exception e)
            write(buildPath(outputDir, stem ~ "_error.txt"), "invalid_command\n");
    }
}

unittest
{
    const cmds = parseCommands("# c\n\n  add a.mtx\tb.mtx  \n\t#x\r\ndet a.mtx\r\n");
    assert(cmds.length == 2);
    assert(cmds[0] == Command("add", ["a.mtx", "b.mtx"]));
    assert(cmds[1].op == "det");
}

unittest
{
    const a = Matrix.fromRows([[1.0, 2.0], [3.0, 4.0]]);
    const o = execute("det", [a]);
    assert(o.length == 1 && o[0].suffix == "det" && o[0].matrix.data[0] == -2.0);
    assert(execute("lu", [a]).length == 3);
    assert(execute("svd", [a]).length == 3);
    assert(execute("eig", [Matrix.fromRows([[2.0, 1.0], [1.0, 3.0]])])[0].suffix == "eig_w");
}

unittest
{
    import std.exception : collectException;

    const rect = Matrix(2, 3);
    assert(collectException!LinAlgException(execute("lu", [rect])).code == ErrorCode.notSquare);
    assert(collectException!LinAlgException(execute("chol", [rect])).code == ErrorCode.notSquare);
    assert(collectException!LinAlgException(execute("lstsq", [rect, Matrix(2, 1)])).code
            == ErrorCode.dimensionMismatch);
    assert(collectException!Exception(execute("frobnicate", [rect])) !is null);
}

unittest
{
    // End to end through the file system.
    import std.file : mkdirRecurse, readText, rmdirRecurse, tempDir, dirEntries, SpanMode;
    import std.path : baseName;
    import std.algorithm : sort, map;

    const root = buildPath(tempDir(), "linalg_script_test");
    if (exists(root))
        rmdirRecurse(root);
    const inDir = buildPath(root, "in"), outDir = buildPath(root, "out");
    mkdirRecurse(inDir);
    mkdirRecurse(outDir);
    scope (exit)
        rmdirRecurse(root);

    write(buildPath(inDir, "commands.txt"), "# two by two\nadd a.mtx b.mtx\n\ndet a.mtx\nchol r.mtx\n");
    write(buildPath(inDir, "a.mtx"), "%%MatrixMarket matrix array real general\n2 2\n1.0\n3.0\n2.0\n4.0\n");
    write(buildPath(inDir, "b.mtx"),
            "%%MatrixMarket matrix coordinate real general\n2 2 2\n1 1 0.5\n2 2 -1.5\n");
    write(buildPath(inDir, "r.mtx"),
            "%%MatrixMarket matrix array real general\n2 3\n1\n2\n3\n4\n5\n6\n");
    runScript(inDir, outDir);

    auto names = dirEntries(outDir, SpanMode.shallow).map!(e => baseName(e.name)).array;
    names.sort();
    assert(names == ["001_add.mtx", "002_det.mtx", "003_error.txt"]);
    assert(readText(buildPath(outDir, "003_error.txt")) == "not_square\n");
    assert(readText(buildPath(outDir, "002_det.mtx"))
            == "%%MatrixMarket matrix array real general\n1 1\n-2.0000000000e+00\n");
}
