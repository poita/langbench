"""Keyword behaviour, grouped like the specification's sections."""

import pytest

from jsonschema2020 import RefResolutionError, SchemaError, Validator, loads, validate


def valid(schema, instance, remotes=None):
    if isinstance(schema, str):
        schema = loads(schema)
    if isinstance(instance, str):
        instance = loads(instance)
    return Validator(schema, remotes, normalized=True).is_valid(instance, normalized=True)


CASES = [
    # (schema, instance, expected)
    ("true", "1", True),
    ("false", "1", False),
    ("{}", "null", True),
    # type
    ('{"type":"integer"}', "1.0", True),
    ('{"type":"integer"}', "1.5", False),
    ('{"type":"integer"}', "1e2", True),
    ('{"type":"number"}', "true", False),
    ('{"type":["string","null"]}', "null", True),
    ('{"type":["string","null"]}', "1", False),
    ('{"type":"boolean"}', "0", False),
    # enum / const use JSON equality
    ('{"enum":[1,"1",null,[1],{"a":1}]}', "1.0", True),
    ('{"enum":[1,"1",null,[1],{"a":1}]}', '{"a":1.000}', True),
    ('{"enum":[1,"1",null,[1],{"a":1}]}', "true", False),
    ('{"enum":[1,"1",null,[1],{"a":1}]}', "[2]", False),
    ('{"enum":[0]}', "false", False),
    ('{"const":{"a":1,"b":2}}', '{"b":2,"a":1}', True),
    ('{"const":[true]}', "[1]", False),
    # numbers
    ('{"multipleOf":0.0001}', "0.3", True),
    ('{"multipleOf":0.0001}', "0.0021", True),
    ('{"multipleOf":0.0001}', "0.00005", False),
    ('{"multipleOf":2}', "7", False),
    ('{"multipleOf":2}', "0", True),
    ('{"multipleOf":1.5}', "4.5", True),
    ('{"maximum":1e308}', "1e309", False),
    ('{"minimum":-1e400}', "-1e399", True),
    ('{"exclusiveMinimum":1}', "1.0", False),
    ('{"exclusiveMaximum":1}', "0.999999999999999999999", True),
    ('{"maximum":3}', '"a"', True),
    # strings
    ('{"maxLength":1}', '"\\ud83d\\udca9"', True),
    ('{"minLength":2}', '"\\u00e9"', False),
    ('{"minLength":2.0}', '"ab"', True),
    ('{"maxLength":2e0}', '"abc"', False),
    ('{"pattern":"bar"}', '"foobarbaz"', True),
    ('{"pattern":"^bar"}', '"foobarbaz"', False),
    ('{"format":"ipv4","type":"string"}', '"nope"', True),
    # arrays
    ('{"minItems":2}', "[1]", False),
    ('{"maxItems":1}', "[1,2]", False),
    ('{"uniqueItems":true}', "[1,true]", True),
    ('{"uniqueItems":true}', "[1,1.0]", False),
    ('{"uniqueItems":true}', '[{"a":1,"b":2},{"b":2,"a":1}]', False),
    ('{"uniqueItems":true}', "[[1],[true]]", True),
    ('{"uniqueItems":false}', "[1,1]", True),
    ('{"prefixItems":[{"type":"integer"},{"type":"string"}]}', '[1,"a",null]', True),
    ('{"prefixItems":[{"type":"integer"},{"type":"string"}]}', '["a"]', False),
    ('{"prefixItems":[{"type":"integer"}],"items":{"type":"string"}}', '[1,"a","b"]', True),
    ('{"prefixItems":[{"type":"integer"}],"items":{"type":"string"}}', '[1,"a",2]', False),
    ('{"items":false}', "[]", True),
    ('{"items":false}', "[1]", False),
    ('{"contains":{"type":"integer"}}', '["a"]', False),
    ('{"contains":{"type":"integer"}}', '["a",1]', True),
    ('{"contains":{"type":"integer"},"minContains":2,"maxContains":3}', '[1,"a",2]', True),
    ('{"contains":{"type":"integer"},"minContains":2,"maxContains":3}', '[1,"a"]', False),
    ('{"contains":{"type":"integer"},"minContains":2,"maxContains":3}', "[1,2,3,4]", False),
    ('{"contains":{"type":"integer"},"minContains":0}', '["a"]', True),
    ('{"contains":{"type":"integer"},"minContains":0,"maxContains":0}', "[1]", False),
    ('{"minContains":2}', "[]", True),
    # objects
    ('{"required":["a"]}', '{"a":1}', True),
    ('{"required":["a"]}', "{}", False),
    ('{"required":["a"]}', "[]", True),
    ('{"minProperties":1}', "{}", False),
    ('{"maxProperties":0}', "{}", True),
    ('{"dependentRequired":{"a":["b"]}}', '{"a":1}', False),
    ('{"dependentRequired":{"a":["b"]}}', '{"b":1}', True),
    ('{"properties":{"a":{"type":"integer"}}}', '{"a":"x"}', False),
    ('{"properties":{"a":{"type":"integer"}}}', '{"b":"x"}', True),
    ('{"patternProperties":{"^a":{"type":"integer"},"b$":{"minimum":5}}}', '{"ab":3}', False),
    ('{"patternProperties":{"^a":{"type":"integer"},"b$":{"minimum":5}}}', '{"ab":7}', True),
    ('{"additionalProperties":false,"properties":{"a":{}}}', '{"a":1,"b":2}', False),
    ('{"additionalProperties":false,"properties":{"a":{}}}', '{"a":1}', True),
    ('{"additionalProperties":false,"patternProperties":{"^x":{}}}', '{"xy":1}', True),
    ('{"propertyNames":{"maxLength":2}}', '{"ab":1,"abc":2}', False),
    ('{"propertyNames":{"pattern":"^a"}}', '{"ab":1}', True),
    ('{"dependentSchemas":{"a":{"required":["b"]}}}', '{"a":1}', False),
    ('{"dependentSchemas":{"a":{"required":["b"]}}}', '{"a":1,"b":1}', True),
    # applicators
    ('{"allOf":[{"type":"integer"},{"minimum":2}]}', "1", False),
    ('{"anyOf":[{"type":"string"},{"minimum":2}]}', "3", True),
    ('{"anyOf":[{"type":"string"},{"minimum":2}]}', "1", False),
    ('{"oneOf":[{"type":"integer"},{"minimum":2}]}', "3", False),
    ('{"oneOf":[{"type":"integer"},{"minimum":2}]}', "1", True),
    ('{"not":{"type":"string"}}', '"a"', False),
    ('{"if":{"minimum":0},"then":{"maximum":10},"else":{"minimum":-10}}', "5", True),
    ('{"if":{"minimum":0},"then":{"maximum":10},"else":{"minimum":-10}}', "15", False),
    ('{"if":{"minimum":0},"then":{"maximum":10},"else":{"minimum":-10}}', "-15", False),
    ('{"then":false}', "1", True),
    ('{"else":false}', "1", True),
    ('{"if":false}', "1", True),
    # unknown / inert keywords
    ('{"definitions":{"x":false},"dependencies":{"a":["b"]},"bogus":false}', '{"a":1}', True),
    ('{"$defs":{"x":false},"title":"t","$comment":"c","default":1}', "1", True),
]


