#!/usr/bin/env python3
"""Regenerate problems/jsonschema/tests/ from the vendored corpora.

Three kinds of test are produced, in this order:

1. hand-written cases that isolate one rule each (the worked examples in
   SPEC.md);
2. one case per schema group of the official JSON Schema Test Suite
   (draft 2020-12, excluding optional/), whose published "valid" flags are the
   authoritative expected output;
3. real-world cases: the OpenAPI 3.1 document schema over published OpenAPI
   documents, the SchemaStore package.json schema over published npm
   manifests, and the 2020-12 meta-schema over published schemas.

Every expected output is produced by reference/main.py and cross-checked
against the `jsonschema` PyPI package in ../../.oracle-venv; the script aborts
on any disagreement that is not in KNOWN_ORACLE_DIVERGENCES.
"""
import copy
import json
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CORPUS = os.path.join(HERE, "corpus")
TESTS = os.path.join(HERE, "tests")
SUITE = os.path.join(CORPUS, "json-schema-test-suite")
REF = [sys.executable, os.path.join(HERE, "reference", "main.py")]
ORACLE_PY = os.path.normpath(os.path.join(HERE, "..", "..", ".oracle-venv", "bin", "python"))

METASCHEMA_FILES = {
    "https://json-schema.org/draft/2020-12/schema": "schema.json",
    "https://json-schema.org/draft/2020-12/meta/core": "core.json",
    "https://json-schema.org/draft/2020-12/meta/applicator": "applicator.json",
    "https://json-schema.org/draft/2020-12/meta/unevaluated": "unevaluated.json",
    "https://json-schema.org/draft/2020-12/meta/validation": "validation.json",
    "https://json-schema.org/draft/2020-12/meta/meta-data": "meta-data.json",
    "https://json-schema.org/draft/2020-12/meta/format-annotation": "format-annotation.json",
    "https://json-schema.org/draft/2020-12/meta/format-assertion": "format-assertion.json",
    "https://json-schema.org/draft/2020-12/meta/content": "content.json",
}

# Suite files in the order their cases are emitted: simple assertions first,
# then applicators, then referencing, then the annotation-driven keywords.
SUITE_ORDER = [
    "boolean_schema.json", "type.json", "enum.json", "const.json", "default.json",
    "multipleOf.json", "maximum.json", "minimum.json",
    "exclusiveMaximum.json", "exclusiveMinimum.json",
    "maxLength.json", "minLength.json", "pattern.json",
    "maxItems.json", "minItems.json", "uniqueItems.json",
    "prefixItems.json", "items.json",
    "contains.json", "maxContains.json", "minContains.json",
    "maxProperties.json", "minProperties.json", "required.json",
    "dependentRequired.json", "properties.json", "patternProperties.json",
    "additionalProperties.json", "propertyNames.json", "dependentSchemas.json",
    "allOf.json", "anyOf.json", "oneOf.json", "not.json", "if-then-else.json",
    "format.json", "content.json",
    "defs.json", "anchor.json", "ref.json", "refRemote.json",
    "infinite-loop-detection.json",
    "dynamicRef.json", "vocabulary.json",
    "unevaluatedItems.json", "unevaluatedProperties.json",
]

# Schema groups dropped from the vendored suite, with the reason. SPEC.md
# documents both exclusions.
SKIP_GROUPS = {
    # \p{...} property escapes are outside the required regex subset.
    ("pattern.json", 2): "Unicode property escape",
    ("patternProperties.json", 5): "Unicode property escape",
    # Needs $vocabulary to switch the validation vocabulary off; the spec here
    # says $vocabulary is ignored.
    ("vocabulary.json", 0): "$vocabulary-driven keyword disabling",
}

