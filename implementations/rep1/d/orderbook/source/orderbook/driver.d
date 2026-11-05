/++
High-level entry point: run a whole textual command stream through a book.
+/
module orderbook.driver;

import orderbook.book : Book;
import orderbook.outbuf : OutBuf;
import orderbook.parser : parseCommands;
import orderbook.pricetable : PriceTable;

/++
Process a complete input (count line plus commands, see SPEC.md) and append
all events to `output`.

Two passes: the first parses and compresses prices, the second executes.
+/
void processStream(scope const(char)[] input, ref OutBuf output)
{
    auto parsed = parseCommands(input);
    auto table = PriceTable.from(parsed.prices);
    table.assignRanks(parsed.commands);
    auto book = Book(table, parsed.commands.length / 4 + 16);
    foreach (ref c; parsed.commands)
        book.execute(c, input, output);
}

/// Convenience wrapper returning the output as a string.
string processToString(scope const(char)[] input)
{
    OutBuf o;
    processStream(input, o);
    return cast(string) o.data.idup;
}
