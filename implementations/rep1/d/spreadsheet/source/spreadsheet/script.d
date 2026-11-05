/// The line-oriented command language (`set`, `get`, `clear`, `dump`).
module spreadsheet.script;

import spreadsheet.sheet;

/// Thrown for a line that is not a valid command.
class CommandError : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}

/**
 * Execute one command line against `sheet`.
 *
 * `get` appends the cell's displayed value and a newline to `sink`; `dump`
 * appends one line per non-empty cell; `set` and `clear` print nothing.
 * Throws `CommandError`, `SyntaxError` or `InvalidCellName` on bad input.
 */
void executeCommand(Sink)(Sheet sheet, string line, ref Sink sink)
{
    if (line == "dump")
    {
        sheet.dump(sink);
        return;
    }
    size_t sp = 0;
    while (sp < line.length && line[sp] != ' ')
        sp++;
    if (sp == line.length)
        throw new CommandError("malformed command: " ~ line);
    string word = line[0 .. sp];
    string rest = line[sp + 1 .. $];
    switch (word)
    {
    case "set":
        size_t sp2 = 0;
        while (sp2 < rest.length && rest[sp2] != ' ')
            sp2++;
        if (sp2 == rest.length)
            throw new CommandError("set needs a cell and content: " ~ line);
        sheet.set(rest[0 .. sp2], rest[sp2 + 1 .. $]);
        break;
    case "get":
        sheet.get(rest).display(sink);
        sink.put('\n');
        break;
    case "clear":
        sheet.clear(rest);
        break;
    default:
        throw new CommandError("unknown command: " ~ word);
    }
}

/// Execute every line of `input` (separated by `\n`; the last may be unterminated).
void executeScript(Sink)(Sheet sheet, string input, ref Sink sink)
{
    size_t pos = 0;
    while (pos < input.length)
    {
        size_t end = pos;
        while (end < input.length && input[end] != '\n')
            end++;
        if (end > pos)
            executeCommand(sheet, input[pos .. end], sink);
        pos = end + 1;
    }
}