# Cases where the PyPI `jsonschema` package disagrees with this problem's
# specification. Each entry is (test name, 0-based index, reason).
KNOWN_ORACLE_DIVERGENCES = [
    ("multipleOf_exact_decimal", 4,
     "0.3 is 3000 x 0.0001 in exact decimal arithmetic; the oracle uses binary "
     "floating point, where the quotient is 2999.9999999999995"),
    ("multipleOf_exact_decimal", 5,
     "0.0021 is 21 x 0.0001 in exact decimal arithmetic; the oracle's binary "
     "quotient is 20.999999999999996"),
    ("regex_subset_coverage", 18,
     "ECMA-262 \\b is a boundary over [A-Za-z0-9_], so U+00E9 is a non-word "
     "character and \\bcat\\b matches in \"\u00e9cat \"; the oracle uses Python's "
     "re, whose \\w is Unicode-aware. Checked against node 23 (new RegExp)"),
    ("regex_subset_coverage", 29,
     "ECMA-262 $ matches only at the very end of the string, so ^a$ does not "
     "match \"a\\n\"; Python's re also matches just before a trailing newline. "
     "Checked against node 23 (new RegExp)"),
]


def slug(text, limit=46):
    s = re.sub(r"[^a-z0-9]+", "_", text.lower()).strip("_")
    return s[:limit].strip("_") or "case"


def read_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def load_remotes():
    """The documents the suite serves, plus the 2020-12 meta-schemas."""
    remotes = {}
    root = os.path.join(SUITE, "remotes")
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for name in sorted(filenames):
            if not name.endswith(".json"):
                continue
            path = os.path.join(dirpath, name)
            rel = os.path.relpath(path, root).replace(os.sep, "/")
            remotes["http://localhost:1234/" + rel] = read_json(path)
    for uri, filename in METASCHEMA_FILES.items():
        remotes[uri] = read_json(os.path.join(CORPUS, "metaschema", filename))
    return remotes


ALL_REMOTES = load_remotes()
METASCHEMA_REMOTES = {u: ALL_REMOTES[u] for u in METASCHEMA_FILES}


def referenced_uris(schema):
    """Every $id, $ref and $dynamicRef string anywhere in a schema document."""
    found = []

    def walk(node):
        if isinstance(node, dict):
            for key, value in node.items():
                if key in ("$id", "$ref", "$dynamicRef") and isinstance(value, str):
                    found.append(value)
                walk(value)
        elif isinstance(node, list):
            for value in node:
                walk(value)

    walk(schema)
    return found


def remotes_for(schema):
    """The remotes map a schema needs, or None when it needs none.

    A schema that identifies itself with, or refers to, the suite's remote host
    gets the whole set: relative references inside those documents mean the set
    cannot be pruned by looking at one document's text. A schema that refers to
    a published meta-schema gets the nine meta-schema documents. Note that
    $schema is not a reference — it names a dialect, which this problem
    ignores — so it does not pull anything in.
    """
    uris = referenced_uris(schema)
    if any("localhost:1234" in u for u in uris):
        return ALL_REMOTES
    if any("json-schema.org/draft/2020-12/" in u for u in uris):
        return METASCHEMA_REMOTES
    return None


class Suite:
    def __init__(self):
        self.cases = []
        self.seen = set()

    def add(self, name, schema, tests, remotes="auto", expected=None):
        """Queue one test case.

        tests is a list of {"data": ..., "description": ...}; expected, when
        given, is the list of "valid"/"invalid" lines the case must produce.
        """
        if name in self.seen:
            raise SystemExit("duplicate test name " + name)
        self.seen.add(name)
        doc = {"schema": schema, "tests": tests}
        if remotes == "auto":
            remotes = remotes_for(schema)
        if remotes:
            doc["remotes"] = remotes
        self.cases.append((name, doc, expected))