@pytest.mark.parametrize("schema,instance,expected", CASES)
def test_keyword(schema, instance, expected):
    assert valid(schema, instance) is expected


# -- annotations -----------------------------------------------------------


def test_unevaluated_properties_worked_example():
    schema = {
        "allOf": [
            {"properties": {"a": {"type": "integer"}}},
            {"properties": {"b": {"type": "integer"}}},
        ],
        "if": {"required": ["a"]},
        "then": {"properties": {"c": {"type": "string"}}},
        "unevaluatedProperties": False,
    }
    validator = Validator(schema)
    assert validator.is_valid({"a": 1, "b": 2})
    assert validator.is_valid({"a": 1, "c": "yes"})
    assert not validator.is_valid({"b": 2, "c": "yes"})
    assert not validator.is_valid({"a": 1, "d": 0})


def test_unevaluated_properties_ignores_rejected_branches():
    schema = {
        "anyOf": [
            {"properties": {"a": True}, "required": ["z"]},
            {"properties": {"b": True}},
        ],
        "unevaluatedProperties": False,
    }
    v = Validator(schema)
    assert v.is_valid({"b": 1})
    assert not v.is_valid({"a": 1})
    assert not v.is_valid({"a": 1, "z": 1, "b": 1})  # nothing evaluated "z"


