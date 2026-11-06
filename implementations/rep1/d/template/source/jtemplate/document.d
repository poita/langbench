/// The command-line input format: a JSON context, a `--` line, and named
/// templates introduced by `=== name` header lines.
module jtemplate.document;

import jtemplate.engine;
import jtemplate.errors;
import jtemplate.json;
import jtemplate.value;

/// A parsed input document.
struct Document
{
    /// The JSON context (always a dictionary value).
    Value context;
    /// Template names in input order; the first one is the main template.
    string[] names;
    /// Template sources by name.
    string[string] sources;
}

/// Split `input` into its JSON context and templates.
///
/// The JSON is everything before the first line that is exactly `--`. A
/// template's body runs from after its header line to the LF before the next
/// header (for the last one: to the end, minus one trailing LF).
/// Throws a syntax [TemplateError] if the layout is wrong.
Document parseDocument(string input)
{
    Document doc;

    // Find the "--" line.
    size_t jsonEnd = size_t.max, bodyStart = 0;
    size_t lineStart = 0;
    while (lineStart <= input.length)
    {
        size_t lineEnd = lineStart;
        while (lineEnd < input.length && input[lineEnd] != '\n') ++lineEnd;
        if (lineEnd - lineStart == 2 && input[lineStart .. lineEnd] == "--")
        {
            jsonEnd = lineStart;
            bodyStart = lineEnd < input.length ? lineEnd + 1 : lineEnd;
            break;
        }
        if (lineEnd >= input.length) break;
        lineStart = lineEnd + 1;
    }
    if (jsonEnd == size_t.max)
        throw syntaxError("missing '--' separator line");

    doc.context = parseJson(input[0 .. jsonEnd]);
    if (doc.context.kind != Kind.dict)
        throw syntaxError("the context must be a JSON object");

    // Collect headers.
    struct Header { size_t lineStart, lineEnd; string name; }
    Header[] headers;
    lineStart = bodyStart;
    while (lineStart < input.length)
    {
        size_t lineEnd = lineStart;
        while (lineEnd < input.length && input[lineEnd] != '\n') ++lineEnd;
        if (lineEnd - lineStart >= 4 && input[lineStart .. lineStart + 4] == "=== ")
            headers ~= Header(lineStart, lineEnd, input[lineStart + 4 .. lineEnd]);
        lineStart = lineEnd + 1;
    }
    if (headers.length == 0)
        throw syntaxError("no templates");

    foreach (i, h; headers)
    {
        size_t begin = h.lineEnd < input.length ? h.lineEnd + 1 : input.length;
        size_t end;
        if (i + 1 < headers.length)
            end = headers[i + 1].lineStart > 0 ? headers[i + 1].lineStart - 1 : 0;
        else
        {
            end = input.length;
            if (end > begin && input[end - 1] == '\n') --end;
        }
        if (end < begin) end = begin;
        doc.names ~= h.name;
        doc.sources[h.name] = input[begin .. end];
    }
    return doc;
}

/// Render a whole input document and return exactly what the command-line
/// tool prints: the output followed by `\n`, or a single `error: <kind>` line.
string renderDocument(string input)
{
    try
    {
        auto doc = parseDocument(input);
        auto engine = new Engine;
        foreach (name, src; doc.sources)
            engine.addTemplate(name, src);
        return engine.render(doc.names[0], doc.context) ~ "\n";
    }
    catch (TemplateError e)
    {
        return "error: " ~ name(e.kind) ~ "\n";
    }
}
