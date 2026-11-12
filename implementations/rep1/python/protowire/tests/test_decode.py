import pytest

from protowire import ProtowireError, decode, parse_schema


def dec(schema, name, hexed):
    return decode(schema, name, bytes.fromhex(hexed))


def test_spec_example(schema):
    assert dec(schema, "Outer", "08011201781a02010222020809") == '{a: 1, b: "x", c: [1, 2], d: {v: -5}}'


def test_unknown_field_skipped(schema):
    assert dec(schema, "Outer", "3800") == "{}"


def test_truncated(schema):
    with pytest.raises(ProtowireError):
        dec(schema, "Outer", "08ff")


def test_wrong_wire_type_is_skipped(schema):
    # field 1 (int32) arriving as fixed32 is skipped, not an error
    assert dec(schema, "Outer", "0d01000000") == "{}"


def test_negative_int32_and_widths(schema):
    assert dec(schema, "Kinds", "08" + "ff" * 9 + "01") == "{i32: -1}"
    assert dec(schema, "Kinds", "10" + "ff" * 9 + "01") == "{i64: -1}"
    assert dec(schema, "Kinds", "4dffffffff") == "{sf32: -1}"
    assert dec(schema, "Kinds", "45ffffffff") == "{f32: 4294967295}"


def test_bool_nonzero_is_true(schema):
    assert dec(schema, "Kinds", "3802") == "{b: true}"


def test_packed_and_unpacked_mix(schema):
    # field 16 = repeated bool: packed [1, 0], then unpacked 1
    assert dec(schema, "Kinds", "8201020100" "8001" "01") == "{rb: [true, false, true]}"


def test_packed_fixed_partial_is_error(schema):
    with pytest.raises(ProtowireError):
        dec(schema, "Kinds", "7a03010203")


def test_packed_varint_cut_mid_varint(schema):
    with pytest.raises(ProtowireError):
        dec(schema, "Kinds", "72" "01" "80")


def test_empty_packed_contributes_nothing(schema):
    assert dec(schema, "Kinds", "7200") == "{}"


def test_string_must_be_utf8(schema):
    with pytest.raises(ProtowireError):
        dec(schema, "Outer", "1201ff")
    with pytest.raises(ProtowireError):
        dec(schema, "Outer", "1203eda080")  # surrogate


def test_string_utf8_passthrough(schema):
    assert dec(schema, "Outer", "1202c3a9") == '{b: "é"}'


def test_string_escape_table(schema):
    payload = '"\t\\\x00\x1f\x7fé\n\r'.encode()
    out = dec(schema, "Outer", "12" + format(len(payload), "02x") + payload.hex())
    assert out == '{b: "\\"\\t\\\\\\x00\\x1f\\x7fé\\n\\r"}'





def test_merge_exact(schema):
    # next twice: first has r=3, second has r=4 (append), and scalar replacement
    assert dec(schema, "Node", "12020803" "12020804") == "{next: {r: [3, 4]}}"
    assert dec(schema, "Node", "1203" "1a0161" "1203" "1a0162") == '{next: {s: "b"}}'


def test_empty_submessage_is_present(schema):
    assert dec(schema, "Node", "1200") == "{next: {}}"


def test_group_skipped_and_mismatch(schema):
    assert dec(schema, "Node", "1b08011c0805") == "{r: [5]}"
    with pytest.raises(ProtowireError):
        dec(schema, "Node", "1b08011400")
    with pytest.raises(ProtowireError):
        dec(schema, "Node", "1c")  # stray end-group
    with pytest.raises(ProtowireError):
        dec(schema, "Node", "1b0801")  # unterminated group


def test_length_exceeding_remaining(schema):
    with pytest.raises(ProtowireError):
        dec(schema, "Node", "1a05" "61")


def test_sublength_bounded_by_parent(schema):
    # inner claims 3 bytes but the enclosing sub-message only has 2
    with pytest.raises(ProtowireError):
        dec(schema, "Node", "1204" "1a03" "6161" "61")