def hand_written(suite):
    add = suite.add

    add("boolean_schemas", {"$defs": {"yes": True, "no": False},
                            "properties": {"a": True, "b": False}}, [
        {"description": "empty object", "data": {}},
        {"description": "a may be anything", "data": {"a": [1, 2]}},
        {"description": "b may not be present", "data": {"b": None}},
    ])

    add("empty_schema_accepts_everything", {}, [
        {"description": "null", "data": None},
        {"description": "number", "data": 1.5},
        {"description": "nested", "data": {"x": [1, {"y": "z"}]}},
    ])

    add("type_integer_vs_number", {"type": "integer"}, [
        {"description": "integer literal", "data": 42},
        {"description": "zero fraction is an integer", "data": 1.0},
        {"description": "exponent form is an integer", "data": 1e2},
        {"description": "true fraction", "data": 1.5},
        {"description": "boolean is not a number", "data": True},
        {"description": "string is not a number", "data": "42"},
    ])

    add("type_union_and_null", {"type": ["string", "null"]}, [
        {"description": "string", "data": "x"},
        {"description": "null", "data": None},
        {"description": "false is not null", "data": False},
    ])

    add("equality_is_type_aware", {"enum": [1, "1", None, [1], {"a": 1}]}, [
        {"description": "number one", "data": 1},
        {"description": "1.0 equals 1", "data": 1.0},
        {"description": "string one", "data": "1"},
        {"description": "true is not 1", "data": True},
        {"description": "false is not 0", "data": False},
        {"description": "object with same content", "data": {"a": 1.000}},
        {"description": "array with different content", "data": [2]},
    ])

    add("multipleOf_exact_decimal", {"multipleOf": 0.0001}, [
        {"description": "0.0075", "data": 0.0075},
        {"description": "0.00751", "data": 0.00751},
        {"description": "zero", "data": 0},
        {"description": "large integer", "data": 12391239123},
        {"description": "0.3 with multipleOf 0.0001", "data": 0.3},
        {"description": "0.0021 with multipleOf 0.0001", "data": 0.0021},
        {"description": "non-numbers are ignored", "data": "0.0075"},
    ])

    add("bounds_on_large_numbers",
        {"type": "number", "minimum": -1e308, "exclusiveMaximum": 1e308}, [
            {"description": "at the inclusive lower bound", "data": -1e308},
            {"description": "just inside the upper bound", "data": 9.99e307},
            {"description": "at the exclusive upper bound", "data": 1e308},
            {"description": "beyond the exclusive upper bound", "data": 1.5e308},
        ])

    add("string_length_counts_code_points",
        {"type": "string", "minLength": 2, "maxLength": 3}, [
            {"description": "two astral code points", "data": "\U0001F4A9\U0001F4A9"},
            {"description": "one astral code point is too short", "data": "\U0001F4A9"},
            {"description": "three combining characters", "data": "e\u0301\u0302"},
            {"description": "four characters", "data": "abcd"},
        ])

    add("pattern_is_a_search_not_a_full_match",
        {"type": "string", "pattern": "^[1-5](?:[0-9]{2}|XX)$"}, [
            {"description": "a status code", "data": "404"},
            {"description": "a wildcard code", "data": "4XX"},
            {"description": "out of range", "data": "600"},
            {"description": "trailing text", "data": "404 Not Found"},
        ])

    add("pattern_unanchored", {"patternProperties": {"o": {"type": "integer"}},
                               "additionalProperties": {"type": "string"}}, [
        {"description": "foo matches o anywhere", "data": {"foo": 1}},
        {"description": "foo with a string value", "data": {"foo": "1"}},
        {"description": "bar has no o", "data": {"bar": "1"}},
    ])

    add("uniqueItems_ignores_key_order", {"uniqueItems": True}, [
        {"description": "same object, different key order",
         "data": [{"a": 1, "b": 2}, {"b": 2, "a": 1}]},
        {"description": "1 and 1.0 are the same number", "data": [1, 1.0]},
        {"description": "0, false and \"0\" all differ", "data": [0, False, "0"]},
        {"description": "nested arrays differ", "data": [[1, [2]], [1, [3]]]},
    ])

    add("contains_with_counts",
        {"type": "array", "contains": {"type": "integer"},
         "minContains": 2, "maxContains": 3}, [
            {"description": "two integers", "data": [1, "a", 2]},
            {"description": "one integer", "data": [1, "a"]},
            {"description": "four integers", "data": [1, 2, 3, 4]},
            {"description": "three integers among others", "data": ["a", 1, 2, 3, "b"]},
        ])

    add("dependent_requirements",
        {"type": "object",
         "dependentRequired": {"card": ["billing_address"]},
         "dependentSchemas": {"billing_address": {"required": ["country"]}}}, [
            {"description": "no dependencies triggered", "data": {"name": "a"}},
            {"description": "card without billing address", "data": {"card": "x"}},
            {"description": "card with an incomplete address",
             "data": {"card": "x", "billing_address": "s"}},
            {"description": "complete", "data": {"card": "x", "billing_address": "s", "country": "NZ"}},
        ])

    add("unevaluated_properties_across_alloff",
        {"allOf": [{"properties": {"a": {"type": "integer"}}},
                   {"properties": {"b": {"type": "integer"}}}],
         "if": {"required": ["a"]},
         "then": {"properties": {"c": {"type": "string"}}},
         "unevaluatedProperties": False}, [
            {"description": "a and b are evaluated by allOf", "data": {"a": 1, "b": 2}},
            {"description": "c is evaluated only when a is present",
             "data": {"a": 1, "c": "yes"}},
            {"description": "c without a is unevaluated", "data": {"b": 2, "c": "yes"}},
            {"description": "d is never evaluated", "data": {"a": 1, "d": 0}},
        ])

    add("unevaluated_items_after_prefix",
        {"prefixItems": [{"type": "string"}],
         "anyOf": [{"prefixItems": [True, {"type": "integer"}]},
                   {"prefixItems": [True, {"type": "boolean"}]}],
         "unevaluatedItems": {"const": "tail"}}, [
            {"description": "two evaluated items", "data": ["a", 1]},
            {"description": "second item evaluated by the other branch", "data": ["a", True]},
            {"description": "third item must be the constant", "data": ["a", 1, "tail"]},
            {"description": "third item is something else", "data": ["a", 1, "other"]},
        ])

    add("local_refs_and_anchors",
        {"$id": "https://example.test/root",
         "$defs": {"pos": {"$anchor": "positive", "type": "integer", "minimum": 1},
                   "pair": {"type": "array", "prefixItems": [{"$ref": "#positive"},
                                                             {"$ref": "#/$defs/pos"}],
                            "minItems": 2}},
         "$ref": "#/$defs/pair"}, [
            {"description": "two positive integers", "data": [1, 2]},
            {"description": "second is zero", "data": [1, 0]},
            {"description": "too short", "data": [1]},
        ])

    add("base_uri_changes_and_remote_refs",
        {"$id": "http://localhost:1234/draft2020-12/root-of-its-own.json",
         "type": "object",
         "properties": {"i": {"$ref": "integer.json"},
                        "s": {"$ref": "nested/string.json"},
                        "n": {"$ref": "subSchemas.json#/$defs/integer"}}}, [
            {"description": "all three resolve", "data": {"i": 1, "s": "x", "n": 2}},
            {"description": "wrong type behind a relative ref", "data": {"i": "1"}},
            {"description": "wrong type behind a fragment ref", "data": {"n": "2"}},
        ])

    generic_list = {
        "$id": "https://example.test/list",
        "$defs": {"itemType": {"$dynamicAnchor": "itemType"}},
        "type": "array",
        "items": {"$dynamicRef": "#itemType"},
    }
    add("dynamic_ref_extends_a_generic_list",
        {"$id": "https://example.test/strings",
         "$defs": {"itemType": {"$dynamicAnchor": "itemType", "type": "string"},
                   "list": generic_list},
         "$ref": "https://example.test/list"}, [
            {"description": "all strings", "data": ["a", "b"]},
            {"description": "one number", "data": ["a", 1]},
            {"description": "empty array", "data": []},
            {"description": "not an array", "data": "a"},
        ], remotes=None)

    add("format_is_an_annotation_only",
        {"type": "string", "format": "ipv4"}, [
            {"description": "a valid address", "data": "10.0.0.1"},
            {"description": "not an address at all", "data": "nope"},
            {"description": "not a string", "data": 7},
        ])

    add("unknown_keywords_are_ignored",
        {"type": "object", "madeUpKeyword": {"type": "integer"},
         "properties": {"x": {"type": "string", "alsoMadeUp": 3}}}, [
            {"description": "x is a string", "data": {"x": "s"}},
            {"description": "x is a number", "data": {"x": 1}},
        ])


    add("rejected_branches_annotate_nothing",
        {"anyOf": [{"properties": {"a": {"type": "integer"}}, "required": ["never"]},
                   {"properties": {"b": {"type": "integer"}}}],
         "oneOf": [{"properties": {"c": {"type": "integer"}}, "required": ["never"]},
                   {"properties": {"d": {"type": "integer"}}}],
         "unevaluatedProperties": False}, [
            {"description": "only the accepting branches evaluate anything",
             "data": {"b": 1, "d": 2}},
            {"description": "a is named only by the rejected anyOf branch",
             "data": {"a": 1, "b": 1, "d": 2}},
            {"description": "c is named only by the rejected oneOf branch",
             "data": {"b": 1, "c": 1, "d": 2}},
            {"description": "e is named by nothing", "data": {"b": 1, "d": 2, "e": 3}},
        ])

    add("not_and_failed_if_annotate_nothing",
        {"not": {"properties": {"a": {"type": "integer"}}, "required": ["never"]},
         "if": {"properties": {"b": {"type": "integer"}}, "required": ["never"]},
         "then": {"properties": {"c": {}}},
         "else": {"properties": {"d": {"type": "integer"}}},
         "unevaluatedProperties": False}, [
            {"description": "else applies and evaluates d", "data": {"d": 1}},
            {"description": "a is named only inside not", "data": {"a": 1, "d": 1}},
            {"description": "b is named only by the if that failed", "data": {"b": 1, "d": 1}},
            {"description": "then was never applied", "data": {"c": 1, "d": 1}},
        ])

    add("anchor_beats_dynamic_anchor",
        {"$id": "https://example.test/a",
         "$defs": {"plain": {"$anchor": "x", "type": "integer"},
                   "dyn": {"$dynamicAnchor": "x", "type": "string"}},
         "$ref": "#x"}, [
            {"description": "the $anchor is the plain-name target", "data": 1},
            {"description": "the $dynamicAnchor is not", "data": "s"},
        ])

    add("id_fragment_is_removed",
        {"$id": "https://example.test/root#",
         "$defs": {"i": {"$id": "https://example.test/int#", "type": "integer"}},
         "properties": {"a": {"$ref": "https://example.test/int"},
                        "b": {"$ref": "int"}}}, [
            {"description": "both refs find the fragmentless base URI",
             "data": {"a": 1, "b": 2}},
            {"description": "and the target still asserts", "data": {"a": "x"}},
        ])

    regex_patterns = {
        "lazy": "^<.+?>$",
        "lazyopt": "^a??b$",
        "reps": "^\\d{2,4}$",
        "openrep": "^x{2,}$",
        "litbrace": "^a{b$",
        "hex": "\\x41\\u00e9",
        "nonbound": "\\Bcat",
        "bound": "\\bcat\\b",
        "negclass": "^[^\\d\\s]+$",
        "dot": "^a.b$",
        "classesc": "^[\\w-]+$",
        "nested": "^(a(b|c)+d)$",
        "anchorend": "^a$",
    }
    regex_instances = [
        ("lazy", "<abc>"), ("lazy", "<a><b>"),
        ("lazyopt", "b"), ("lazyopt", "ab"), ("lazyopt", "aab"),
        ("reps", "123"), ("reps", "1"), ("reps", "12345"),
        ("openrep", "xx"), ("openrep", "x"),
        ("litbrace", "a{b"), ("litbrace", "ab"),
        ("hex", "zA\u00e9z"), ("hex", "Ae"),
        ("nonbound", "concat"), ("nonbound", "cat food"),
        ("bound", "the cat sat"), ("bound", "concat"), ("bound", "\u00e9cat "),
        ("negclass", "abc-"), ("negclass", "ab c"), ("negclass", "ab1"),
        ("dot", "axb"), ("dot", "a\nb"),
        ("classesc", "a_1-b"), ("classesc", "a b"),
        ("nested", "abcbd"), ("nested", "ad"),
        ("anchorend", "a"), ("anchorend", "a\n"), ("anchorend", "ba"),
    ]
    add("regex_subset_coverage",
        {"type": "object",
         "properties": {name: {"type": "string", "pattern": pattern}
                        for name, pattern in regex_patterns.items()}},
        [{"description": "%s matches %r" % (name, text), "data": {name: text}}
         for name, text in regex_instances])


