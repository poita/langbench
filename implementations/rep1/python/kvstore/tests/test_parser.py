import pytest

from tessera import TesseraError, parse_command, parse_predicate, parse_value
from tessera.lexer import resolve_string, tokenize
from tessera.parser import Find, Put, Scan, Simple
from tessera.query import And, Cmp, Exists, Missing, Not, Or


def kind(line):
    with pytest.raises(TesseraError) as e:
        parse_command(line)
    return e.value.kind


def test_tokens_and_whitespace():
    assert [t.text for t in tokenize('  put\t"a"  [1,-2] ')] == ["put", "a", "[", "1", ",", "-2", "]"]
    assert [t.text for t in tokenize("a<=b<c")] == ["a", "<=", "b", "<", "c"]


@pytest.mark.parametrize("line", ["", "   ", "\t", "= 1", "-", 'put "a" 007', 'put "a" -0',
                                  'put "a" +1', 'put "a" "x', 'put "a" "\\q"', 'put "a" "\\u00zz"',
                                  'put "a" "tab\there"', "!", "put 1 2", "[1]"])
def test_syntax_errors(line):
    assert kind(line) == "syntax"


def test_stage_order():
    assert kind('frobnicate "\\ud800"') == "unknown-command"
    assert kind('put "\\ud800" 1') == "bad-utf8"
    assert kind('put "a" "\\ud800"') == "bad-utf8"
    assert kind('put "a" "\\u00zz"') == "syntax"          # lexing precedes surrogate resolution
    assert kind('get "a" "\\ud800"') == "syntax"          # leftover tokens are never resolved
    assert kind('put "a" 1 99999999999999999999') == "syntax"
    assert kind('put "a" 9223372036854775808') == "int-range"
    assert kind('put "" 99999999999999999999') == "bad-key"
    assert kind('put "' + "k" * 129 + '" 1') == "bad-key"
    assert kind('put "a" {x:1,x}') == "dup-field"
    assert kind('put "a" {x:1,x 2}') == "dup-field"
    assert kind('put "a" [1,]') == "syntax"
    assert kind("Put") == "unknown-command"


def test_string_escapes():
    assert resolve_string(r'a\"\\\/\b\f\n\r\té😀') == 'a"\\/\b\f\n\r\té😀'
    assert resolve_string(r"\u0000") == "\x00"
    for bad in [r"\ud800", r"\ud800x", r"\udc00", r"\ud800\ud800", r"\ud800A"]:
        with pytest.raises(TesseraError) as e:
            resolve_string(bad)
        assert e.value.kind == "bad-utf8"


def test_depth_rules():
    deep = "[" * 32
    parse_command('put "a" ' + deep + "]" * 32)
    for tail in ["1" + "]" * 32, "99999999999999999999", '"\\ud800"', ",", ")", ""]:
        assert kind('put "a" ' + deep + tail) == "depth"
    assert kind('put "a" ' + "[" * 30 + "{x:[[1]],x:1}") == "depth"
    assert kind('put "a" ' + "[" * 30 + "{x:1,x:[[1]]}") == "dup-field"
    assert kind('put "a" ' + deep + "-") == "syntax"
    assert kind('put "a" ' + "{a:" * 32 + "1") == "depth"


def test_path_limits():
    assert kind("create index a.b.c.d.e.f.g.h.i.") == "bad-path"
    assert kind("create index " + "x" * 31 + " .") == "bad-path"
    assert kind("create index " + "x" * 8 + ".y" * 3 + ".zzzzzzzzzzzzzzzzzzzzz.") == "bad-path"
    assert parse_command("create index a . b").segs == ("a", "b")
    assert kind("create index a.") == "syntax"


def test_scan_options():
    c = parse_command('scan from "b" to "d" limit 3 reverse keys')
    assert c == Scan(b"b", b"d", 3, True, True)
    assert parse_command('scan from ""').start == b""
    assert kind('scan limit 1 limit 2') == "syntax"
    assert kind('scan limit -1') == "syntax"
    assert kind('scan limit 2147483648') == "syntax"
    assert kind('scan limit 9223372036854775808') == "int-range"
    assert kind('scan reverse reverse') == "syntax"
    assert kind('scan foo') == "syntax"


def test_find_grammar():
    p = parse_command('find a == 1 or b == 2 and not(c > 3) limit 4')
    assert isinstance(p, Find) and p.limit == 4
    assert p.pred == Or(Cmp(("a",), "==", 1), And(Cmp(("b",), "==", 2), Not(Cmp(("c",), ">", 3))))
    assert parse_predicate("exists a.b") == Exists(("a", "b"))
    assert parse_predicate("missing a") == Missing(("a",))
    assert parse_predicate("exists == 1") == Cmp(("exists",), "==", 1)   # a field called exists
    assert parse_predicate("not == 1") == Cmp(("not",), "==", 1)
    assert parse_predicate('(a == null)') == Cmp(("a",), "==", None)
    assert kind("find a == 1 and") == "syntax"
    assert kind("find") == "syntax"
    assert kind("find a = 1") == "syntax"


def test_values():
    assert parse_value('{b: [1, "x", null], "a": true}') == {"b": [1, "x", None], "a": True}
    assert parse_command("begin") == Simple("begin")
    assert parse_command('put "k" {}') == Put(b"k", {})
