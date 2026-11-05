/// Shared helpers for the unit tests.
module regex.helpers;

import std.conv : to;
import std.format : format;

import regex.api;

/// Renders a search the way the CLI does: `no` or `match s e|gs,ge|-...`.
string render(string pattern, string subject)
{
    auto re = new Regex(pattern);
    auto m = re.search(subject);
    if (!m.matched)
        return "no";
    string r = format("match %s %s", m.start, m.end);
    foreach (g; 1 .. m.groupCount + 1)
        r ~= m.isSet(g) ? format("|%s,%s", m.groupStart(g), m.groupEnd(g)) : "|-";
    return r;
}