def suite_cases(suite):
    tests_dir = os.path.join(SUITE, "tests", "draft2020-12")
    on_disk = sorted(f for f in os.listdir(tests_dir) if f.endswith(".json"))
    if set(on_disk) != set(SUITE_ORDER):
        raise SystemExit("SUITE_ORDER does not match %s" % tests_dir)
    for filename in SUITE_ORDER:
        stem = slug(filename[:-5], 24)
        groups = read_json(os.path.join(tests_dir, filename))
        for index, group in enumerate(groups):
            if (filename, index) in SKIP_GROUPS:
                continue
            name = "%s_%02d_%s" % (stem, index, slug(group["description"]))
            tests = [{"description": t["description"], "data": t["data"]}
                     for t in group["tests"]]
            expected = ["valid" if t["valid"] else "invalid" for t in group["tests"]]
            suite.add(name, group["schema"], tests, expected=expected)


def npm_schema():
    """The SchemaStore package.json schema, converted to draft 2020-12.

    The conversion is purely mechanical: the dialect is switched, the draft-07
    `definitions` keyword is renamed to `$defs`, and the JSON pointers that
    referred to it are repointed. The schema uses no other draft-07-only
    construct (no array-form `items`, no boolean `exclusiveMinimum`, no
    `dependencies` keyword).
    """
    text = open(os.path.join(CORPUS, "npm", "package-draft07.json"), encoding="utf-8").read()
    text = text.replace('"#/definitions/', '"#/$defs/')
    schema = json.loads(text)
    schema["$schema"] = "https://json-schema.org/draft/2020-12/schema"
    schema["$id"] = "https://json.schemastore.org/package.json"
    schema["$defs"] = schema.pop("definitions")
    return schema


