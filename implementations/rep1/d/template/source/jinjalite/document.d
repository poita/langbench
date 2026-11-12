/// The combined input format used by the command-line tool: a JSON context and named templates.
module jinjalite.document;

import jinjalite.json;
import jinjalite.value;

/// Thrown when the combined input is malformed.
class DocumentException : Exception
{
    ///
    this(string message, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(message, file, line);
    }
}

/// A parsed combined input.
struct Document
{
    /// The JSON context (always a dict).
    Value context;
    /// Template names in input order; the first is the one to render.
    string[] names;
    /// Template bodies by name.
    string[string] bodies;
}

/++
    Parse text of the form

    ---
    <JSON object, possibly over several lines>
    --
    === name
    template body
    === other
    ...
    ---

    The body of a template runs up to the line feed before the next `=== ` header
    (the last one up to the end of input, minus one trailing line feed).
+/
Document parseDocument(string input)
{
    // Locate the line that is exactly "--".
    size_t sep = size_t.max, afterSep = 0;
    for (size_t pos = 0; pos <= input.length;)
    {
        size_t eol = pos;
        while (eol < input.length && input[eol] != '\n')
            ++eol;
        if (eol - pos == 2 && input[pos .. eol] == "--")
        {
            sep = pos;
            afterSep = eol < input.length ? eol + 1 : eol;
            break;
        }
        pos = eol + 1;
    }
    if (sep == size_t.max)
        throw new DocumentException("missing '--' separator line");

    Document doc;
    try
        doc.context = parseJson(input[0 .. sep]);
    catch (JsonException e)
        throw new DocumentException(e.msg);
    if (doc.context.kind != Kind.dict)
        throw new DocumentException("the JSON context must be an object");

    struct Header { string name; size_t lineStart, bodyStart; }
    Header[] headers;
    for (size_t pos = afterSep; pos < input.length;)
    {
        size_t eol = pos;
        while (eol < input.length && input[eol] != '\n')
            ++eol;
        if (eol - pos >= 4 && input[pos .. pos + 4] == "=== ")
            headers ~= Header(input[pos + 4 .. eol], pos, eol < input.length ? eol + 1 : eol);
        pos = eol + 1;
    }
    if (headers.length == 0)
        throw new DocumentException("no templates after the '--' line");

    foreach (idx, h; headers)
    {
        size_t end;
        if (idx + 1 < headers.length)
            end = headers[idx + 1].lineStart - 1;
        else
        {
            end = input.length;
            if (end > h.bodyStart && input[end - 1] == '\n')
                --end;
        }
        if (end < h.bodyStart)
            end = h.bodyStart;
        doc.names ~= h.name;
        doc.bodies[h.name] = input[h.bodyStart .. end];
    }
    return doc;
}

unittest
{
    auto doc = parseDocument("{\"a\": 1,\n \"b\": 2}\n--\n=== main\nHello {{ a }}!\n=== other\nx\n\n=== last\ny\n");
    assert(doc.names == ["main", "other", "last"]);
    assert(doc.bodies["main"] == "Hello {{ a }}!");
    assert(doc.bodies["other"] == "x\n");
    assert(doc.bodies["last"] == "y");
    assert(doc.context.asDict.keys == ["a", "b"]);
}

unittest
{
    import std.exception : assertThrown;
    auto doc = parseDocument("{}\n--\n=== a\n=== b\nz");
    assert(doc.bodies["a"] == "" && doc.bodies["b"] == "z");
    doc = parseDocument("{}\n--\n=== a\nno trailing newline");
    assert(doc.bodies["a"] == "no trailing newline");
    assertThrown!DocumentException(parseDocument("{}\n=== a\nx"));
    assertThrown!DocumentException(parseDocument("[]\n--\n=== a\nx"));
    assertThrown!DocumentException(parseDocument("{}\n--\n"));
}
