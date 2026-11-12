//! End-to-end checks of the worked examples and the keyword semantics that
//! implementations most often get wrong.

use jsonschema::{json, Json, Schema};

fn parse(s: &str) -> Json {
    json::parse(s).unwrap_or_else(|e| panic!("bad JSON {s}: {e}"))
}

/// Compiles `schema` (with optional `(uri, document)` remotes) and checks
/// each `(instance, expected)` pair.
fn check(schema: &str, remotes: &[(&str, &str)], cases: &[(&str, bool)]) {
    let schema_doc = parse(schema);
    let docs: Vec<Json> = remotes.iter().map(|(_, d)| parse(d)).collect();
    let mut builder = Schema::builder();
    for ((uri, _), doc) in remotes.iter().zip(&docs) {
        builder = builder.remote(uri, doc);
    }
    let compiled = builder.build(&schema_doc).expect("schema compiles");
    for (instance, expected) in cases {
        assert_eq!(
            compiled.is_valid(&parse(instance)),
            *expected,
            "schema {schema} instance {instance}"
        );
    }
}

#[test]
fn boolean_schemas() {
    check("true", &[], &[("1", true), ("null", true)]);
    check("false", &[], &[("1", false), ("{}", false)]);
}

#[test]
fn integer_vs_number() {
    check(
        r##"{"type":"integer"}"##,
        &[],
        &[("1", true), ("1.0", true), ("1e2", true), ("1.5", false), ("true", false), ("\"1\"", false)],
    );
    check(r##"{"type":"number"}"##, &[], &[("1.5", true), ("true", false)]);
    check(r##"{"type":["string","null"]}"##, &[], &[("null", true), ("\"a\"", true), ("0", false)]);
}

#[test]
fn equality_is_type_aware() {
    check(
        r##"{"enum":[1,"1",null,[1],{"a":1}]}"##,
        &[],
        &[
            ("1", true),
            ("1.0", true),
            (r##"{"a":1.000}"##, true),
            ("true", false),
            ("false", false),
            ("[2]", false),
        ],
    );
    check(r##"{"const":{"a":1,"b":2}}"##, &[], &[(r##"{"b":2,"a":1}"##, true), (r##"{"a":1}"##, false)]);
}

#[test]
fn multiple_of_is_exact() {
    check(r##"{"multipleOf":0.0001}"##, &[], &[("0.3", true), ("0.0021", true), ("0.00005", false)]);
    check(r##"{"multipleOf":0.5}"##, &[], &[("1e308", true), ("1.25", false), ("0", true)]);
}

#[test]
fn bounds_are_exact() {
    check(r##"{"maximum":1e308}"##, &[], &[("1e308", true), ("1e309", false)]);
    check(
        r##"{"exclusiveMinimum":0.1}"##,
        &[],
        &[("0.1", false), ("0.1000000000000000000000001", true)],
    );
}

#[test]
fn string_length_counts_code_points() {
    check(r##"{"maxLength":1}"##, &[], &[(r##""💩""##, true), (r##""e\u0301""##, false)]);
    check(r##"{"minLength":2.0}"##, &[], &[(r##""ab""##, true), (r##""a""##, false)]);
}

#[test]
fn pattern_is_a_search() {
    check(r##"{"pattern":"bar"}"##, &[], &[(r##""foobarbaz""##, true), (r##""foo""##, false)]);
    check(r##"{"pattern":"^a$"}"##, &[], &[(r##""a""##, true), (r##""a\n""##, false)]);
    check(r##"{"pattern":"\\bcat\\b"}"##, &[], &[(r##""écat ""##, true)]);
}

#[test]
fn unique_items() {
    check(
        r##"{"uniqueItems":true}"##,
        &[],
        &[
            (r##"[{"a":1,"b":2},{"b":2,"a":1}]"##, false),
            ("[1,true]", true),
            ("[1,1.0]", false),
            ("[[1],[1]]", false),
        ],
    );
    let big: Vec<String> = (0..100).map(|i| i.to_string()).collect();
    let unique = format!("[{}]", big.join(","));
    let dup = format!("[{},50.0]", big.join(","));
    check(r##"{"uniqueItems":true}"##, &[], &[(&unique, true), (&dup, false)]);
}

#[test]
fn contains_with_counts() {
    let s = r##"{"type":"array","contains":{"type":"integer"},"minContains":2,"maxContains":3}"##;
    check(
        s,
        &[],
        &[
            (r##"[1,"a",2]"##, true),
            (r##"["a",1,2,3,"b"]"##, true),
            (r##"[1,"a"]"##, false),
            ("[1,2,3,4]", false),
        ],
    );
    check(r##"{"contains":{"type":"integer"},"minContains":0}"##, &[], &[(r##"["a"]"##, true), ("[]", true)]);
    // Without `contains` the counts are inert.
    check(r##"{"minContains":5}"##, &[], &[("[]", true)]);
}

#[test]
fn dependent_keywords() {
    check(
        r##"{"dependentRequired":{"a":["b"]},"dependentSchemas":{"c":{"required":["d"]}}}"##,
        &[],
        &[
            (r##"{"a":1,"b":2}"##, true),
            (r##"{"a":1}"##, false),
            (r##"{"c":1}"##, false),
            (r##"{"c":1,"d":1}"##, true),
            ("{}", true),
        ],
    );
}

#[test]
fn additional_and_pattern_properties() {
    check(
        r##"{"properties":{"a":true},"patternProperties":{"^x-":{"type":"integer"}},"additionalProperties":false}"##,
        &[],
        &[
            (r##"{"a":"s","x-1":2}"##, true),
            (r##"{"x-1":"s"}"##, false),
            (r##"{"b":1}"##, false),
        ],
    );
    check(
        r##"{"patternProperties":{"a":{"minimum":1},"b":{"maximum":3}}}"##,
        &[],
        &[(r##"{"ab":2}"##, true), (r##"{"ab":5}"##, false), (r##"{"ab":0}"##, false)],
    );
}

#[test]
fn unevaluated_properties_across_all_of() {
    let s = r##"{"allOf":[{"properties":{"a":{"type":"integer"}}},{"properties":{"b":{"type":"integer"}}}],
        "if":{"required":["a"]},"then":{"properties":{"c":{"type":"string"}}},
        "unevaluatedProperties":false}"##;
    check(
        s,
        &[],
        &[
            (r##"{"a":1,"b":2}"##, true),
            (r##"{"a":1,"c":"yes"}"##, true),
            (r##"{"b":2,"c":"yes"}"##, false),
            (r##"{"a":1,"d":0}"##, false),
        ],
    );
}

#[test]
fn unevaluated_items_after_prefix_and_contains() {
    check(
        r##"{"prefixItems":[true],"unevaluatedItems":false}"##,
        &[],
        &[("[1]", true), ("[1,2]", false)],
    );
    check(
        r##"{"contains":{"type":"string"},"unevaluatedItems":{"type":"integer"}}"##,
        &[],
        &[(r##"["a",1,"b"]"##, true), (r##"["a",1.5]"##, false)],
    );
}

#[test]
fn rejected_branches_annotate_nothing() {
    // The failing anyOf branch evaluated `a`, but must not count.
    let s = r##"{"anyOf":[{"properties":{"a":true},"required":["z"]},{"properties":{"b":true}}],
        "unevaluatedProperties":false}"##;
    check(s, &[], &[(r##"{"b":1}"##, true), (r##"{"a":1,"b":1}"##, false)]);
    // `not` never annotates.
    check(
        r##"{"not":{"not":{"properties":{"a":true}}},"unevaluatedProperties":false}"##,
        &[],
        &[(r##"{"a":1}"##, false), ("{}", true)],
    );
}

#[test]
fn one_of_and_if_then_else() {
    check(
        r##"{"oneOf":[{"type":"integer"},{"minimum":2}]}"##,
        &[],
        &[("1", true), ("3", false), ("2.5", true)],
    );
    check(
        r##"{"if":{"type":"string"},"then":{"minLength":2},"else":{"type":"integer"}}"##,
        &[],
        &[(r##""ab""##, true), (r##""a""##, false), ("1", true), ("1.5", false)],
    );
    check(r##"{"then":false,"else":false}"##, &[], &[("1", true)]);
}

#[test]
fn local_refs_and_anchors() {
    check(
        r##"{"$defs":{"pos":{"type":"integer","minimum":1},"a":{"$anchor":"foo","type":"string"}},
          "properties":{"x":{"$ref":"#/$defs/pos"},"y":{"$ref":"#foo"}}}"##,
        &[],
        &[(r##"{"x":1,"y":"s"}"##, true), (r##"{"x":0}"##, false), (r##"{"y":1}"##, false)],
    );
    // Sibling keywords of $ref are evaluated too.
    check(
        r##"{"$defs":{"i":{"type":"integer"}},"$ref":"#/$defs/i","minimum":3}"##,
        &[],
        &[("5", true), ("2", false), ("5.5", false)],
    );
    // JSON Pointer escapes and percent-decoding.
    check(
        r##"{"$defs":{"a/b":{"type":"null"},"c%d":{"type":"null"}},
          "properties":{"p":{"$ref":"#/$defs/a~1b"},"q":{"$ref":"#/$defs/c%25d"}}}"##,
        &[],
        &[(r##"{"p":null,"q":null}"##, true), (r##"{"p":1}"##, false), (r##"{"q":1}"##, false)],
    );
}

#[test]
fn base_uri_changes_and_remotes() {
    let schema = r##"{"$id":"http://localhost:1234/draft2020-12/root-of-its-own.json","type":"object",
        "properties":{"i":{"$ref":"integer.json"},"n":{"$ref":"subSchemas.json#/$defs/integer"}}}"##;
    let remotes = [
        ("http://localhost:1234/draft2020-12/integer.json", r##"{"type":"integer"}"##),
        (
            "http://localhost:1234/draft2020-12/subSchemas.json",
            r##"{"$defs":{"integer":{"type":"integer"}}}"##,
        ),
    ];
    check(schema, &remotes, &[(r##"{"i":1,"n":2}"##, true), (r##"{"i":"1"}"##, false), (r##"{"n":"x"}"##, false)]);
}

#[test]
fn nested_id_resources() {
    check(
        r##"{"$id":"http://example.test/root","$defs":{"inner":{"$id":"nested/","$defs":{"s":{"type":"string"}},
            "properties":{"v":{"$ref":"#/$defs/s"}}}},
          "$ref":"http://example.test/nested/"}"##,
        &[],
        &[(r##"{"v":"x"}"##, true), (r##"{"v":1}"##, false)],
    );
    // An $id inside data is not an identifier.
    check(r##"{"const":{"$id":"http://x/","type":"string"}}"##, &[], &[(r##"{"$id":"http://x/","type":"string"}"##, true)]);
}

#[test]
fn id_fragment_is_removed() {
    check(
        r##"{"$id":"http://example.test/a#","$defs":{"x":{"type":"integer"}},"$ref":"http://example.test/a#/$defs/x"}"##,
        &[],
        &[("1", true), ("\"s\"", false)],
    );
}

#[test]
fn dynamic_ref_extends_a_generic_list() {
    let s = r##"{
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
    }"##;
    check(s, &[], &[(r##"["a","b"]"##, true), (r##"["a",1]"##, false)]);
}

#[test]
fn dynamic_ref_without_a_dynamic_anchor_is_a_plain_ref() {
    check(
        r##"{"$defs":{"s":{"$anchor":"s","type":"string"}},"items":{"$dynamicRef":"#s"}}"##,
        &[],
        &[(r##"["a"]"##, true), ("[1]", false)],
    );
}

#[test]
fn anchor_beats_dynamic_anchor_for_plain_refs() {
    check(
        r##"{"$defs":{"a":{"$dynamicAnchor":"x","type":"string"},"b":{"$anchor":"x","type":"integer"}},"$ref":"#x"}"##,
        &[],
        &[("1", true), ("\"s\"", false)],
    );
}

#[test]
fn unknown_and_annotation_keywords_are_inert() {
    check(
        r##"{"format":"ipv4","title":"t","$comment":"c","contentEncoding":"base64","definitions":{"x":{"type":"string"}},
          "dependencies":{"a":["b"]},"madeUp":{"type":"string"},"$vocabulary":{"https://x/":false},
          "properties":{"p":{"$ref":"#/definitions/x"}}}"##,
        &[],
        &[(r##""nope""##, true), (r##"{"a":1}"##, true)],
    );
}

#[test]
fn keywords_ignore_other_instance_types() {
    check(
        r##"{"minimum":5,"maxLength":1,"required":["a"],"minItems":3,"minProperties":2,"uniqueItems":true}"##,
        &[],
        &[("\"abc\"", false), ("null", true), ("true", true), ("7", true)],
    );
}

#[test]
fn property_names() {
    check(
        r##"{"propertyNames":{"maxLength":2}}"##,
        &[],
        &[(r##"{"ab":1}"##, true), (r##"{"abc":1}"##, false), ("[]", true)],
    );
}

#[test]
fn deep_recursion_through_ref() {
    let s = r##"{"$ref":"#/$defs/n","$defs":{"n":{"type":"object","properties":{"c":{"$ref":"#/$defs/n"}}}}}"##;
    let depth = 200;
    let inst = format!("{}{}{}", r#"{"c":"#.repeat(depth), "{}", "}".repeat(depth));
    check(s, &[], &[(&inst, true)]);
}

#[test]
fn invalid_pattern_is_a_compile_error() {
    let doc = parse(r#"{"pattern":"("}"#);
    assert!(Schema::compile(&doc).is_err());
}
