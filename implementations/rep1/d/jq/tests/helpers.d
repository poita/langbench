/// Shared helpers for the unit tests.
module tests.helpers;

import jq;

/// Run `filter` on the JSON text `doc`; returns outputs as compact JSON,
/// with a trailing "error" element if evaluation failed.
string[] runFilter(string filter, string doc)
{
    auto program = Program.compile(filter);
    RunStatus status;
    auto outs = program.runAll(parseJson(doc), status);
    string[] r;
    foreach (v; outs)
        r ~= toJson(v);
    if (!status.ok)
        r ~= "error";
    return r;
}
