/// Batch mode: run a `commands.txt` against a repository and write `NNN.out` files.
module gitrepo.batch;

import std.conv : to;
import std.exception : assumeUnique;
import std.file;
import std.format : format;

import gitrepo.queries;
import gitrepo.repository;

/// The content written for a command that fails.
immutable string errorOutput = "error\n";

/// Splits the contents of a commands file into command lines (LF separated; a final
/// line may lack its newline).
string[] splitCommands(string text) @safe pure nothrow
{
    string[] lines;
    size_t start = 0;
    foreach (i; 0 .. text.length)
    {
        if (text[i] == '\n')
        {
            lines ~= text[start .. i];
            start = i + 1;
        }
    }
    if (start < text.length)
        lines ~= text[start .. $];
    return lines;
}

/// Runs one command line; any failure is turned into `error\n`.
const(ubyte)[] answer(Repository repo, string line) nothrow
{
    try
        return execute(repo, line);
    catch (Exception)
        return cast(const(ubyte)[]) errorOutput;
    catch (Error)
        return cast(const(ubyte)[]) errorOutput;
}

/// Reads `<inputDir>/commands.txt` and the repository `<inputDir>/repo`, and writes
/// `<outputDir>/NNN.out` for every command (numbered from 1, zero padded to 3 digits).
void runBatch(string inputDir, string outputDir)
{
    string text;
    try
        text = assumeUnique(cast(char[]) std.file.read(inputDir ~ "/commands.txt"));
    catch (Exception)
        text = "";
    auto repo = new Repository(inputDir ~ "/repo");
    mkdirRecurse(outputDir);
    foreach (k, line; splitCommands(text))
        std.file.write(outputDir ~ "/" ~ format("%03d", k + 1) ~ ".out", answer(repo, line));
}