def real_world(suite):
    examples = os.path.join(CORPUS, "openapi", "examples")
    oas = read_json(os.path.join(CORPUS, "openapi", "oas31-schema.json"))

    def example(name):
        return read_json(os.path.join(examples, name))

    def as_31(name):
        doc = example(name)
        doc["openapi"] = "3.1.0"
        return doc

    suite.add("openapi31_published_documents", oas, [
        {"description": "webhook-example.json", "data": example("v3.1_webhook-example.json")},
        {"description": "non-oauth-scopes.json", "data": example("v3.1_non-oauth-scopes.json")},
        {"description": "tictactoe.json", "data": example("v3.1_tictactoe.json")},
    ], remotes=None)

    suite.add("openapi31_documents_upgraded_from_30", oas, [
        {"description": "petstore", "data": as_31("v3.0_petstore.json")},
        {"description": "petstore-expanded", "data": as_31("v3.0_petstore-expanded.json")},
        {"description": "uspto", "data": as_31("v3.0_uspto.json")},
        {"description": "api-with-examples", "data": as_31("v3.0_api-with-examples.json")},
        {"description": "link-example", "data": as_31("v3.0_link-example.json")},
        {"description": "callback-example", "data": as_31("v3.0_callback-example.json")},
    ], remotes=None)

    wrong_version = example("v3.0_petstore.json")
    no_info = as_31("v3.0_petstore.json")
    del no_info["info"]
    bad_path = as_31("v3.0_petstore.json")
    bad_path["paths"]["pets"] = bad_path["paths"].pop("/pets")
    bad_status = as_31("v3.0_petstore.json")
    responses = bad_status["paths"]["/pets"]["get"]["responses"]
    responses["twohundred"] = responses.pop("200")
    extra_key = as_31("v3.0_petstore.json")
    extra_key["info"]["licence"] = "MIT"
    suite.add("openapi31_rejected_documents", oas, [
        {"description": "an OpenAPI 3.0 document", "data": wrong_version},
        {"description": "info is required", "data": no_info},
        {"description": "path keys must start with a slash", "data": bad_path},
        {"description": "response keys must be status codes", "data": bad_status},
        {"description": "info forbids unknown properties", "data": extra_key},
    ], remotes=None)

    pkg = npm_schema()
    instances = os.path.join(CORPUS, "npm", "instances")
    manifests = sorted(f for f in os.listdir(instances) if f.endswith(".json"))
    suite.add("npm_published_manifests", pkg,
              [{"description": f, "data": read_json(os.path.join(instances, f))}
               for f in manifests], remotes=None)

    base = read_json(os.path.join(instances, "express.json"))

    def broken(**changes):
        doc = copy.deepcopy(base)
        doc.update(changes)
        return doc

    no_deps = copy.deepcopy(base)
    no_deps["dependencies"] = {"body-parser": 1}
    bad_scripts = copy.deepcopy(base)
    bad_scripts["scripts"] = {"test": ["mocha"]}
    suite.add("npm_rejected_manifests", pkg, [
        {"description": "version must be a string", "data": broken(version=5)},
        {"description": "name has a length limit",
         "data": broken(name="x" * 250)},
        {"description": "dependency ranges are strings", "data": no_deps},
        {"description": "scripts hold strings", "data": bad_scripts},
        {"description": "bugs must be a string or an object",
         "data": broken(bugs=["https://example.test"])},
    ], remotes=None)

    meta = read_json(os.path.join(CORPUS, "metaschema", "schema.json"))
    suite_dir = os.path.join(SUITE, "tests", "draft2020-12")
    published = [
        ("the OpenAPI 3.1 schema", oas),
        ("the package.json schema", pkg),
        ("the 2020-12 meta-schema itself", meta),
        ("the applicator vocabulary schema",
         read_json(os.path.join(CORPUS, "metaschema", "applicator.json"))),
        ("a schema from the test suite",
         read_json(os.path.join(suite_dir, "unevaluatedProperties.json"))[0]["schema"]),
    ]
    suite.add("metaschema_over_published_schemas", meta,
              [{"description": d, "data": s} for d, s in published],
              remotes=METASCHEMA_REMOTES)

    suite.add("metaschema_rejects_malformed_schemas", meta, [
        {"description": "type must name a JSON type", "data": {"type": "nunber"}},
        {"description": "required holds strings", "data": {"required": [1]}},
        {"description": "minLength must not be negative", "data": {"minLength": -1}},
        {"description": "$defs values must be schemas", "data": {"$defs": {"a": 3}}},
        {"description": "$anchor has a restricted syntax", "data": {"$anchor": "9lives"}},
        {"description": "pattern must be a string", "data": {"pattern": 7}},
        {"description": "a boolean is a schema", "data": True},
        {"description": "a well-formed schema", "data": {"type": ["string", "null"]}},
    ], remotes=METASCHEMA_REMOTES)


