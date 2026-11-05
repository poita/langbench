/**
 * Parsing of `queries.txt`: queries, comments, blank lines and `%k`
 * directives.
 */
module fulltext.queryfile;

import fulltext.whitespace : stripSpace;

/// One query from a query file.
struct QueryEntry
{
    /// 1-based number among the queries (directives and comments excluded).
    uint number;
    /// The stripped query text.
    string text;
    /// Result limit in force for this query.
    size_t k;
}

/// The default result limit.
enum size_t defaultK = 10;

/**
 * If `line` (already stripped) is a `%k <digits>` directive, stores the
 * value in `k` and returns true.
 */
bool parseKDirective(string line, out size_t k) pure nothrow @safe
{
    if (line.length < 3 || line[0] != '%' || line[1] != 'k')
        return false;
    size_t i = 2;
    immutable ws = i;
    while (i < line.length && (line[i] == ' ' || line[i] == '\t'))
        ++i;
    if (i == ws)
        return false;
    immutable ds = i;
    size_t v = 0;
    while (i < line.length && line[i] >= '0' && line[i] <= '9')
    {
        if (v < size_t.max / 20)
            v = v * 10 + (line[i] - '0');
        ++i;
    }
    if (i == ds)
        return false;
    while (i < line.length && (line[i] == ' ' || line[i] == '\t'))
        ++i;
    if (i != line.length)
        return false;
    k = v;
    return true;
}

/// Parses the contents of a query file.
QueryEntry[] parseQueryFile(string content) pure @safe
{
    QueryEntry[] entries;
    size_t k = defaultK;
    uint number = 0;
    size_t start = 0;
    while (start <= content.length)
    {
        size_t end = start;
        while (end < content.length && content[end] != '\n')
            ++end;
        auto line = stripSpace(content[start .. end]);
        start = end + 1;
        if (line.length == 0 || line[0] == '#')
            continue;
        size_t newK;
        if (parseKDirective(line, newK))
        {
            k = newK;
            continue;
        }
        entries ~= QueryEntry(++number, line, k);
    }
    return entries;
}
