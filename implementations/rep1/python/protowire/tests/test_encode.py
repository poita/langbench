import pytest

from protowire import ProtowireError, encode


def enc(schema, name, text):
    return encode(schema, name, text).hex()


def test_spec_example(schema):
    assert enc(schema, "Outer", '{a: 1, b: "x", c: [1, 2], d: {v: -5}}') == "08011201781a02010222020809"


def test_defaults_vanish_but_empty_message_stays(schema):
    assert enc(schema, "Outer", "{d: {}, c: [], a: 0}") == "2200"
    assert enc(schema, "Outer", "{}") == ""


def test_field_order_and_widths(schema):
    assert enc(schema, "Kinds", "{u64: 18446744073709551615, i32: -1}") == "08" + "ff" * 9 + "01" + "20" + "ff" * 9 + "01"
    assert enc(schema, "Kinds", "{s64: -128}") == "30ff01"
    assert enc(schema, "Kinds", "{sf32: -1, f64: 1}") == "4dffffffff" + "51" + "0100000000000000"


def test_packed_repeated_keeps_defaults(schema):
    assert enc(schema, "Kinds", "{rb: [false, true]}") == "8201020001"
    assert enc(schema, "Kinds", "{rf: [1]}") == "7a0401000000"


def test_repeated_string_and_message(schema):
    assert enc(schema, "Kinds", '{rstr: ["a", ""], rin: [{}, {v: 1}]}') == "8a0101618a0100" "920100" "9201020802"


@pytest.mark.parametrize(
    "text",
    [
        "{a: -0}", "{a: 007}", "{a: +5}", "{a: 1.0}", "{a: 2147483648}", "{a: -2147483649}",
        "{a: true}", '{a: "1"}', "{a: {}}", "{a: [1]}", "{c: 1}", "{c: [1,]}", "{c: [[1]]}",
        "{a: 1, a: 2}", "{zz: 1}", "{a: 1,}", "{a: 1} x", "", " ", "{a 1}", "{a: - 1}",
        '{b: "x}', '{b: "\\q"}', '{b: "\\x4"}', '{b: "\\xc3"}', '{b: "\t"}', "{b: 1}", '{b: x"00"}',
        "{\ta: 1}", "{a: 1}\t", "{d: 1}",
    ],
)
def test_encode_errors(schema, text):
    with pytest.raises(ProtowireError):
        encode(schema, "Outer", text)


@pytest.mark.parametrize(
    "text",
    ["{a:1,c:[1,2]}", "  {  a  :  1  ,  c : [ 1 , 2 ] }  ", '{b:"x"}'],
)
def test_encode_whitespace_relaxations(schema, text):
    encode(schema, "Outer", text)


def test_string_escapes_and_raw(schema):
    assert enc(schema, "Outer", r'{b: "\xc3\xA9"}') == enc(schema, "Outer", '{b: "é"}') == "1202c3a9"
    assert enc(schema, "Outer", '{b: "\x7f"}') == "120" "17f"
    assert enc(schema, "Outer", r'{b: "\"\\\n\r\t"}') == "1205225c0a0d09"


def test_bytes_literals(schema):
    assert enc(schema, "Kinds", '{y: x"cafe"}') == "6a02cafe"
    assert enc(schema, "Kinds", '{y: x""}') == ""
    for bad in ('{y: x"CAFE"}', '{y: x"caf"}', '{y: "ca"}', '{y: x "ca"}'):
        with pytest.raises(ProtowireError):
            encode(schema, "Kinds", bad)


def test_unsigned_range(schema):
    with pytest.raises(ProtowireError):
        encode(schema, "Kinds", "{u64: 18446744073709551616}")
    with pytest.raises(ProtowireError):
        encode(schema, "Kinds", "{u32: -1}")
