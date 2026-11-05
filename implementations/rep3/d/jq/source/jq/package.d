/// jq-subset: a JSON parser/serializer and a filter interpreter.
///
/// ---
/// import jq;
///
/// auto prog = compile(`.users | map(.name)`);
/// auto doc  = parseJson(`{"users":[{"name":"ann"},{"name":"bob"}]}`);
/// run(prog, doc, (Value v) { writeln(toJson(v)); });  // ["ann","bob"]
/// ---
///
/// Modules: `jq.value` (data model), `jq.json` (parse/serialize),
/// `jq.parser` (filter compiler), `jq.interp` (evaluator), `jq.compare`
/// (total order), `jq.arith` and `jq.builtins` (operators and functions).
module jq;

public import jq.ast : Program;
public import jq.buffer;
public import jq.compare : compare, equals;
public import jq.errors;
public import jq.interp : run, Sink;
public import jq.json;
public import jq.parser : compile;
public import jq.value;

/// The outcome of `query`.
struct QueryResult
{
    /// Compact JSON text of each output produced.
    string[] outputs;
    /// True if evaluation stopped on an error (outputs before it are kept).
    bool failed;
}

/// Compile `filter`, parse `json`, and collect every output as JSON text.
/// Parse failures throw `ParseError`; runtime errors set `failed`.
QueryResult query(string filter, string json)
{
    auto prog = compile(filter);
    auto doc = parseJson(json);
    QueryResult r;
    try
        run(prog, doc, (Value v) { r.outputs ~= toJson(v); });
    catch (JqError)
        r.failed = true;
    return r;
}