ORACLE_SCRIPT = r'''
import json, sys
import jsonschema
from referencing import Registry, Resource
from referencing.jsonschema import DRAFT202012

doc = json.load(open(sys.argv[1], encoding="utf-8"))
resources = []
for uri, remote in (doc.get("remotes") or {}).items():
    resources.append((uri, Resource.from_contents(remote, default_specification=DRAFT202012)))
registry = Registry().with_resources(resources)
validator = jsonschema.Draft202012Validator(doc["schema"], registry=registry)
for case in doc["tests"]:
    print("valid" if validator.is_valid(case["data"]) else "invalid")
'''


def run_reference(path):
    proc = subprocess.run(REF, stdin=open(path, "rb"), capture_output=True)
    if proc.returncode != 0:
        raise SystemExit("reference failed on %s:\n%s" %
                         (path, proc.stderr.decode("utf-8", "replace")))
    return proc.stdout.decode("utf-8").split()


def run_oracle(script, path):
    proc = subprocess.run([ORACLE_PY, script, path], capture_output=True)
    if proc.returncode != 0:
        return None, proc.stderr.decode("utf-8", "replace")
    return proc.stdout.decode("utf-8").split(), None


def main():
    suite = Suite()
    hand_written(suite)
    suite_cases(suite)
    real_world(suite)

    if os.path.isdir(TESTS):
        shutil.rmtree(TESTS)
    os.makedirs(TESTS)

    script = os.path.join(TESTS, "_oracle.py")
    with open(script, "w", encoding="utf-8") as f:
        f.write(ORACLE_SCRIPT)
    have_oracle = os.path.exists(ORACLE_PY)
    if not have_oracle:
        print("warning: %s is missing; skipping the cross-check" % ORACLE_PY)

    divergences = {(name, index): reason
                   for name, index, reason in KNOWN_ORACLE_DIVERGENCES}
    checked = 0
    for number, (name, doc, expected) in enumerate(suite.cases, start=1):
        stem = "%03d_%s" % (number, name)
        in_path = os.path.join(TESTS, stem + ".in")
        with open(in_path, "w", encoding="utf-8") as f:
            json.dump(doc, f, indent=2, ensure_ascii=False)
            f.write("\n")
        produced = run_reference(in_path)
        if len(produced) != len(doc["tests"]):
            raise SystemExit("%s: %d lines for %d tests" %
                             (stem, len(produced), len(doc["tests"])))
        if expected is not None and produced != expected:
            for i, (a, b) in enumerate(zip(produced, expected)):
                if a != b:
                    raise SystemExit("%s test %d (%s): suite says %s, reference says %s" %
                                     (stem, i, doc["tests"][i]["description"], b, a))
        if have_oracle:
            oracle, err = run_oracle(script, in_path)
            if oracle is None:
                raise SystemExit("oracle failed on %s:\n%s" % (stem, err))
            if len(oracle) != len(produced):
                raise SystemExit("%s: oracle produced %d lines for %d tests" %
                                 (stem, len(oracle), len(produced)))
            for i, (a, b) in enumerate(zip(produced, oracle)):
                if a != b and (name, i) not in divergences:
                    raise SystemExit("%s test %d (%s): oracle says %s, reference says %s" %
                                     (stem, i, doc["tests"][i]["description"], b, a))
            checked += len(oracle)
        with open(os.path.join(TESTS, stem + ".out"), "w", encoding="utf-8") as f:
            f.write("".join(line + "\n" for line in produced))

    os.remove(script)
    assertions = sum(len(doc["tests"]) for _, doc, _ in suite.cases)
    print("wrote %d test cases (%d assertions); cross-checked %d against the oracle"
          % (len(suite.cases), assertions, checked))
    for (name, index), reason in divergences.items():
        print("known oracle divergence: %s test %d — %s" % (name, index, reason))


