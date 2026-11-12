/**
 * The line-oriented command language: `set`, `get`, `clear` and `dump`.
 *
 * This is what the command-line tool speaks; it is part of the library so
 * that other programs (and the tests) can drive a $(REF Sheet, spreadsheet,sheet)
 * with the same text format.
 */
module spreadsheet.script;

import spreadsheet.cellref;
import spreadsheet.sheet;
import spreadsheet.parser : ParseException;

/// Thrown for a command line that is not part of the command language.
class CommandException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

/// Receives output text (each call is one chunk, newlines included).
alias OutputSink = void delegate(const(char)[] chunk) @safe;

/**
 * Executes one command line (no trailing newline).
 *
 * `get` and `dump` write their lines (each terminated by `\n`) to `output`.
 * An empty line is ignored.
 *
 * Throws: $(LREF CommandException) for an unknown or malformed command,
 * $(REF ParseException, spreadsheet,parser) for bad `set` content.
 */
void executeCommand(Sheet sheet, string line, scope OutputSink output) @safe
{
    if (line.length == 0)
        return;
    size_t sp = 0;
    while (sp < line.length && line[sp] != ' ')
        sp++;
    const word = line[0 .. sp];

    if (word == "dump")
    {
        foreach (e; sheet.dump())
        {
            output(e.cell.toString);
            output(" ");
            output(e.value.toString);
            output("\n");
        }
        return;
    }
    if (word != "set" && word != "get" && word != "clear")
        throw new CommandException("unknown command: " ~ word);

    if (sp >= line.length)
        throw new CommandException("missing cell name: " ~ line);
    size_t end = sp + 1;
    while (end < line.length && line[end] != ' ')
        end++;
    CellRef cell;
    if (!tryParseCellRef(line[sp + 1 .. end], cell))
        throw new CommandException("invalid cell name: " ~ line[sp + 1 .. end]);

    switch (word)
    {
    case "get":
        output(sheet.display(cell));
        output("\n");
        break;
    case "clear":
        sheet.clear(cell);
        break;
    default:
        if (end >= line.length)
            throw new CommandException("missing content: " ~ line);
        sheet.set(cell, line[end + 1 .. $]);
        break;
    }
}

/**
 * Executes every line of `script` (lines end with `\n`; the last may lack
 * the terminator) against `sheet`.
 *
 * Throws: as $(LREF executeCommand); the exception message is prefixed with
 * the 1-based line number.
 */
void runScript(Sheet sheet, string script, scope OutputSink output) @safe
{
    size_t start = 0, lineNo = 0;
    while (start < script.length)
    {
        size_t end = start;
        while (end < script.length && script[end] != '\n')
            end++;
        lineNo++;
        try
            executeCommand(sheet, script[start .. end], output);
        catch (CommandException e)
            throw new CommandException(lineMessage(lineNo, e.msg));
        catch (ParseException e)
            throw new ParseException(lineMessage(lineNo, e.msg));
        start = end + 1;
    }
}

private string lineMessage(size_t lineNo, string msg) pure @safe
{
    import std.conv : to;
    return "line " ~ lineNo.to!string ~ ": " ~ msg;
}

version (unittest)
{
    private string run(string script) @safe
    {
        import std.array : appender;
        auto buf = appender!string;
        runScript(new Sheet, script, (const(char)[] s) { buf ~= s; });
        return buf[];
    }
}

/// Worked example: a dependency, a cycle created and broken.
@safe unittest
{
    assert(run("set A1 10\nset A2 32\nset A3 =A1+A2\nget A3\nset A1 =A3\nget A1\nget A3\n"
        ~ "set A1 5\nget A3\ndump\n")
        == "42\n#CYCLE!\n#CYCLE!\n37\nA1 5\nA2 32\nA3 37\n");
}

/// Worked example: strings, ranges, IF, error propagation.
@safe unittest
{
    assert(run(`set A1 "Total"
set B1 3
set B2 4.5
set B3 "x"
set C1 =SUM(B1:B3)
set C2 =A1&": "&C1
set C3 =IF(C1>7, "big", "small")
set C4 =AVG(B1:B3)
set C5 =COUNT(B1:B3)
set C6 =B1/(B2-4.5)
set C7 =C6+1
set C8 =1/3
dump`) == "A1 Total\nB1 3\nC1 7.5\nB2 4.5\nC2 Total: 7.5\nB3 x\nC3 big\nC4 3.75\nC5 2\n"
        ~ "C6 #DIV/0!\nC7 #DIV/0!\nC8 0.3333333333\n");
}

/// Worked example: precedence, number formatting, clearing.
@safe unittest
{
    assert(run(`set A1 =1+2*3
set A2 =(1+2)*3
set A3 =-2*3-4
set A4 =2*-3
set A5 =1<2+3
set A6 =1+2&3
set A7 =100000000000000000000
set A8 =0.00001
set A9 =1234567.891
set A10 =2/3*3
set B1 =A9
clear A9
get B1
dump
`) == "0\nA1 7\nB1 0\nA2 9\nA3 -10\nA4 -6\nA5 1\nA6 33\nA7 1e+20\nA8 1e-05\nA10 2\n");
}

@safe unittest
{
    import std.exception : assertThrown;
    assertThrown!CommandException(run("frob A1"));
    assertThrown!CommandException(run("get a1"));
    assertThrown!CommandException(run("set A1"));
    assertThrown!ParseException(run("set A1 nonsense"));
}

/// Semantics of empty cells, strings and comparisons.
@safe unittest
{
    assert(run("set B1 =(Z1)&\"x\"\nset B2 =IF(1,Z1,7)&\"x\"\nset B3 =(Z1)=\"\"\n"
        ~ "set B4 =COUNT((Z1))\nset B5 =-Z1&\"x\"\nset B6 =\"5\"+1\nset B7 =\"a\"<\"b\"\n"
        ~ "set B8 =1=\"1\"\nset B9 =1<\"1\"\nset B10 =Z1=Z2\nset B11 =\"😀\"<\"ｚ\"\n"
        ~ "get B1\nget B2\nget B3\nget B4\nget B5\nget B6\nget B7\nget B8\nget B9\nget B10\nget B11\nget Q9\n")
        == "x\nx\n1\n0\n0x\n#VALUE!\n1\n0\n#VALUE!\n1\n0\n\n");
}

/// Errors: first problem in evaluation order wins.
@safe unittest
{
    assert(run("set A1 =1/0\nset B1 =\"x\"+A1\nset B2 =A1+\"x\"\nset A9 1" ~ "0000000000000000000000000000000000000000000000000\n"
        ~ "set B3 =A9*A9*A9*A9*A9*A9*A9\n"
        ~ "set B4 =AAA1+A1\nset B5 =SUM(A1:A1,\"x\")\nset B6 =AVG(Z1:Z2)\nset B7 =MIN(Z1:Z2)\n"
        ~ "get B1\nget B2\nget B3\nget B4\nget B5\nget B6\nget B7\n")
        == "#VALUE!\n#DIV/0!\n#VALUE!\n#REF!\n#DIV/0!\n#DIV/0!\n0\n");
}
