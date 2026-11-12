/// The batch driver behind the command-line tool: read `commands.txt`, answer
/// every line, write `NNN.out` files.
module gitrepo.batch;

import std.file : exists, mkdirRecurse, readFile = read, writeFile = write;

import gitrepo.commands;
import gitrepo.errors;
import gitrepo.repository;

/// The bytes written for a command that fails.
immutable ubyte[] errorOutput = cast(immutable(ubyte)[]) "error\n";

/// Split the content of a `commands.txt` into command lines (LF separated; the
/// final line may lack its newline).
const(ubyte)[][] splitCommands(const(ubyte)[] text) @safe pure nothrow
{
    const(ubyte)[][] lines;
    size_t start;
    foreach (i; 0 .. text.length)
        if (text[i] == '\n')
        {
            lines ~= text[start .. i];
            start = i + 1;
        }
    if (start < text.length)
        lines ~= text[start .. $];
    return lines;
}

/// The name of the output file for command number `k` (1-based): decimal,
/// zero-padded to at least three digits, plus `.out`.
string outputName(size_t k) @safe pure nothrow
{
    string s;
    do
    {
        s = cast(char)('0' + k % 10) ~ s;
        k /= 10;
    }
    while (k);
    while (s.length < 3)
        s = "0" ~ s;
    return s ~ ".out";
}

/// Answer one command line, never throwing: any failure yields `errorOutput`.
const(ubyte)[] answer(Repository repo, const(ubyte)[] line) nothrow
{
    try
        return execute(repo, cast(const(char)[]) line);
    catch (Throwable)
        return errorOutput; // GitError, or anything unforeseen: the contract is "error", never a crash
}

/// Run every command of `<inputDir>/commands.txt` against `<inputDir>/repo`,
/// writing `<outputDir>/NNN.out` for each.
void runBatch(string inputDir, string outputDir)
{
    mkdirRecurse(outputDir);
    const(ubyte)[] text;
    immutable cmdPath = inputDir ~ "/commands.txt";
    if (exists(cmdPath))
        text = cast(const(ubyte)[]) readFile(cmdPath);
    auto lines = splitCommands(text);
    Repository repo;
    try
        repo = new Repository(inputDir ~ "/repo");
    catch (Exception)
        repo = null;
    foreach (k, line; lines)
    {
        const(ubyte)[] result = repo is null ? errorOutput : answer(repo, line);
        writeFile(outputDir ~ "/" ~ outputName(k + 1), result);
    }
}

unittest
{
    assert(outputName(1) == "001.out");
    assert(outputName(999) == "999.out");
    assert(outputName(1000) == "1000.out");
    assert(splitCommands(cast(const(ubyte)[]) "a\nb") == [cast(const(ubyte)[]) "a", cast(const(ubyte)[]) "b"]);
    assert(splitCommands(cast(const(ubyte)[]) "a\nb\n").length == 2);
    assert(splitCommands([]).length == 0);
    assert(splitCommands(cast(const(ubyte)[]) "a\n\nb").length == 3);
}
