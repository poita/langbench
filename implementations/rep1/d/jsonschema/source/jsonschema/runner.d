/**
 * High-level entry points: `SchemaValidator` bundles a registry and an
 * evaluator behind a two-call API, and `validateDocument` implements the
 * command-line tool's input format.
 */
module jsonschema.runner;

import jsonschema.json;
import jsonschema.schema;
import jsonschema.validator;

/// Compiles a schema and answers whether instances satisfy it.
final class SchemaValidator
{
    private Registry registry;
    private Validator validator;
    private Schema root;

    /**
     * Compiles `schema`. `remotes` maps absolute URIs to schema documents that
     * `$ref`/`$dynamicRef` may refer to (nothing is ever fetched).
     */
    this(JsonValue schema, JsonValue[string] remotes = null)
    {
        registry = new Registry;
        root = registry.add(schema, "");
        foreach (uri; sortedKeys(remotes))
            registry.add(remotes[uri], uri);
        validator = new Validator(registry, root);
    }

    /// True when `instance` is valid against the schema.
    bool isValid(JsonValue instance)
    {
        return validator.isValid(instance);
    }

    private static string[] sortedKeys(JsonValue[string] m)
    {
        import std.algorithm.sorting : sort;
        import std.array : array;

        return m.keys.sort().release();
    }
}

/**
 * Implements the CLI contract: `input` is a JSON object with `schema`, `tests`
 * and optionally `remotes`; the result has one `valid`/`invalid` per test.
 *
 * Throws `JsonException` for malformed JSON and `Exception` when the document
 * lacks `schema` or `tests`.
 */
string[] validateDocument(const(char)[] input)
{
    auto doc = parseJson(input);
    if (!doc.isObject)
        throw new Exception("input must be a JSON object");
    auto schema = doc.get("schema");
    auto tests = doc.get("tests");
    if (schema is null || tests is null || !tests.isArray)
        throw new Exception("input needs a \"schema\" and a \"tests\" array");
    JsonValue[string] remotes;
    if (auto r = doc.get("remotes"))
        if (r.isObject)
            foreach (i, k; r.keys)
                remotes[k] = r.values[i];
    auto validator = new SchemaValidator(schema, remotes);
    string[] result;
    foreach (t; tests.items)
    {
        auto data = t.get("data");
        if (data is null)
            data = JsonValue.makeNull();
        bool ok;
        try
            ok = validator.isValid(data);
        catch (SchemaException)
            ok = false;
        result ~= ok ? "valid" : "invalid";
    }
    return result;
}

unittest
{
    auto out_ = validateDocument(`{"schema":{"type":"integer","minimum":1},
        "tests":[{"description":"a","data":3},{"description":"b","data":0},{"description":"c","data":"3"}]}`);
    assert(out_ == ["valid", "invalid", "invalid"]);
}

unittest
{
    // section 7.1: annotations and unevaluatedProperties
    auto out_ = validateDocument(`{"schema": {"allOf": [{"properties": {"a": {"type": "integer"}}},
                      {"properties": {"b": {"type": "integer"}}}],
            "if": {"required": ["a"]},
            "then": {"properties": {"c": {"type": "string"}}},
            "unevaluatedProperties": false},
 "tests": [{"data": {"a": 1, "b": 2}},
           {"data": {"a": 1, "c": "yes"}},
           {"data": {"b": 2, "c": "yes"}},
           {"data": {"a": 1, "d": 0}}]}`);
    assert(out_ == ["valid", "valid", "invalid", "invalid"]);
}

unittest
{
    // section 7.4: base URI changes and remotes
    auto out_ = validateDocument(`{"schema": {"$id": "http://localhost:1234/draft2020-12/root-of-its-own.json",
            "type": "object",
            "properties": {"i": {"$ref": "integer.json"},
                           "n": {"$ref": "subSchemas.json#/$defs/integer"}}},
 "remotes": {"http://localhost:1234/draft2020-12/integer.json": {"type": "integer"},
             "http://localhost:1234/draft2020-12/subSchemas.json":
                 {"$defs": {"integer": {"type": "integer"}}}},
 "tests": [{"data": {"i": 1, "n": 2}}, {"data": {"i": "1"}}]}`);
    assert(out_ == ["valid", "invalid"]);
}

unittest
{
    // section 6.5: dynamic references resolve to the outermost dynamic anchor
    auto v = new SchemaValidator(parseJson(`{
      "$id": "https://example.test/strings",
      "$defs": {
        "itemType": {"$dynamicAnchor": "itemType", "type": "string"},
        "list": {
          "$id": "https://example.test/list",
          "$defs": {"itemType": {"$dynamicAnchor": "itemType"}},
          "type": "array",
          "items": {"$dynamicRef": "#itemType"}
        }
      },
      "$ref": "https://example.test/list"}`));
    assert(v.isValid(parseJson(`["a","b"]`)));
    assert(!v.isValid(parseJson(`["a",1]`)));
}

unittest
{
    // section 7.2 / 7.3
    auto v = new SchemaValidator(parseJson(
            `{"type":"array","contains":{"type":"integer"},"minContains":2,"maxContains":3}`));
    assert(v.isValid(parseJson(`[1,"a",2]`)));
    assert(v.isValid(parseJson(`["a",1,2,3,"b"]`)));
    assert(!v.isValid(parseJson(`[1,"a"]`)));
    assert(!v.isValid(parseJson(`[1,2,3,4]`)));
    auto e = new SchemaValidator(parseJson(`{"enum":[1,"1",null,[1],{"a":1}]}`));
    assert(e.isValid(parseJson("1.0")) && e.isValid(parseJson(`{"a":1.000}`)));
    assert(!e.isValid(parseJson("true")) && !e.isValid(parseJson("[2]")));
}

unittest
{
    auto v = new SchemaValidator(parseJson(`{"multipleOf":0.0001}`));
    assert(v.isValid(parseJson("0.3")) && v.isValid(parseJson("0.0021")));
    auto s = new SchemaValidator(parseJson(`{"maxLength":2}`));
    assert(s.isValid(parseJson(`"💩💩"`)) && !s.isValid(parseJson(`"e\u0301x"`)));
}
