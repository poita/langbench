import pytest

import tomlcodec


def enc(json_text):
    return tomlcodec.encode(json_text)


def test_spec_example():
    j = ('{"db":{"enabled":{"type":"bool","value":"true"},"ports":[{"type":"integer","value":"8001"},'
         '{"type":"integer","value":"8002"}]},"dob":{"type":"datetime","value":"1979-05-27T07:32:00-08:00"},'
         '"fruit":[{"name":{"type":"string","value":"apple"}},{"name":{"type":"string","value":"banana"}}],'
         '"name":{"type":"string","value":"Tom"}}')
    assert enc(j) == (
        'dob = 1979-05-27T07:32:00-08:00\nname = "Tom"\n\n[db]\nenabled = true\n'
        "ports = [8001, 8002]\n\n[[fruit]]\nname = \"apple\"\n\n[[fruit]]\nname = \"banana\"\n"
    )


def test_empty_root():
    assert enc("{}") == "\n"


def test_first_header_has_no_blank_line():
    assert enc('{"a":{"b":{}}}') == "[a]\n\n[a.b]\n"


def test_empty_tables_get_headers():
    assert enc('{"a":{},"b":[]}') == "b = []\n\n[a]\n"


def test_keys_are_quoted_when_needed():
    j = '{"a b":{"type":"bool","value":"true"},"":{"type":"bool","value":"false"},"é":{"type":"bool","value":"true"}}'
    assert enc(j) == '"" = false\n"a b" = true\n"é" = true\n'


def test_string_quoting():
    j = '{"s":{"type":"string","value":"\\"\\\\\\b\\t\\n\\f\\r\\u0000\\u007f é"}}'
    assert enc(j) == 's = "\\"\\\\\\b\\t\\n\\f\\r\\u0000\\u007f é"\n'


def test_mixed_arrays_are_inline():
    j = '{"a":[{"x":{"type":"integer","value":"1"}},{"type":"integer","value":"2"}],"b":[[],[{"type":"integer","value":"1"}]]}'
    assert enc(j) == "a = [{x = 1}, 2]\nb = [[], [1]]\n"


def test_nested_array_of_tables_paths():
    j = '{"a":[{"b":[{"c":{"type":"integer","value":"1"}}]}]}'
    assert enc(j) == "[[a]]\n\n[[a.b]]\nc = 1\n"


def test_float_text_is_verbatim():
    j = '{"f":{"type":"float","value":"1.0000000000000000e+00"},"n":{"type":"float","value":"nan"}}'
    assert enc(j) == "f = 1.0000000000000000e+00\nn = nan\n"


@pytest.mark.parametrize(
    "doc",
    [
        "a = 1\nb = 'x'\n[t]\nk = [1, [2, 3], {x = 1, y = {z = []}}]\n[[u]]\nq = 1979-05-27\n[[u]]\n[[u.v]]\n",
        'a.b.c = 1e5\n"k e y" = "\\u0001\\"\\\\"\n[x.y]\n[x.z]\n',
        "t = [{a = 1}, {b = 2}]\ne = []\nf = [[]]\n",
    ],
)
def test_round_trip(doc):
    j = tomlcodec.decode(doc)
    toml = tomlcodec.encode(j)
    assert tomlcodec.decode(toml) == j
    assert tomlcodec.encode(tomlcodec.decode(toml)) == toml
