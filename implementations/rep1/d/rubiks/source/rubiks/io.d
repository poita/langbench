/**
 * Text I/O contract of the command-line tool: one scramble per line in, one
 * solution per line out.
 */
module rubiks.io;

import rubiks.move;
import rubiks.solver;

/**
 * Splits input text into scramble lines. A final line without a terminating
 * newline counts as a line, but a trailing newline does not start a new one,
 * so `"R\n"` and `"R"` are one scramble and `"R\n\n"` is two.
 */
const(char)[][] splitLines(const(char)[] text) pure nothrow @safe
{
    const(char)[][] lines;
    size_t start = 0;
    foreach (i, c; text)
        if (c == '\n')
        {
            lines ~= text[start .. i];
            start = i + 1;
        }
    if (start < text.length)
        lines ~= text[start .. $];
    return lines;
}

/**
 * Solves every scramble line and returns the solutions, each terminated by a
 * newline. Throws `MoveParseException` (naming the 1-based line) on a bad token.
 */
string solveLines(const Solver solver, const(char)[][] lines)
{
    import std.array : appender;
    import std.format : format;

    auto output = appender!string;
    foreach (n, line; lines)
    {
        Move[] scramble;
        try
            scramble = parseMoves(line);
        catch (MoveParseException e)
            throw new MoveParseException(format("line %s: %s", n + 1, e.msg));
        foreach (i, m; solver.solve(scramble))
        {
            if (i)
                output.put(' ');
            output.put(m.toString);
        }
        output.put('\n');
    }
    return output[];
}

@safe pure nothrow unittest
{
    assert(splitLines("R") == ["R"]);
    assert(splitLines("R\n") == ["R"]);
    assert(splitLines("R\n\n") == ["R", ""]);
    assert(splitLines("\n") == [""]);
    assert(splitLines("R U\nF\n\nD") == ["R U", "F", "", "D"]);
    assert(splitLines("").length == 0);
}

unittest
{
    import std.exception : assertThrown;
    import rubiks.cubie : CubieCube;
    import std.algorithm : splitter;
    import std.array : array;

    auto solver = new Solver;
    immutable input = "F R U'\n\nR U R' U' R U R' U' R U R' U' R U R' U' R U R' U' R U R' U'";
    auto lines = splitLines(input);
    auto output = solveLines(solver, lines);
    auto solutions = splitLines(output);
    assert(solutions.length == 3);
    assert(solutions[1] == "" && solutions[2] == "");
    foreach (i, line; lines)
    {
        auto sol = parseMoves(solutions[i]);
        assert(sol.length <= 45);
        assert(CubieCube.fromMoves(parseMoves(line) ~ sol).isSolved);
    }
    assert(output[$ - 1] == '\n');
    assertThrown!MoveParseException(solveLines(solver, ["R", "Q"]));
}
