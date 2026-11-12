/**
 * A jq-subset query language implemented from scratch: JSON parser,
 * serializer, filter parser and interpreter.
 *
 * Example:
 * ---
 * import jq;
 *
 * auto filter = Filter.compile(".users | map(select(.age >= 30) | .name)");
 * auto doc = parseJson(`{"users":[{"name":"ann","age":31},{"name":"bo","age":20}]}`);
 * foreach (result; filter.collect(doc))
 *     writeln(toJson(result)); // ["ann"]
 * ---
 */
module jq;

public import jq.errors;
public import jq.interp : Filter, Sink, query;
public import jq.json : parseJson, toJson, writeJson, writeJsonString, formatNumber;
public import jq.value;

version (unittest)
{
    private string[] runAll(string filter, string doc, out bool errored)
    {
        string[] lines;
        errored = false;
        try
            Filter.compile(filter).run(parseJson(doc), (Value v) { lines ~= toJson(v); });
        catch (JqError)
            errored = true;
        return lines;
    }
}

// End-to-end examples from the specification.
unittest
{
    bool err;
    auto r = runAll(`.users | map(select(.age >= 30 and .active)) | sort_by(.age) | reverse | map({name, age})`,
            `{"users":[{"name":"ann","age":31,"active":true},{"name":"bob","age":45,"active":false},`
            ~ `{"name":"cy","age":30,"active":true},{"name":"di","age":52,"active":true},`
            ~ `{"name":"ed","age":29,"active":true},{"name":"flo","age":31,"active":true}]}`, err);
    assert(!err && r == [`[{"name":"di","age":52},{"name":"flo","age":31},{"name":"ann","age":31},{"name":"cy","age":30}]`]);

    r = runAll(`[(1,2) + (10,20)], {a:(1,2), b:(3,4)}, [.[] | .a?], (.[] | .a.b?)`,
            `[{"a":{"b":1}},{"a":5},3]`, err);
    assert(err);
    assert(r == [`[11,12,21,22]`, `{"a":1,"b":3}`, `{"a":1,"b":4}`, `{"a":2,"b":3}`,
            `{"a":2,"b":4}`, `[{"b":1},5]`, `1`]);

    r = runAll(`reduce .[] as $o ({}; . + {($o.k): $o.v}), (map(.v) | add), sort_by(.k, -.v), `
            ~ `(group_by(.k) | map([.[0].k, length])), (.[0] | keys), (.[2].v / 4)`,
            `[{"k":"b","v":1},{"k":"a","v":2},{"k":"b","v":3}]`, err);
    assert(!err);
    assert(r == [`{"b":3,"a":2}`, `6`, `[{"k":"a","v":2},{"k":"b","v":3},{"k":"b","v":1}]`,
            `[["a",1],["b",2]]`, `["k","v"]`, `0.75`]);
}

unittest
{
    assert(toJson(query(`[.[] | . * 2]`, `[1,2.5]`)[0]) == `[2,5]`);
}
