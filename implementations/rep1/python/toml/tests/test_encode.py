import pytest

from tomlcodec import dumps, from_tagged_json, loads, to_tagged_json


def enc(js):
    return dumps(from_tagged_json(js))


def test_worked_example():
    js = (
        '{"db":{"enabled":{"type":"bool","value":"true"},"ports":[{"type":"integer","value":"8001"},'
        '{"type":"integer","value":"8002"}]},"dob":{"type":"datetime","value":"1979-05-27T07:32:00-08:00"},'
        '"fruit":[{"name":{"type":"string","value":"apple"}},{"name":{"type":"string","value":"banana"}}],'
        '"name":{"type":"string","value":"Tom"}}'
    )
    assert enc(js) == (
        'dob = 1979-05-27T07:32:00-08:00\nname = "Tom"\n\n[db]\nenabled = true\nports = [8001, 8002]\n'
        '\n[[fruit]]\nname = "apple"\n\n[[fruit]]\nname = "banana"\n'
    )


def test_empty_root():
    assert enc("{}") == "\n"


def test_nested_header_without_blank_first_line():
    assert enc('{"a":{"b":{}}}') == "[a]\n\n[a.b]\n"


def test_key_quoting_and_order():
    out = enc('{"b c":{"x":{}},"":{}, "é":{},"a-1_":{}}')
    assert out == '[""]\n\n[a-1_]\n\n["b c"]\n\n["b c".x]\n\n["é"]\n'


def test_inline_forms():
    js = '{"a":[[{"type":"integer","value":"1"}],[]],"e":[]}'
    assert enc(js) == "a = [[1], []]\ne = []\n"


def test_inline_mixed_array_renders_tables_inline():
    js = '{"m":[{"k":{"type":"integer","value":"1"}},{"type":"integer","value":"2"}]}'
    assert enc(js) == "m = [{k = 1}, 2]\n"


def test_string_quoting():
    js = '{"s":{"type":"string","value":"a\\"\\\\\\b\\t\\n\\f\\r\\u0001\\u007fé"}}'
    assert enc(js) == 's = "a\\"\\\\\\b\\t\\n\\f\\r\\u0001\\u007fé"\n'


def test_type_value_table_is_a_table_only_if_not_scalar_node():
    js = '{"t":{"type":{"type":"string","value":"x"},"value":{"type":"string","value":"y"}}}'
    assert enc(js) == '[t]\ntype = "x"\nvalue = "y"\n'


DOCS = [
    "",
    "a = 1\nb = 'x'\n[t]\nc = [1, 'two', 3.5]\n[[t.u]]\nd = 1979-05-27\n[[t.u]]\ne = {f = 1}\n",
    '"quoted key"."é".z = "\\u0001\\u007f"\n',
    "[a.b.c]\n[a.d]\nx = 07:32:00.123456789\n",
    "m = [ {a = 1}, 2 ]\nn = [ {a = 1}, {b = 2} ]\nf = [inf, -inf, nan, 1e-7, 1.5e300]\n",
    "x = 1979-05-27T07:32:00+01:30\ny = 0x7fffffffffffffff\n",
]


@pytest.mark.parametrize("doc", DOCS)
def test_round_trip(doc):
    tagged = to_tagged_json(loads(doc))
    assert to_tagged_json(loads(enc(tagged))) == tagged