# tests/ is handed out without corpus/, so it carries the licences of its
# third-party data.
TEST_NOTICE = 'corpus/tests-notice.md'
TEST_LICENCES = [
    ('corpus/json-schema-test-suite/LICENSE',
     'LICENSE-json-schema-test-suite.txt'),
    ('corpus/metaschema/LICENSE',
     'LICENSE-json-schema-spec.txt'),
    ('corpus/openapi/LICENSE-Apache-2.0.txt',
     'LICENSE-openapi-schema-Apache-2.0.txt'),
    ('corpus/openapi/examples/LICENSE-CC-BY-4.0.txt',
     'LICENSE-openapi-examples-CC-BY-4.0.txt'),
    ('corpus/npm/LICENSE-SchemaStore-Apache-2.0.txt',
     'LICENSE-SchemaStore-Apache-2.0.txt'),
    ('corpus/npm/instances/LICENSE-axios-MIT.txt',
     'LICENSE-npm-axios-MIT.txt'),
    ('corpus/npm/instances/LICENSE-chalk-MIT.txt',
     'LICENSE-npm-chalk-MIT.txt'),
    ('corpus/npm/instances/LICENSE-eslint-MIT.txt',
     'LICENSE-npm-eslint-MIT.txt'),
    ('corpus/npm/instances/LICENSE-express-MIT.txt',
     'LICENSE-npm-express-MIT.txt'),
    ('corpus/npm/instances/LICENSE-lodash-MIT.txt',
     'LICENSE-npm-lodash-MIT.txt'),
]


def copy_licences():
    shutil.copyfile(os.path.join(HERE, TEST_NOTICE),
                    os.path.join(TESTS, 'THIRD_PARTY.md'))
    for src, name in TEST_LICENCES:
        shutil.copyfile(os.path.join(HERE, src), os.path.join(TESTS, name))


if __name__ == "__main__":
    main()
    copy_licences()
