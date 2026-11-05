/// Shared helpers for the unit tests.
module helpers;

import std.array : join;
import jq;

/// Run `filter` on the JSON text `doc`; returns the outputs joined with newlines,
/// with a final `error` line if evaluation raised an error.
string run(string filter, string doc)
{
    string[] outs;
    auto prog = new Program(filter);
    JqError err;
    immutable ok = prog.run(parseJson(doc), (Value v) { outs ~= toJson(v); return true; }, err);
    if (!ok)
        outs ~= "error";
    return outs.join("\n");
}
