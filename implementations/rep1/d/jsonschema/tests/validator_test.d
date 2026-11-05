module validator_test;

import std.exception : assertThrown;

import jsonschema;

private bool check(string schema, string instance)
{
    auto v = new Validator;
    v.setSchema(parseJson(schema));
    return v.isValid(parseJson(instance));
}

unittest // boolean schemas and the empty schema
{
    assert(check("true", "1"));
    assert(!check("false", "1"));
    assert(check("{}", `{"a":[1]}`));
}

unittest // type
{
    assert(check(`{"type":"integer"}`, "1.0"));
    assert(!check(`{"type":"integer"}`, "1.5"));
    assert(check(`{"type":"number"}`, "1"));
    assert(!check(`{"type":"number"}`, "true"));
    assert(check(`{"type":["string","null"]}`, "null"));
    assert(!check(`{"type":["string","null"]}`, "0"));
}

unittest // enum / const use JSON equality
{
    assert(check(`{"enum":[1,"1",null,[1],{"a":1}]}`, "1.0"));
    assert(check(`{"enum":[1,"1",null,[1],{"a":1}]}`, `{"a":1.000}`));
    assert(!check(`{"enum":[1,"1",null,[1],{"a":1}]}`, "true"));
    assert(!check(`{"enum":[0]}`, "false"));
    assert(check(`{"const":{"a":[1,2]}}`, `{"a":[1,2.0]}`));
}

unittest // numeric keywords are exact
{
    assert(check(`{"multipleOf":0.0001}`, "0.3"));
    assert(!check(`{"multipleOf":2}`, "7"));
    assert(check(`{"maximum":1e308}`, "1e308"));
    assert(!check(`{"maximum":1e308}`, "1e309"));
    assert(!check(`{"exclusiveMinimum":1}`, "1.0"));
    assert(check(`{"minimum":1}`, "1.0"));
    assert(check(`{"minimum":1}`, `"x"`));
}

unittest // strings count code points
{
    assert(check(`{"maxLength":1}`, `"💩"`));
    assert(!check(`{"minLength":2}`, `"💩"`));
    assert(check(`{"minLength":2.0}`, "\"e\u0301\""));
    assert(!check(`{"minLength":2}`, "\"\u00e9\""));
    assert(check(`{"pattern":"bar"}`, `"foobarbaz"`));
    assert(!check(`{"pattern":"^bar"}`, `"foobarbaz"`));
    assert(check(`{"format":"ipv4"}`, `"nope"`));
}

unittest // arrays
{
    assert(!check(`{"uniqueItems":true}`, `[1,1.0]`));
    assert(check(`{"uniqueItems":true}`, `[1,true,"1"]`));
    assert(!check(`{"uniqueItems":true}`, `[1,2,3,4,5,6,7,8,9,10,{"a":[1]},{"a":[1.0]}]`));
    assert(check(`{"uniqueItems":true}`, `[1,2,3,4,5,6,7,8,9,10,{"a":[1]},{"a":[2]}]`));
    assert(check(`{"prefixItems":[{"type":"integer"}],"items":{"type":"string"}}`, `[1,"a"]`));
    assert(!check(`{"prefixItems":[{"type":"integer"}],"items":{"type":"string"}}`, `[1,2]`));
    assert(!check(`{"maxItems":1}`, "[1,2]"));
}

unittest // contains with counts (SPEC 7.2)
{
    enum s = `{"type":"array","contains":{"type":"integer"},"minContains":2,"maxContains":3}`;
    assert(check(s, `[1,"a",2]`));
    assert(check(s, `["a",1,2,3,"b"]`));
    assert(!check(s, `[1,"a"]`));
    assert(!check(s, `[1,2,3,4]`));
    assert(check(`{"contains":{"type":"integer"},"minContains":0}`, `["a"]`));
    assert(!check(`{"contains":{"type":"integer"}}`, `["a"]`));
    assert(check(`{"minContains":5}`, `[1]`)); // inert without contains
}

unittest // objects
{
    assert(!check(`{"required":["a"]}`, `{}`));
    assert(check(`{"required":["a"]}`, `[]`));
    assert(!check(`{"dependentRequired":{"a":["b"]}}`, `{"a":1}`));
    assert(check(`{"dependentRequired":{"a":["b"]}}`, `{"c":1}`));
    assert(!check(`{"properties":{"a":{"type":"string"}}}`, `{"a":1}`));
    assert(!check(`{"patternProperties":{"^x":{"type":"string"}}}`, `{"xa":1}`));
    assert(!check(`{"properties":{"a":true},"additionalProperties":false}`, `{"a":1,"b":2}`));
    assert(check(`{"patternProperties":{"^b":true},"additionalProperties":false}`, `{"bc":1}`));
    assert(!check(`{"propertyNames":{"maxLength":2}}`, `{"abc":1}`));
    assert(!check(`{"dependentSchemas":{"a":{"required":["b"]}}}`, `{"a":1}`));
    assert(!check(`{"maxProperties":1}`, `{"a":1,"b":2}`));
}

