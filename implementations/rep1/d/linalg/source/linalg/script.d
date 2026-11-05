/**
 * Script driver: executes a `commands.txt` of matrix operations against an
 * input directory and writes one set of result files per command.
 */
module linalg.script;

import std.array : split;
import std.conv : to;
import std.file : exists, readText, write;
import std.format : format;
import std.path : buildPath;
import linalg.cholesky;
import linalg.eigen;
import linalg.errors;
import linalg.lu;
import linalg.matrix;
import linalg.mmio;
import linalg.qr;
import linalg.svd;

/// One output matrix of a command; the file is `NNN_<suffix>.mtx`.
struct NamedResult
{
    /// File name suffix, e.g. `"lu_L"`.
    string suffix;
    /// The matrix to write.
    Matrix value;
}

/// One parsed command line.
struct Command
{
    /// Operation name, e.g. `"mul"`.
    string op;
    /// Matrix file names.
    string[] args;
}

/// Number of arguments of `op`, or -1 if it is not a known operation.
int arity(string op) pure nothrow @safe
{
    switch (op)
    {
    case "transpose", "lu", "det", "inv", "qr", "chol", "eig", "svd",
         "norm1", "norminf", "normfro", "cond":
        return 1;
    case "add", "mul", "solve", "lstsq":
        return 2;
    default:
        return -1;
    }
}

/**
 * Parse the text of a `commands.txt`. Lines are stripped of spaces and tabs;
 * empty lines and `#` comments are dropped; the rest split on runs of spaces
 * and tabs.
 */
Command[] parseCommands(string text) pure
{
    Command[] cmds;
    foreach (rawLine; text.split('\n'))
    {
        size_t lo = 0, hi = rawLine.length;
        while (lo < hi && isWs(rawLine[lo])) ++lo;
        while (hi > lo && isWs(rawLine[hi - 1])) --hi;
        auto line = rawLine[lo .. hi];
        if (line.length == 0 || line[0] == '#')
            continue;
        string[] toks;
        size_t i = 0;
        while (i < line.length)
        {
            while (i < line.length && isWs(line[i])) ++i;
            immutable s = i;
            while (i < line.length && !isWs(line[i])) ++i;
            if (i > s)
                toks ~= line[s .. i];
        }
        cmds ~= Command(toks[0], toks[1 .. $]);
    }
    return cmds;
}

private bool isWs(char c) pure nothrow @nogc @safe
{
    return c == ' ' || c == '\t' || c == '\r';
}

private Matrix scalar(double v) pure nothrow
{
    return Matrix(1, 1, [v]);
}

private Matrix column(const double[] v) pure nothrow
{
    return Matrix(v.length, 1, v.dup);
}

/**
 * Execute one operation on already-loaded operands.
 *
 * Throws: $(REF LinalgException, linalg,errors) for the failure cases of
 * the specification.
 */
NamedResult[] execute(string op, const(Matrix)[] args)
{
    if (arity(op) < 0)
        throw new Exception("unknown operation: " ~ op);
    if (args.length != arity(op))
        throw new Exception("wrong number of arguments for " ~ op);
    switch (op)
    {
    case "add":
        return [NamedResult("add", add(args[0], args[1]))];
    case "mul":
        return [NamedResult("mul", multiply(args[0], args[1]))];
    case "transpose":
        return [NamedResult("transpose", transpose(args[0]))];
    case "lu":
        auto f = luFactor(args[0]);
        enforceCode(!f.singular, ErrorCode.singular);
        return [NamedResult("lu_P", f.P), NamedResult("lu_L", f.L),
                NamedResult("lu_U", f.U)];
    case "det":
        return [NamedResult("det", scalar(determinant(args[0])))];
    case "inv":
        return [NamedResult("inv", inverse(args[0]))];
    case "solve":
        return [NamedResult("solve", solve(args[0], args[1]))];
    case "qr":
        auto f = qrFactor(args[0]);
        return [NamedResult("qr_Q", f.Q), NamedResult("qr_R", f.R)];
    case "chol":
        return [NamedResult("chol_L", cholesky(args[0]))];
    case "eig":
        auto e = symmetricEigen(args[0]);
        return [NamedResult("eig_w", column(e.w)), NamedResult("eig_V", e.V)];
    case "svd":
        auto s = svd(args[0]);
        return [NamedResult("svd_U", s.U), NamedResult("svd_S", column(s.s)),
                NamedResult("svd_V", s.V)];
    case "lstsq":
        return [NamedResult("lstsq", leastSquares(args[0], args[1]))];
    case "norm1":
        return [NamedResult("norm1", scalar(norm1(args[0])))];
    case "norminf":
        return [NamedResult("norminf", scalar(normInf(args[0])))];
    case "normfro":
        return [NamedResult("normfro", scalar(normFro(args[0])))];
    case "cond":
        return [NamedResult("cond", scalar(conditionNumber(args[0])))];
    default:
        assert(0);
    }
}

/**
 * Run `<inputDir>/commands.txt`, writing results into `outputDir`.
 *
 * Matrices are parsed on first use and cached by file name. A command that
 * fails with a $(REF LinalgException, linalg,errors) produces `NNN_error.txt`
 * holding the error code; the remaining commands still run.
 */
void runScript(string inputDir, string outputDir)
{
    auto cmds = parseCommands(readText(buildPath(inputDir, "commands.txt")));
    Matrix[string] cache;

    Matrix load(string name)
    {
        if (auto p = name in cache)
            return *p;
        auto m = readMatrixMarket(buildPath(inputDir, name));
        cache[name] = m;
        return m;
    }

    foreach (idx, cmd; cmds)
    {
        immutable num = format("%03d", idx + 1);
        try
        {
            Matrix[] args;
            foreach (name; cmd.args)
                args ~= load(name);
            foreach (r; execute(cmd.op, args))
                write(buildPath(outputDir, num ~ "_" ~ r.suffix ~ ".mtx"),
                      formatMatrixMarket(r.value));
        }
        catch (LinalgException e)
        {
            write(buildPath(outputDir, num ~ "_error.txt"), e.msg ~ "\n");
        }
        catch (Exception e)
        {
            write(buildPath(outputDir, num ~ "_error.txt"), "internal_error\n");
        }
    }
}