def test_not_contributes_no_annotations():
    v = Validator({"not": {"not": {"properties": {"a": True}}}, "unevaluatedProperties": False})
    assert not v.is_valid({"a": 1})


def test_unevaluated_items():
    v = Validator({"prefixItems": [True], "unevaluatedItems": {"type": "string"}})
    assert v.is_valid([1, "a", "b"])
    assert not v.is_valid([1, "a", 2])
    v = Validator({"contains": {"type": "integer"}, "unevaluatedItems": False})
    assert v.is_valid([1, 2])  # contains annotates every match
    assert not v.is_valid([1, "a"])
    v = Validator({"items": True, "unevaluatedItems": False})
    assert v.is_valid([1, 2, 3])


def test_unevaluated_crosses_ref():
    v = Validator(
        {
            "$ref": "#/$defs/base",
            "$defs": {"base": {"properties": {"a": True}}},
            "unevaluatedProperties": False,
        }
    )
    assert v.is_valid({"a": 1})
    assert not v.is_valid({"a": 1, "b": 1})


def test_nested_unevaluated_does_not_see_siblings_of_parent():
    v = Validator(
        {
            "properties": {"a": True},
            "allOf": [{"unevaluatedProperties": False}],
        }
    )
    # the allOf branch is evaluated on its own: "a" is not evaluated *there*
    assert not v.is_valid({"a": 1})


# -- references --------------------------------------------------------------


def test_ref_with_siblings():
    v = Validator({"$ref": "#/$defs/i", "maximum": 5, "$defs": {"i": {"type": "integer"}}})
    assert v.is_valid(3)
    assert not v.is_valid(7)
    assert not v.is_valid(1.5)


def test_ref_pointer_escapes_and_percent_decoding():
    schema = {
        "properties": {
            "x": {"$ref": "#/$defs/a~1b"},
            "y": {"$ref": "#/$defs/c%25d"},
            "z": {"$ref": "#/$defs/e%20f"},
        },
        "$defs": {"a/b": {"type": "integer"}, "c%d": {"type": "string"}, "e f": {"type": "null"}},
    }
    v = Validator(schema)
    assert v.is_valid({"x": 1, "y": "s", "z": None})
    assert not v.is_valid({"x": "1"})
    assert not v.is_valid({"y": 1})
    assert not v.is_valid({"z": 1})


def test_anchors_and_ids():
    schema = {
        "$id": "http://example.test/root",
        "$defs": {
            "a": {"$anchor": "foo", "type": "integer"},
            "b": {"$id": "other", "$defs": {"c": {"$anchor": "foo", "type": "string"}}},
        },
        "properties": {
            "p": {"$ref": "#foo"},
            "q": {"$ref": "other#foo"},
            "r": {"$ref": "http://example.test/other#/$defs/c"},
        },
    }
    v = Validator(schema)
    assert v.is_valid({"p": 1, "q": "s", "r": "t"})
    assert not v.is_valid({"p": "x"})
    assert not v.is_valid({"q": 1})
    assert not v.is_valid({"r": 1})