unittest // in-place applicators
{
    assert(!check(`{"allOf":[true,false]}`, "1"));
    assert(check(`{"anyOf":[false,true]}`, "1"));
    assert(!check(`{"oneOf":[true,true]}`, "1"));
    assert(check(`{"oneOf":[true,false]}`, "1"));
    assert(check(`{"not":false}`, "1"));
    assert(!check(`{"if":{"type":"string"},"then":{"minLength":3}}`, `"ab"`));
    assert(check(`{"if":{"type":"string"},"then":{"minLength":3}}`, `5`));
    assert(!check(`{"if":{"type":"string"},"else":{"type":"null"}}`, `5`));
    assert(check(`{"then":false,"else":false}`, `5`)); // inert without if
}

unittest // unevaluatedProperties (SPEC 7.1)
{
    enum s = `{"allOf":[{"properties":{"a":{"type":"integer"}}},{"properties":{"b":{"type":"integer"}}}],
        "if":{"required":["a"]},"then":{"properties":{"c":{"type":"string"}}},
        "unevaluatedProperties":false}`;
    assert(check(s, `{"a":1,"b":2}`));
    assert(check(s, `{"a":1,"c":"yes"}`));
    assert(!check(s, `{"b":2,"c":"yes"}`));
    assert(!check(s, `{"a":1,"d":0}`));
}

unittest // unevaluatedItems sees prefixItems and contains
{
    assert(check(`{"prefixItems":[true],"unevaluatedItems":false}`, "[1]"));
    assert(!check(`{"prefixItems":[true],"unevaluatedItems":false}`, "[1,2]"));
    assert(check(`{"contains":{"type":"integer"},"unevaluatedItems":false}`, "[1,2]"));
    assert(!check(`{"contains":{"type":"integer"},"unevaluatedItems":false}`, `[1,"a"]`));
    // annotations from a rejected anyOf branch do not leak
    assert(!check(`{"anyOf":[{"prefixItems":[true,false]}],"unevaluatedItems":false}`, "[1,2]"));
}

unittest // $ref, $anchor, $defs and base URI changes
{
    assert(!check(`{"$defs":{"p":{"type":"integer"}},"properties":{"a":{"$ref":"#/$defs/p"}}}`, `{"a":"x"}`));
    assert(!check(`{"$defs":{"p":{"$anchor":"foo","type":"integer"}},"$ref":"#foo"}`, `"x"`));
    assert(check(`{"$ref":"#/$defs/a~1b","$defs":{"a/b":true}}`, "1"));
    assert(!check(`{"$ref":"#/$defs/a%25b","$defs":{"a%b":false}}`, "1"));
    // siblings of $ref are evaluated too
    assert(!check(`{"$ref":"#/$defs/t","maximum":3,"$defs":{"t":true}}`, "5"));
    // recursion
    assert(!check(`{"properties":{"n":{"$ref":"#"}},"type":"object"}`, `{"n":{"n":1}}`));
}

unittest // remotes and relative references (SPEC 7.4)
{
    auto v = new Validator;
    v.setSchema(parseJson(`{"$id":"http://localhost:1234/draft2020-12/root-of-its-own.json",
        "type":"object","properties":{"i":{"$ref":"integer.json"},"n":{"$ref":"subSchemas.json#/$defs/integer"}}}`));
    v.addRemote("http://localhost:1234/draft2020-12/integer.json", parseJson(`{"type":"integer"}`));
    v.addRemote("http://localhost:1234/draft2020-12/subSchemas.json",
            parseJson(`{"$defs":{"integer":{"type":"integer"}}}`));
    assert(v.isValid(parseJson(`{"i":1,"n":2}`)));
    assert(!v.isValid(parseJson(`{"i":"1"}`)));
}

unittest // $dynamicRef picks the outermost dynamic anchor (SPEC 6.5)
{
    enum s = `{
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
      "$ref": "https://example.test/list"
    }`;
    assert(check(s, `["a","b"]`));
    assert(!check(s, `["a",1]`));
    // Referenced directly, the generic list has no outer override.
    assert(check(`{"$id":"https://example.test/list","$defs":{"itemType":{"$dynamicAnchor":"itemType"}},
        "type":"array","items":{"$dynamicRef":"#itemType"}}`, `["a",1]`));
}

unittest // $id is only recognised in schema positions
{
    assert(check(`{"$ref":"#/$defs/a","$defs":{"a":{"const":{"$id":"http://x/","type":"integer"}}}}`,
            `{"$id":"http://x/","type":"integer"}`));
}

unittest // unknown keywords and definitions are ignored
{
    assert(check(`{"definitions":{"x":false},"dependencies":{"a":false},"bogus":1}`, `{"a":1}`));
}

unittest // invalid regular expressions are reported at compile time
{
    auto v = new Validator;
    assertThrown!SchemaException(v.setSchema(parseJson(`{"pattern":"(a"}`)));
}

unittest // the request format of the command-line tool
{
    enum req = `{"schema":{"type":"integer","minimum":1},
        "tests":[{"description":"ok","data":3},{"description":"zero","data":0},{"description":"str","data":"3"}]}`;
    assert(processRequest(req) == "valid\ninvalid\ninvalid\n");
    assert(processRequest(`{"schema":true,"tests":[]}`) == "");
    assertThrown!RequestException(processRequest(`{"tests":[]}`));
    assertThrown!JsonException(processRequest(`{`));
}
