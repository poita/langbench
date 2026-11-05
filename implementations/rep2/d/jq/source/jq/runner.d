/**
 * The command-line contract as a library function: the first line of the
 * input is a filter, the rest is one JSON document; every output is written
 * as a line of compact JSON, followed by `error` if evaluation fails.
 */
module jq.runner;

import jq.interp;
import jq.json;
import jq.lexer : ParseException;
import jq.value;

/// Flush threshold of the output buffer.
private enum flushAt = 1 << 16;

/**
 * Evaluate the filter on the first line of `input` against the document in the
 * rest of it. Calls `write` with chunks of output text.
 * Returns `false` if the filter or document could not be parsed, or evaluation
 * raised an error (in which case `error\n` has been written after the results).
 */
bool runSpecInput(string input, scope void delegate(const(char)[]) write, out string problem)
{
    size_t nl = 0;
    while (nl < input.length && input[nl] != '\n')
        ++nl;
    auto filterText = input[0 .. nl];
    auto docText = nl < input.length ? input[nl + 1 .. $] : "";
    TextBuffer buf;
    Program prog;
    Value doc;
    try
    {
        prog = new Program(filterText);
        doc = parseJson(docText);
    }
    catch (ParseException e)
    {
        problem = "filter: " ~ e.msg;
        write("error\n");
        return false;
    }
    catch (JsonException e)
    {
        problem = "document: " ~ e.msg;
        write("error\n");
        return false;
    }
    JqError err;
    immutable ok = prog.run(doc, (Value v) {
        writeJson(buf, v);
        buf.put('\n');
        if (buf.length >= flushAt)
        {
            write(buf[]);
            buf.clear();
        }
        return true;
    }, err);
    if (!ok)
    {
        buf.put("error\n");
        problem = err.message;
    }
    write(buf[]);
    return ok;
}