def test_id_inside_const_is_data():
    v = Validator(
        {
            "$id": "http://x.test/r",
            "const": {"$id": "http://x.test/other", "type": "x"},
            "$defs": {"a": {"type": "string"}},
            "properties": {"a": {"$ref": "#/$defs/a"}},
        }
    )
    assert v.is_valid({"$id": "http://x.test/other", "type": "x"})


def test_relative_ref_against_id_and_remotes():
    schema = {
        "$id": "http://localhost:1234/draft2020-12/root-of-its-own.json",
        "type": "object",
        "properties": {
            "i": {"$ref": "integer.json"},
            "n": {"$ref": "subSchemas.json#/$defs/integer"},
        },
    }
    remotes = {
        "http://localhost:1234/draft2020-12/integer.json": {"type": "integer"},
        "http://localhost:1234/draft2020-12/subSchemas.json": {"$defs": {"integer": {"type": "integer"}}},
    }
    v = Validator(schema, remotes)
    assert v.is_valid({"i": 1, "n": 2})
    assert not v.is_valid({"i": "1"})
    assert not v.is_valid({"n": "1"})


def test_recursive_ref():
    schema = {
        "type": "object",
        "properties": {"child": {"$ref": "#"}, "n": {"type": "integer"}},
    }
    v = Validator(schema)
    assert v.is_valid({"n": 1, "child": {"n": 2, "child": {}}})
    assert not v.is_valid({"child": {"child": {"n": "x"}}})


def test_dynamic_ref_extension_point():
    schema = {
        "$id": "https://example.test/strings",
        "$defs": {
            "itemType": {"$dynamicAnchor": "itemType", "type": "string"},
            "list": {
                "$id": "https://example.test/list",
                "$defs": {"itemType": {"$dynamicAnchor": "itemType"}},
                "type": "array",
                "items": {"$dynamicRef": "#itemType"},
            },
        },
        "$ref": "https://example.test/list",
    }
    v = Validator(schema)
    assert v.is_valid(["a", "b"])
    assert not v.is_valid(["a", 1])
    # Used on its own, the generic list accepts anything.
    standalone = Validator({"$ref": "https://example.test/list"}, {"https://example.test/list": schema["$defs"]["list"]})
    assert standalone.is_valid(["a", 1])


def test_dynamic_ref_without_dynamic_anchor_acts_like_ref():
    v = Validator({"$dynamicRef": "#/$defs/x", "$defs": {"x": {"type": "integer"}}})
    assert v.is_valid(1)
    assert not v.is_valid("1")


def test_anchor_beats_dynamic_anchor_for_plain_ref():
    schema = {
        "$id": "http://x.test/r",
        "$defs": {
            "a": {"$dynamicAnchor": "n", "type": "string"},
            "b": {"$anchor": "n", "type": "integer"},
        },
        "$ref": "#n",
    }
    v = Validator(schema)
    assert v.is_valid(1)
    assert not v.is_valid("1")


def test_unresolvable_reference_is_reported_when_reached():
    v = Validator({"properties": {"a": {"$ref": "http://nowhere.test/x"}}})
    assert v.is_valid({})
    with pytest.raises(RefResolutionError):
        v.is_valid({"a": 1})


def test_invalid_schema_shapes():
    with pytest.raises(SchemaError):
        Validator({"items": 5})
    with pytest.raises(SchemaError):
        Validator({"pattern": "("})


# -- python-native input ------------------------------------------------------


def test_python_floats_are_converted_exactly():
    assert validate({"multipleOf": 0.01}, 0.07)  # exact decimal arithmetic
    assert validate({"type": "integer"}, 2.0)
    assert not validate({"type": "integer"}, 2.5)
    assert not validate({"type": "integer"}, True)
    assert validate({"enum": [1]}, 1.0)
    assert validate({"items": {"type": "string"}}, ("a", "b"))


def test_validator_is_reusable():
    v = Validator({"type": "string", "minLength": 2})
    assert [v.is_valid(x) for x in ["ab", "a", 1, "abc"]] == [True, False, False, True]
