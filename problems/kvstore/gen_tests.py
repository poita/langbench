#!/usr/bin/env python3
"""Deterministic test generator for the kvstore problem (Tessera, SPEC.md).

Every case is a directory-mode case: ``<dir>/input/`` holds ``commands.txt``
and optionally ``main.tdb`` / ``main.twal``, and ``<dir>/expected/`` holds the
three files the program must write. Expected outputs come from the reference
implementation in ``reference/``, driven in process.

Cases are numbered from one shared sequence and then split: roughly one in four
goes to the public suite (``problems/kvstore/tests``) and the rest to the held-out
suite (``problems/kvstore/heldout``). The split is taken
within each feature area, so every area appears in both suites.

Run as ``python3 gen_tests.py`` from ``problems/kvstore/``; pass ``--list`` to
print the case table without writing anything.
"""

import argparse
import os
import random
import shutil
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REFDIR = os.path.join(HERE, "reference")
sys.path.insert(0, REFDIR)
sys.setrecursionlimit(100000)

import texec  # noqa: E402  (needs REFDIR on sys.path)
from tcrc import crc32  # noqa: E402
from tengine import Store  # noqa: E402

PUBLIC_DIR = os.path.join(HERE, "tests")
HIDDEN_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "heldout")

# One case in every PUBLIC_STRIDE, counted within a feature area, is public.
PUBLIC_STRIDE = 4


# --------------------------------------------------------------------------
# running the reference
# --------------------------------------------------------------------------

def run_ref(commands, tdb=None, twal=None):
    """Return (results text, main.tdb bytes, main.twal bytes) for one input."""
    store = Store()
    store.open(tdb, twal)
    lines = texec.run_script(store, commands)
    text = ("\n".join(lines) + "\n") if lines else ""
    return text, store.main_bytes(), store.wal_bytes()


def build(commands, tdb=None, twal=None):
    """Run a script only for the database and log it leaves behind."""
    _, out_tdb, out_twal = run_ref(commands, tdb, twal)
    return out_tdb, out_twal


# --------------------------------------------------------------------------
# the case registry
# --------------------------------------------------------------------------

CASES = []


def add(area, name, commands, tdb=None, twal=None, force_public=False):
    """Register one case. `commands` is the exact bytes of commands.txt."""
    CASES.append({"area": area, "name": name, "commands": commands,
                  "tdb": tdb, "twal": twal, "force_public": force_public})


def S(*lines):
    """A command file from one line per argument, each LF terminated."""
    return "".join(line + "\n" for line in lines)


# --------------------------------------------------------------------------
# small building blocks for scripts
# --------------------------------------------------------------------------

LIST20 = "[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20]"  # 185 bytes


def listdoc(n):
    """A list of the first n positive ints; serialises to 5 + 9n bytes."""
    return "[" + ",".join(str(i) for i in range(1, n + 1)) + "]"


def strdoc(n):
    """A string literal whose document serialises to exactly n bytes (n >= 5)."""
    return '"' + "z" * (n - 5) + '"'


def wide(i, width=128, prefix="k"):
    """A padded key of `width` bytes, ordered by i."""
    body = "%s%06d" % (prefix, i)
    return body + "x" * (width - len(body))


def put(key, doc):
    return 'put "%s" %s' % (key, doc)


# --------------------------------------------------------------------------
# area: the value model
# --------------------------------------------------------------------------

def area_value():
    add("value", "kinds", S(
        'put "n" null', 'put "t" true', 'put "f" false',
        'put "i" 42', 'put "neg" -42', 'put "s" "hello"',
        'put "l" [1,2,3]', 'put "o" {a:1,b:"two",c:[true,null]}',
        'get "n"', 'get "t"', 'get "f"', 'get "i"', 'get "neg"',
        'get "s"', 'get "l"', 'get "o"', 'scan', 'stat'))

    add("value", "int_extremes", S(
        'put "min" -9223372036854775808',
        'put "max" 9223372036854775807',
        'put "zero" 0', 'put "one" 1', 'put "mone" -1',
        'get "min"', 'get "max"', 'get "zero"', 'get "mone"',
        'put "over" 9223372036854775808',
        'put "under" -9223372036854775809',
        'put "far" 99999999999999999999999999',
        'scan', 'stat'))

    add("value", "escapes_in", S(
        r'put "esc" "a\"b\\c\/d\be\ff\ng\rh\ti"',
        'get "esc"',
        r'put "u" "\u0000\u001f\u007f\u0080é￿"',
        'get "u"',
        r'put "sur" "😀"',
        'get "sur"',
        r'put "hi" "😀"',
        'get "hi"',
        r'put "lone" "\ud800"',
        r'put "lone2" "\udc00"',
        r'put "lone3" "\ud800x"',
        r'put "lone4" "\ud83dA"',
        r'put "bad" "\u00zz"',
        r'put "bad2" "\q"',
        'scan keys'))

    add("value", "escapes_out", S(
        r'put "k" ["\u0000","\u0001","\u0007","\u0008","\u0009","\u000a"]',
        'get "k"',
        r'put "k2" ["\u000b","\u000c","\u000d","\u000e","\u001f","\u007f"]',
        'get "k2"',
        r'put "k3" " !/\\\""',
        'get "k3"',
        r'put "\u0000\u001f" 1',
        'scan keys', 'scan'))

    add("value", "unicode", S(
        'put "é" {"né":"ü",emoji:"\U0001F600"}',
        'get "é"',
        'put "中文" [1,"あ"]',
        'get "中文"',
        'scan', 'scan keys', 'stat'))

    add("value", "empty_containers", S(
        'put "a" []', 'put "b" {}', 'put "c" ""',
        'put "d" [[],{},""]', 'put "e" {x:[],y:{},z:""}',
        'get "a"', 'get "b"', 'get "c"', 'get "d"', 'get "e"',
        'scan', 'stat'))

    add("value", "field_order", S(
        'put "a" {z:1,a:2,m:3}', 'get "a"',
        'put "b" {"z":1,a:2}', 'get "b"',
        'put "c" {"b":1,"B":2,"ab":3,"a":4,"":5,"é":6,"z":7}', 'get "c"',
        'put "d" {a:1,a:2}', 'put "e" {"a":1,a:2}',
        'put "f" {a:1,}', 'put "g" [1,]', 'put "h" {,}',
        'put "i" {a}', 'put "j" {1:2}',
        'scan'))

    deep32 = "[" * 31 + "1" + "]" * 31
    deep33 = "[" * 32 + "1" + "]" * 32
    odeep32 = "{a:" * 31 + "1" + "}" * 31
    odeep33 = "{a:" * 32 + "1" + "}" * 32
    add("value", "depth", S(
        put("d32", deep32), 'get "d32"',
        put("d33", deep33),
        put("o32", odeep32),
        put("o33", odeep33),
        put("mix", "[" * 15 + "{a:" * 15 + "1" + "}" * 15 + "]" * 15),
        put("mix2", "[" * 16 + "{a:" * 16 + "1" + "}" * 16 + "]" * 16),
        'stat'))

    add("value", "doc_size_limits", S(
        put("ok", strdoc(65536)), 'stat',
        put("too", strdoc(65537)),
        put("ok2", strdoc(65535)), 'stat',
        'delete "ok"', 'delete "ok2"', 'stat'))

    add("value", "doc_max_get", S(
        put("a", strdoc(65536)), 'get "a"', 'stat'))

    add("value", "nested_mixed", S(
        'put "a" {users:[{name:"ada",tags:["x","y"]},{name:"bob",tags:[]}],n:2}',
        'get "a"',
        'put "b" [[1,2],[3,[4,[5,[6]]]],{}]', 'get "b"',
        'put "c" {"":{"":{"":null}}}', 'get "c"',
        'scan', 'stat'))

    add("value", "replace_kinds", S(
        'put "a" 1', 'get "a"', 'put "a" "one"', 'get "a"',
        'put "a" [1]', 'get "a"', 'put "a" {b:1}', 'get "a"',
        'put "a" null', 'get "a"', 'put "a" true', 'get "a"',
        'put "a" false', 'get "a"', 'stat'))


# --------------------------------------------------------------------------
# area: lexing and parsing
# --------------------------------------------------------------------------

def area_lex():
    add("lex", "basic_syntax", "put \"a\" 1\n\n   \n\t\n" + S(
        'put', 'put "a"', 'put "a" 1 2', 'PUT "a" 1', 'Put "a" 1',
        'frobnicate', 'frobnicate "x"', 'put 1 "x"', 'get', 'get "a" "b"',
        '1', '"a"', '{', '==', '.', 'stat'))

    add("lex", "strings_bad", S(
        'put "a 1',
        'put "a\\" 1',
        'put "a" "b',
        'put "a" "b\\q"',
        'put "a" "b\\u12"',
        'put "a" "b\\u12g4"',
        'put "a" "b\\u 123"',
        'put "a" "b\tc"',
        'put "a" "b\x01c"',
        'put "a" "b\\\\"',
        'get "a"',
        'put "b" "\\u0041\\u0042"',
        'get "b"'))

    add("lex", "operators", S(
        'put "a" {v:1}',
        'find v = 1', 'find v ! = 1', 'find v == 1', 'find v != 1',
        'find v <= 1', 'find v < = 1', 'find v >= 1', 'find v > = 1',
        'find v < 1', 'find v > 1', 'find v <> 1', 'find v =< 1',
        'put "a" +1', 'put "a" -', 'put "a" - 1', 'put "a" 1-', 'stat'))

    add("lex", "int_shapes", S(
        'put "a" 0', 'get "a"',
        'put "a" 00', 'put "a" 007', 'put "a" -0', 'put "a" -007',
        'put "a" 10000000000000000000', 'put "a" -10000000000000000000',
        'put "a" 0123456789',
        'scan limit 0', 'scan limit -1', 'scan limit 1',
        'scan limit 2147483647', 'scan limit 2147483648',
        'scan limit 9223372036854775807', 'scan limit 9223372036854775808',
        'scan limit -9223372036854775809'))

    add("lex", "command_words", S(
        'begin', 'commit', 'rollback', 'checkpoint', 'stat', 'indexes',
        'create', 'drop', 'create table a', 'drop table a',
        'create index', 'drop index', 'index a', 'puts "a" 1',
        'Begin', 'BEGIN', 'stats', 'sta', 'statt', 'scans', 'find',
        'scan extra', 'indexes 1', 'stat 1', 'begin 1'))

    add("lex", "scan_options", S(
        'put "a" 1', 'put "b" 2', 'put "c" 3',
        'scan from "a" from "b"', 'scan to "a" to "b"',
        'scan limit 1 limit 2', 'scan reverse reverse', 'scan keys keys',
        'scan keys reverse limit 2 from "a" to "c"',
        'scan to "c" from "a" limit 2 reverse keys',
        'scan from', 'scan to', 'scan limit', 'scan reverse keys',
        'scan from 1', 'scan limit "x"', 'scan reverse 1', 'scan keys extra'))

    add("lex", "paths", S(
        'put "a" {b:{c:{d:{e:{f:{g:{h:1}}}}}}}',
        'update "a" b.c.d.e.f.g.h 2',
        'update "a" b.c.d.e.f.g.h.i 2',
        'update "a" a.b.c.d.e.f.g.h.i. 2',
        'update "a" b . c 3',
        'get "a"',
        'create index aaaaaaaaaa.bbbbbbbbbb.cccccccc',
        'create index aaaaaaaaaa.bbbbbbbbbb.ccccccccc',
        'create index aaaaaaaaaa.bbbbbbbbbb.cccccccccc',
        'create index a.',
        'create index .a',
        'create index a..b',
        'create index 1a',
        'create index "a"',
        'create index null',
        'create index and',
        'indexes'), force_public=True)

    add("lex", "keys_limits", S(
        'put "" 1',
        put("k" * 128, "1"),
        put("k" * 129, "1"),
        'get ""', 'delete ""', 'update "" a 1', 'unset "" a',
        'get "%s"' % ("k" * 129),
        put("é" * 64, "1"),
        put("é" * 65, "1"),
        'scan from ""', 'scan to ""',
        'scan from "%s"' % ("z" * 200),
        'scan keys', 'stat'))

    add("lex", "stage_order", S(
        r'frobnicate "\ud800"',
        r'put "\ud800" 1',
        'put 1 "x"',
        'put "a" {x:1,x:2}',
        r'put "\ud800" {x:1,x:2}',
        'put "a" {x:9223372036854775808,x:2}',
        'put "" {x:1,x:2}',
        r'put "" "\ud800"',
        'put "a" [1,2 3]',
        'put "a" ' + "[" * 32 + "1" + "]" * 32,
        r'put "a" ["\ud800",' + "[" * 32 + "1" + "]" * 32 + "]",
        'update "a" b 1',
        'update "%s" b 1' % ("k" * 129),
        'unset "" b.c.d.e.f.g.h.i',
        'stat'))

    add("lex", "whitespace", "  put   \"a\"    1  \n\tget\t\"a\"\t\n" + S(
        'put "b" [ 1 , 2 , { a : 1 } ]', 'get "b"',
        'scan   keys   reverse  ',
        'find  a  ==  1  limit  1 ',
        '   ', '\t\t', ''))

    add("lex", "no_trailing_newline", 'put "a" 1\nstat')

    add("lex", "empty_file", "")

    add("lex", "only_newline", "\n")

    add("lex", "trailing_blank", 'put "a" 1\n\n')

    add("lex", "word_positions", S(
        'put "a" {null:1,true:2,and:3,or:4,not:5,exists:6,missing:7,limit:8}',
        'get "a"',
        'update "a" null 9', 'update "a" and 10', 'get "a"',
        'put "b" {x:null}', 'put "c" {x:nul}', 'put "d" {x:True}',
        'put "e" {x:TRUE}',
        'find null == 9', 'find and == 10', 'find exists == 6',
        'find missing == 7', 'find not == 5',
        'find exists null', 'find missing null', 'find not(null == 9)',
        'stat'))

    add("lex", "punct_tokens", S(
        'put "a" (1)', 'put "a" [1):', 'put "a" {a:1]',
        'put "a" ]', 'put "a" }', 'put "a" )', 'put "a" ,',
        'put "a" :', 'put "a" .', 'put "a" [,]',
        'find (a == 1)', 'find ((a == 1))', 'find (a == 1', 'find a == 1)',
        'find not a == 1', 'find not(a == 1)', 'find not (a == 1)',
        'stat'))

    # Depth is raised the moment a value at level 33 is about to be read,
    # whatever token sits there; path limits are checked from the first
    # segment on; a leftover token is never resolved (§6.3, §6.4, §18.2).
    a31, a30, a29 = "a" * 31, "a" * 30, "a" * 29
    add("lex", "parse_stage_a", S(
        'put "k" {b:1}',
        'put "a" ' + "[" * 32 + ",",
        'put "a" ' + "[" * 32 + "99999999999999999999" + "]" * 32,
        'put "a" ' + "[" * 30 + "{x:[[1]],x:1}" + "]" * 30,
        'put "a" ' + "[" * 30 + "{x:1,x:[[1]]}" + "]" * 30,
        'put "a" ' + "[" * 32 + "]" * 32, 'get "a"',
        'create index ' + a31 + '.',
        'create index ' + a30 + '.',
        'update "k" ' + a31 + '. 1',
        'find ' + a31 + '.',
        'get "k" "\\ud800"',
        'stat'))
    add("lex", "parse_stage_b", S(
        'put "k" {b:1}',
        'put "a" ' + "[" * 32,
        'put "a" ' + "[" * 32 + '"\\ud800"' + "]" * 32,
        'put "a" ' + "[" * 31 + "{}" + "]" * 31, 'get "a"',
        'put "a" ' + "[" * 31 + "{x:" + ")",
        'find a == ' + "[" * 32 + ")",
        'find a == ' + "[" * 32 + "]" * 32,
        'unset "k" ' + a31 + '..',
        'find exists ' + a31 + '.',
        'create index ' + a29 + '.b',
        'create index ' + a31,
        'put "a" 1 99999999999999999999',
        'stat'))
    add("lex", "parse_stage_c", S(
        'put "k" {b:1}',
        'update "k" b ' + "[" * 32 + "-",
        'update "k" b ' + "{x:" * 32 + "{x:1,x:2}" + "}" * 32,
        'put "a" ' + "[" * 31 + "[1,2," + "]",
        'find ' + a31 + ' .b == 1',
        'drop index ' + a31 + ' .',
        'update "k" ' + a31 + ' {',
        'stat "\\udc00"',
        'scan keys "\\ud800"',
        'stat'))


# --------------------------------------------------------------------------
# area: scan
# --------------------------------------------------------------------------

def area_scan():
    base = [put(k, str(i + 1)) for i, k in enumerate("abcd")]

    add("scan", "ranges", S(*(base + [
        'scan', 'scan from "b"', 'scan to "c"', 'scan from "b" to "d"',
        'scan limit 2', 'scan reverse limit 2', 'scan keys reverse',
        'scan from "d" to "b"', 'scan from "a" to "a"',
        'scan limit 0', 'scan keys limit 1', 'scan from "" to "zz"'])))

    add("scan", "empty_store", S(
        'scan', 'scan keys', 'scan reverse', 'scan limit 5',
        'scan from "a" to "z"', 'stat'))

    add("scan", "bounds_bytewise", S(
        'put "a" 1', 'put "ab" 2', 'put "b" 3', 'put "A" 4', 'put "Z" 5',
        'put "\u0000" 6', 'put "~" 7', 'put "ÿ" 8',
        'scan keys',
        'scan from "A" to "b" keys',
        'scan from "a" to "ab" keys',
        'scan from "aa" keys',
        'scan from "\u0000" keys limit 3',
        'scan reverse keys limit 3',
        'scan from "ÿ" keys',
        'scan to "\u0000" keys'))

    add("scan", "unicode_order", S(
        'put "z" 1', 'put "é" 2', 'put "中" 3', 'put "\U0001F600" 4',
        'put "a" 5',
        'scan keys', 'scan reverse keys',
        'scan from "é" keys', 'scan to "中" keys'))

    add("scan", "many_pages", S(*(
        [put("k%04d" % i, listdoc(20)) for i in range(40)] +
        ['scan keys', 'scan keys reverse', 'scan keys limit 7',
         'scan keys reverse limit 7', 'scan keys from "k0010" to "k0020"',
         'scan limit 2', 'stat'])))

    add("scan", "long_keys", S(*(
        [put(wide(i), str(i)) for i in range(25)] +
        ['scan keys', 'scan keys reverse limit 5',
         'scan keys from "%s"' % wide(10), 'stat'])))

    add("scan", "overflow_values", S(*(
        [put("k%d" % i, strdoc(200 + 500 * i)) for i in range(5)] +
        ['scan keys', 'scan keys reverse', 'stat'])))

    add("scan", "inside_txn", S(
        'put "a" 1', 'begin', 'put "b" 2', 'delete "a"',
        'scan', 'scan keys reverse', 'rollback', 'scan', 'stat'))

    add("scan", "limit_interactions", S(*(
        [put("k%02d" % i, str(i)) for i in range(12)] +
        ['scan limit 3', 'scan reverse limit 3',
         'scan from "k03" limit 3', 'scan from "k03" reverse limit 3',
         'scan to "k05" reverse limit 2', 'scan keys limit 100',
         'scan limit 2147483647'])))

    add("scan", "bound_over_maxkey", S(
        'put "a" 1', 'put "%s" 2' % ("b" * 128),
        'scan from "%s"' % ("b" * 200),
        'scan to "%s"' % ("b" * 200),
        'scan from "%s" keys' % ("b" * 128),
        'scan keys'))

    add("scan", "after_deletes", S(*(
        [put("k%02d" % i, listdoc(20)) for i in range(20)] +
        ['delete "k%02d"' % i for i in range(0, 20, 2)] +
        ['scan keys', 'scan keys reverse', 'stat'])))

    add("scan", "single_doc", S(
        'put "only" {a:1}', 'scan', 'scan keys', 'scan reverse',
        'scan from "only"', 'scan to "only"', 'scan limit 1', 'stat'))


# --------------------------------------------------------------------------
# area: update and unset
# --------------------------------------------------------------------------

def area_update():
    add("update", "basic", S(
        'put "u1" {name:"ada"}',
        'update "u1" age 36',
        'update "u1" addr.city "oslo"',
        'get "u1"',
        'unset "u1" addr.city',
        'get "u1"',
        'unset "u1" addr.zip',
        'unset "u1" name.first',
        'update "u2" age 1',
        'stat'))

    add("update", "autovivify", S(
        'put "a" {}',
        'update "a" b.c.d.e 1', 'get "a"',
        'update "a" b.c.d.f 2', 'get "a"',
        'update "a" b.c 3', 'get "a"',
        'update "a" b.c.d 4',
        'get "a"', 'stat'))

    add("update", "not_object", S(
        'put "a" 1', 'update "a" b 2',
        'put "b" "s"', 'update "b" x.y 1',
        'put "c" [1]', 'update "c" x 1',
        'put "d" {x:1}', 'update "d" x.y 1', 'update "d" y 2', 'get "d"',
        'put "e" null', 'update "e" x 1',
        'put "f" true', 'update "f" x 1',
        'scan', 'stat'))

    add("update", "unset_errors", S(
        'put "a" {x:{y:1},z:2}',
        'unset "a" q', 'unset "a" x.q', 'unset "a" z.q', 'unset "a" x.y.q',
        'unset "a" x.y', 'get "a"',
        'unset "a" x', 'get "a"',
        'unset "a" z', 'get "a"',
        'unset "b" x',
        'put "c" 1', 'unset "c" x',
        'stat'))

    add("update", "root_replace", S(
        'put "a" {x:1}', 'update "a" x 2', 'get "a"',
        'update "a" x [1,2,3]', 'get "a"',
        'update "a" x {y:{z:1}}', 'get "a"',
        'unset "a" x', 'get "a"',
        'update "a" x null', 'get "a"', 'stat'))

    add("update", "depth_limit", S(
        'put "a" {b:' + "{c:" * 28 + "1" + "}" * 28 + "}",
        'update "a" b ' + "{c:" * 29 + "1" + "}" * 29,
        'update "a" b ' + "{c:" * 30 + "1" + "}" * 30,
        'update "a" b.c.d.e.f.g.h ' + "[" * 24 + "1" + "]" * 24,
        'update "a" b.c.d.e.f.g.h ' + "[" * 25 + "1" + "]" * 25,
        'stat'))

    add("update", "size_limit", S(
        put("a", "{b:%s}" % strdoc(65000)),
        'stat',
        'update "a" c ' + strdoc(400),
        'stat',
        'update "a" c ' + strdoc(600),
        'stat'))

    add("update", "overflow_transitions", S(
        'put "a" {x:1}', 'stat',
        'update "a" y ' + strdoc(400), 'stat',
        'update "a" y 2', 'stat',
        'update "a" y ' + strdoc(3000), 'stat',
        'unset "a" y', 'stat', 'get "a"'))

    add("update", "unset_last_field", S(
        'put "a" {only:1}', 'unset "a" only', 'get "a"',
        'update "a" only 2', 'get "a"',
        'put "b" {x:{y:{z:1}}}', 'unset "b" x.y.z', 'get "b"',
        'unset "b" x.y', 'get "b"', 'unset "b" x', 'get "b"', 'stat'))

    add("update", "path_segments_max", S(
        'put "a" {}',
        'update "a" b.c.d.e.f.g.h 1', 'get "a"',
        'unset "a" b.c.d.e.f.g.h', 'get "a"',
        'update "a" bb.cc.dd.ee.ff.gg.hh 1',
        'update "a" bbb.ccc.ddd.eee.fff.ggg.hhh 1',
        'update "a" bbbb.cccc.dddd.eeee.ffff.gggg.hhhh 1',
        'stat'))

    add("update", "mass_updates", S(*(
        [put("k%02d" % i, "{v:%d}" % i) for i in range(25)] +
        ['update "k%02d" v %d' % (i, i * 100) for i in range(25)] +
        ['update "k%02d" extra %s' % (i, listdoc(20)) for i in range(0, 25, 3)] +
        ['unset "k%02d" extra' % i for i in range(0, 25, 3)] +
        ['scan limit 4', 'stat'])))

    add("update", "txn_update", S(
        'put "a" {v:1}', 'begin', 'update "a" v 2', 'get "a"',
        'unset "a" v', 'get "a"', 'rollback', 'get "a"',
        'begin', 'update "a" v 3', 'commit', 'get "a"', 'stat'))


# --------------------------------------------------------------------------
# area: find and predicates
# --------------------------------------------------------------------------

PEOPLE = [
    ('u1', '{name:"ada",age:36,ok:true}'),
    ('u2', '{name:"bob",age:29,ok:false}'),
    ('u3', '{name:"cy",age:36,ok:true}'),
    ('u4', '{name:"dee",age:null}'),
    ('u5', '{name:"eve",age:[1,2]}'),
    ('u6', '{name:"fay",age:{x:1}}'),
    ('u7', '{name:"gus"}'),
    ('u8', '{name:"hal",age:-5}'),
    ('u9', '{name:"ivy",age:"36"}'),
]


def people_lines():
    return [put(k, v) for k, v in PEOPLE]


def area_find():
    add("find", "worked_example", S(
        'put "u1" {name:"ada",age:36}',
        'put "u2" {name:"bob",age:29}',
        'put "u3" {name:"cy",age:36}',
        'create index age',
        'indexes',
        'find age == 36',
        'find age > 30',
        'find age == 36 and name == "cy"',
        'find not(age == 36)',
        'stat'))

    add("find", "operators_scan", S(*(people_lines() + [
        'find age == 36', 'find age != 36', 'find age < 36',
        'find age <= 36', 'find age > 36', 'find age >= 36',
        'find age == null', 'find age != null',
        'find age < null', 'find age >= null',
        'find age == [1,2]', 'find age == {x:1}',
        'find age < "36"', 'find age == "36"',
        'find ok == true', 'find ok < true', 'find ok >= false',
        'find exists age', 'find missing age',
        'find exists age.x', 'find missing age.x'])))

    add("find", "operators_index", S(*(people_lines() + [
        'create index age',
        'find age == 36', 'find age != 36', 'find age < 36',
        'find age <= 36', 'find age > 36', 'find age >= 36',
        'find age == null', 'find age >= null', 'find age < null',
        'find age == "36"', 'find age < "36"', 'find age > "36"',
        'find age == [1,2]', 'find exists age', 'find missing age',
        'indexes', 'stat'])))

    add("find", "boolean_logic", S(*(people_lines() + [
        'find age == 36 and name == "cy"',
        'find age == 36 or age == 29',
        'find age == 36 or age == 29 and name == "bob"',
        'find (age == 36 or age == 29) and name == "bob"',
        'find not(age == 36) and exists age',
        'find not(exists age)',
        'find not(not(age == 36))',
        'find exists name and exists age and age > 0',
        'find age > 0 and age < 40 or name == "gus"',
        'find missing age or age == null'])))

    add("find", "limit", S(*(people_lines() + [
        'find exists name limit 0',
        'find exists name limit 1',
        'find exists name limit 3',
        'find exists name limit 100',
        'find exists name limit 2147483647',
        'find exists name limit -1',
        'find exists name limit',
        'find exists name 3',
        'find limit 1'])))

    add("find", "plan_choice", S(*(people_lines() + [
        'create index age', 'create index name',
        'find age == 36 and name == "cy"',
        'find name == "cy" and age == 36',
        'find age > 30 and name == "cy"',
        'find age == 36 and name > "a"',
        'find age > 30 and name > "a"',
        'find name > "a" and age > 30',
        'find age != 36 and name != "cy"',
        'find age == [1,2] and name == "cy"',
        'find age == 36 or name == "cy"',
        'find not(age == 36) and name == "cy"',
        'find exists age and name == "cy"',
        'indexes'])))

    add("find", "plan_ties", S(*(people_lines() + [
        'create index age', 'create index ok', 'create index name',
        'find age == 36 and ok == true',
        'find ok == true and age == 36',
        'find age > 1 and ok > false',
        'find ok > false and age > 1',
        'find name == "ada" and age == 36 and ok == true',
        'find age == 36 and age == 29',
        'find age > 1 and age > 2',
        'find missing zz and age == 36',
        'indexes', 'stat'])))

    add("find", "nested_paths", S(
        'put "a" {u:{v:1},t:"x"}',
        'put "b" {u:{v:2},t:"y"}',
        'put "c" {u:3}',
        'put "d" {u:{w:1}}',
        'create index u.v',
        'find u.v == 1', 'find u.v > 0', 'find u.v == 3',
        'find exists u.v', 'find missing u.v',
        'find u == 3', 'find u.v.w == 1',
        'indexes', 'stat'))

    add("find", "string_compare", S(
        'put "a" {s:""}', 'put "b" {s:"a"}', 'put "c" {s:"ab"}',
        'put "d" {s:"b"}', 'put "e" {s:"A"}', 'put "f" {s:"é"}',
        'put "g" {s:"\u0000"}',
        'find s > ""', 'find s < "b"', 'find s >= "a"', 'find s <= "ab"',
        'find s == "é"', 'find s == "\u0000"',
        'create index s',
        'find s > ""', 'find s < "b"', 'find s >= "a"', 'find s <= "ab"',
        'find s == "é"', 'find s == "\u0000"', 'stat'))

    add("find", "deep_equality", S(
        'put "a" {v:[1,[2,{x:3}]]}',
        'put "b" {v:[1,[2,{x:4}]]}',
        'put "c" {v:{x:1,y:2}}',
        'put "d" {v:{y:2,x:1}}',
        'find v == [1,[2,{x:3}]]',
        'find v == {x:1,y:2}',
        'find v == {y:2,x:1}',
        'find v != {x:1,y:2}',
        'find v == [1,[2,{x:3}],4]',
        'find v < [1]', 'find v > {}',
        'stat'))

    add("find", "type_ranks", S(
        'put "a" {v:null}', 'put "b" {v:false}', 'put "c" {v:true}',
        'put "d" {v:-1}', 'put "e" {v:0}', 'put "f" {v:1}',
        'put "g" {v:""}', 'put "h" {v:"z"}', 'put "i" {v:[]}',
        'put "j" {v:{}}',
        'find v >= null', 'find v <= null',
        'find v > false', 'find v < true',
        'find v >= -1', 'find v <= 1',
        'find v >= ""', 'find v < "z"',
        'create index v',
        'find v >= null', 'find v > false', 'find v >= -1',
        'find v >= ""', 'find v < "z"', 'find v == null',
        'indexes', 'stat'))

    add("find", "empty_and_errors", S(
        'find exists a',
        'find a == 1',
        'put "x" {a:1}',
        'find a ==',
        'find a == 1 and',
        'find a == 1 or',
        'find and a == 1',
        'find a',
        'find',
        'find exists',
        'find missing',
        'find not',
        'find not a',
        'find exists a.b.c.d.e.f.g.h.i',
        'find a == {x:1,x:2}',
        'find a == 9223372036854775808',
        'find exists a limit 1 extra',
        'stat'))

    add("find", "many_docs", S(*(
        [put("k%03d" % i, '{m:%d,s:"s%03d"}' % (i % 7, i)) for i in range(60)] +
        ['create index m',
         'find m == 3', 'find m > 3', 'find m <= 1 limit 5',
         'find m == 3 and s > "s030"',
         'create index s',
         'find s == "s042"', 'find s >= "s055"',
         'find m == 3 and s == "s003"',
         'indexes', 'stat'])))

    add("find", "index_after_writes", S(*(
        [put("k%02d" % i, '{v:%d}' % i) for i in range(10)] +
        ['create index v',
         'put "k03" {v:100}', 'find v == 100', 'find v == 3',
         'update "k04" v 101', 'find v == 101',
         'unset "k05" v', 'find exists v', 'find v >= 0',
         'delete "k06"', 'find v >= 0',
         'put "k20" {v:5}', 'find v == 5',
         'indexes', 'stat'])))


# --------------------------------------------------------------------------
# area: the primary tree, splits
# --------------------------------------------------------------------------

def area_split():
    add("split", "worked_example", S(*(
        [put("k%d" % i, LIST20) for i in range(1, 7)] +
        ['stat', 'scan keys'] +
        ['delete "k1"', 'delete "k2"', 'delete "k3"'] +
        ['stat', 'scan keys'])))

    add("split", "thin_after_replace", S(*(
        [put("k%d" % i, LIST20) for i in range(1, 7)] +
        ['put "k1" 1', 'put "k2" 2', 'stat', 'delete "k3"', 'stat',
         'scan keys'])))

    # A cell on a primary leaf costs 14 + key_len + inline_len, so fixing the
    # document's inline size fixes how many cells a page holds, and with it the
    # arity every split runs at.
    for inline in (1, 5, 15, 30, 60, 120, 192):
        doc = "null" if inline == 1 else strdoc(inline)
        per = 1008 // (18 + inline)
        add("split", "arity_inline%03d" % inline, S(*(
            [put("k%03d" % i, doc) for i in range(per * 3 + 2)] +
            ['stat', 'scan keys limit 4', 'scan keys reverse limit 4'])))

    for inline in (1, 50, 100, 192):
        doc = "null" if inline == 1 else strdoc(inline)
        per = 1008 // (142 + inline)
        add("split", "wide_inline%03d" % inline, S(*(
            [put(wide(i, 128), doc) for i in range(per * 12 + 3)] +
            ['stat', 'scan keys limit 3', 'scan keys reverse limit 3'])))

    add("split", "ascending", S(*(
        [put("k%04d" % i, listdoc(20)) for i in range(120)] +
        ['stat', 'scan keys limit 3', 'scan keys reverse limit 3'])))

    add("split", "descending", S(*(
        [put("k%04d" % i, listdoc(20)) for i in range(119, -1, -1)] +
        ['stat', 'scan keys limit 3', 'scan keys reverse limit 3'])))

    add("split", "interleaved", S(*(
        [put("k%04d" % (i * 37 % 120), listdoc(20)) for i in range(120)] +
        ['stat', 'scan keys limit 3'])))

    add("split", "height_growth", S(*(
        [put(wide(i), str(i)) for i in range(300)] +
        ['stat', 'scan keys limit 2', 'scan keys reverse limit 2'])))

    add("split", "height5", S(*(
        [put(wide(i), "1") for i in range(700)] +
        ['stat', 'scan keys limit 2', 'scan keys reverse limit 2',
         'get "%s"' % wide(350)])), force_public=True)

    add("split", "height6", S(*(
        [put(wide(i), "1") for i in range(2400)] +
        ['stat', 'scan keys limit 2', 'scan keys reverse limit 2',
         'get "%s"' % wide(1200), 'checkpoint', 'stat'])))

    add("split", "mixed_sizes", S(*(
        [put("k%03d" % i, strdoc(20 + (i * 53) % 300)) for i in range(80)] +
        ['stat', 'scan keys limit 3'])))

    add("split", "cascading", S(*(
        [put(wide(i, 128), LIST20) for i in range(150)] +
        ['stat', 'scan keys limit 2'])))

    add("split", "replace_grows_cell", S(*(
        [put("k%02d" % i, "1") for i in range(30)] +
        ['stat'] +
        [put("k%02d" % i, LIST20) for i in range(30)] +
        ['stat', 'scan keys limit 3'])))

    add("split", "max_cell_cost", S(*(
        [put(wide(i, 128), strdoc(192)) for i in range(20)] +
        ['stat', 'scan keys limit 2', 'get "%s"' % wide(0, 128)])))


# --------------------------------------------------------------------------
# area: deletion and rebalancing
# --------------------------------------------------------------------------

def area_delete():
    add("delete", "empty_root", S(
        'put "k1" "x"', 'put "k2" "y"', 'delete "k1"', 'delete "k2"',
        'stat', 'put "k3" "z"', 'stat'))

    add("delete", "not_found", S(
        'put "a" 1', 'delete "b"', 'delete "a"', 'delete "a"',
        'get "a"', 'stat'))

    def wipe(order, n, doc, keyfn=lambda i: "k%03d" % i, extra=()):
        lines = [put(keyfn(i), doc) for i in range(n)]
        lines.append('stat')
        lines += ['delete "%s"' % keyfn(i) for i in order]
        lines.append('stat')
        lines.append('scan keys limit 4')
        lines += list(extra)
        return S(*lines)

    n = 60
    add("delete", "forward", wipe(range(n), n, listdoc(20)))
    add("delete", "backward", wipe(range(n - 1, -1, -1), n, listdoc(20)))
    rnd = random.Random(90210)
    order = list(range(n))
    rnd.shuffle(order)
    add("delete", "random_order", wipe(order, n, listdoc(20)))
    middle = sorted(range(n), key=lambda i: abs(i - n // 2))
    add("delete", "from_middle", wipe(middle, n, listdoc(20)))

    add("delete", "half_forward", wipe(range(0, n, 2), n, listdoc(20)))
    add("delete", "half_backward", wipe(range(n - 1, 0, -2), n, listdoc(20)))

    add("delete", "deep_forward",
        wipe(range(200), 200, "1", keyfn=lambda i: wide(i, 128)))
    add("delete", "deep_backward",
        wipe(range(199, -1, -1), 200, "1", keyfn=lambda i: wide(i, 128)))
    order2 = list(range(200))
    random.Random(4711).shuffle(order2)
    add("delete", "deep_random",
        wipe(order2, 200, "1", keyfn=lambda i: wide(i, 128)))
    add("delete", "deep_middle",
        wipe(sorted(range(200), key=lambda i: abs(i - 100)), 200, "1",
             keyfn=lambda i: wide(i, 128)))

    add("delete", "borrow_left", S(*(
        [put("k%02d" % i, listdoc(20)) for i in range(11)] +
        ['stat', 'scan keys'] +
        ['delete "k%02d"' % i for i in (10, 9, 8)] +
        ['stat', 'scan keys'])))

    add("delete", "merge_then_borrow", S(*(
        [put("k%02d" % i, listdoc(20)) for i in range(16)] +
        ['stat'] +
        ['delete "k%02d"' % i for i in (5, 6, 7, 4, 3, 12, 13)] +
        ['stat', 'scan keys'])))

    add("delete", "root_collapse_twice", S(*(
        [put("k%03d" % i, listdoc(20)) for i in range(40)] +
        ['stat'] +
        ['delete "k%03d"' % i for i in range(38)] +
        ['stat', 'scan keys'])))

    add("delete", "replace_then_delete", S(*(
        [put("k%02d" % i, listdoc(20)) for i in range(20)] +
        [put("k%02d" % i, "1") for i in range(0, 20, 3)] +
        ['stat'] +
        ['delete "k%02d"' % i for i in range(1, 20, 2)] +
        ['stat', 'scan keys'])))

    add("delete", "interior_rebalance", S(*(
        [put(wide(i, 128), LIST20) for i in range(120)] +
        ['stat'] +
        ['delete "%s"' % wide(i, 128) for i in range(30, 90)] +
        ['stat', 'scan keys limit 3', 'scan keys reverse limit 3'])))

    add("delete", "height5_wipe", S(*(
        [put(wide(i), "1") for i in range(700)] +
        ['stat'] +
        ['delete "%s"' % wide(i) for i in range(100, 600)] +
        ['stat', 'scan keys limit 3', 'scan keys reverse limit 3'])),
        force_public=True)

    add("delete", "height5_wipe_all", S(*(
        [put(wide(i), "1") for i in range(650)] +
        ['delete "%s"' % wide(i) for i in range(649, -1, -1)] +
        ['stat'] +
        [put("k%02d" % i, "1") for i in range(10)] +
        ['stat', 'scan keys'])))

    add("delete", "delete_all_then_rebuild", S(*(
        [put("k%03d" % i, listdoc(20)) for i in range(50)] +
        ['delete "k%03d"' % i for i in range(50)] +
        ['stat'] +
        [put("k%03d" % i, "1") for i in range(50)] +
        ['stat', 'scan keys limit 3'])))

    # A leaf borrow replaces the parent's separator with a longer key. With a
    # nearly full parent of short separators that overflows the parent, which
    # then splits (§12.5). `n` ascending keys leave three cells per leaf, so
    # leaf `i` holds keys 3i .. 3i+2 and its separator is key 3i+2.
    def parent_grows(n, i, side):
        k = lambda j: "a%03d" % j
        lines = [put(k(j), LIST20) for j in range(n)] + ['stat']
        a, b, c = 3 * i, 3 * i + 1, 3 * i + 2
        if side == "left":
            lines += [put(k(b) + ch * 124, "1") for ch in "yz"]
            lines += ['delete "%s"' % k(x) for x in (c, c + 1, c + 2)]
        else:
            lines += [put(k(c) + "z" * 124, "1"),
                      'delete "%s"' % k(a - 3)]
            lines += ['delete "%s"' % k(x) for x in (a, b)]
        lines += ['stat', 'scan keys from "%s" to "%s"' % (k(a - 3), k(c + 6)),
                  'scan keys reverse limit 4', 'delete "%s"' % k(n - 1),
                  'stat']
        return S(*lines)

    add("delete", "borrow_left_splits_parent", parent_grows(360, 83, "left"))
    add("delete", "borrow_right_splits_parent", parent_grows(360, 84, "right"))
    add("delete", "borrow_left_splits_root", parent_grows(240, 40, "left"))
    add("delete", "borrow_right_splits_root", parent_grows(240, 41, "right"))


# --------------------------------------------------------------------------
# area: overflow chains
# --------------------------------------------------------------------------

def area_overflow():
    add("overflow", "worked_example", S(
        put("big", listdoc(25)), 'stat', 'get "big"', 'delete "big"', 'stat'))

    add("overflow", "boundaries", S(
        put("a", strdoc(192)), 'stat',
        put("b", strdoc(193)), 'stat',
        put("c", strdoc(1204)), 'stat',
        put("d", strdoc(1205)), 'stat',
        'scan keys', 'stat'))

    add("overflow", "grow_shrink", S(
        put("a", strdoc(200)), 'stat',
        put("a", strdoc(2000)), 'stat',
        put("a", strdoc(5000)), 'stat',
        put("a", strdoc(1500)), 'stat',
        put("a", strdoc(100)), 'stat',
        put("a", strdoc(192)), 'stat',
        'delete "a"', 'stat'))

    add("overflow", "same_doc_replace", S(
        put("a", strdoc(2005)), 'stat',
        put("a", strdoc(2005)), 'stat',
        put("a", strdoc(2005)), 'stat',
        'scan keys', 'stat'))

    add("overflow", "long_chain", S(
        put("a", strdoc(65536)), 'stat',
        put("a", strdoc(33000)), 'stat',
        put("a", strdoc(65536)), 'stat',
        'delete "a"', 'stat'))

    add("overflow", "chain_lengths", S(*(
        [put("k%02d" % i, strdoc(192 + 1012 * i)) for i in range(1, 9)] +
        ['stat'] +
        ['delete "k%02d"' % i for i in range(1, 9, 2)] +
        ['stat', 'scan keys'])))

    add("overflow", "many_big_docs", S(*(
        [put("k%02d" % i, strdoc(3000 + 97 * i)) for i in range(24)] +
        ['stat', 'scan keys'] +
        ['delete "k%02d"' % i for i in range(0, 24, 2)] +
        ['stat'] +
        [put("k%02d" % i, strdoc(1500)) for i in range(1, 24, 2)] +
        ['stat'])))

    add("overflow", "reuse_as_split_sibling", S(*(
        [put("b%02d" % i, strdoc(4000)) for i in range(6)] +
        ['stat'] +
        ['delete "b%02d"' % i for i in range(6)] +
        ['stat'] +
        [put("k%02d" % i, listdoc(20)) for i in range(14)] +
        ['stat', 'scan keys'])))

    add("overflow", "in_txn", S(
        'begin', put("a", strdoc(4000)), 'stat', 'rollback', 'stat',
        'begin', put("a", strdoc(4000)), put("a", strdoc(2000)),
        'delete "a"', 'stat', 'commit', 'stat'))

    add("overflow", "update_into_overflow", S(
        'put "a" {x:1}', 'stat',
        'update "a" y ' + strdoc(2500), 'stat',
        'update "a" y ' + strdoc(5000), 'stat',
        'unset "a" y', 'stat', 'get "a"',
        'update "a" z ' + strdoc(900), 'stat', 'delete "a"', 'stat'))

    add("overflow", "with_index", S(
        'put "a" {v:1,blob:' + strdoc(3000) + '}',
        'put "b" {v:2,blob:' + strdoc(5000) + '}',
        'create index v', 'stat', 'indexes',
        'find v > 0 limit 0',
        'update "a" v 9', 'indexes', 'find v == 9 limit 0',
        'delete "b"', 'indexes', 'stat'))

    add("overflow", "mixed_inline_overflow", S(*(
        [put("k%02d" % i, strdoc(100 if i % 3 == 0 else 2500)) for i in range(18)] +
        ['stat', 'scan keys'] +
        [put("k%02d" % i, strdoc(2500 if i % 3 == 0 else 100)) for i in range(18)] +
        ['stat', 'scan keys'])))


# --------------------------------------------------------------------------
# area: the free list
# --------------------------------------------------------------------------

def area_free():
    add("free", "reuse_after_delete", S(
        'put "k1" "x"', 'put "k2" "y"', 'delete "k1"', 'delete "k2"',
        'stat', 'put "k3" "z"', 'stat'))

    add("free", "lifo_order", S(*(
        [put("k%02d" % i, strdoc(2000)) for i in range(6)] +
        ['stat'] +
        ['delete "k%02d"' % i for i in range(6)] +
        ['stat'] +
        [put("n%02d" % i, strdoc(1300)) for i in range(5)] +
        ['stat', 'scan keys'])))

    add("free", "free_and_realloc_in_txn", S(
        put("a", strdoc(3000)), 'stat',
        'begin', 'delete "a"', 'stat', put("b", strdoc(3000)), 'stat',
        'commit', 'stat', 'scan keys'))

    add("free", "rollback_restores", S(
        put("a", strdoc(2000)), 'stat',
        'begin', 'delete "a"', put("b", strdoc(5000)), 'stat',
        'rollback', 'stat', 'scan keys'))

    add("free", "churn", S(*(
        sum(([put("k%02d" % i, strdoc(2500)), 'delete "k%02d"' % i]
             for i in range(12)), []) +
        ['stat'] +
        [put("z%02d" % i, listdoc(20)) for i in range(10)] +
        ['stat', 'scan keys'])))

    add("free", "drop_index_pages", S(*(
        [put("k%03d" % i, '{v:%d}' % i) for i in range(60)] +
        ['create index v', 'indexes', 'stat',
         'drop index v', 'stat', 'indexes'] +
        [put("n%02d" % i, listdoc(20)) for i in range(8)] +
        ['stat'])))

    add("free", "interleaved_trees", S(*(
        [put("k%03d" % i, listdoc(20)) for i in range(30)] +
        ['create index nope', 'stat'] +
        ['delete "k%03d"' % i for i in range(0, 30, 2)] +
        ['stat', 'drop index nope', 'stat'] +
        [put("m%03d" % i, listdoc(20)) for i in range(10)] +
        ['stat'])))

    add("free", "big_free_list", S(*(
        [put("k%03d" % i, strdoc(10000)) for i in range(12)] +
        ['stat'] +
        ['delete "k%03d"' % i for i in range(12)] +
        ['stat'] +
        [put("n%03d" % i, "1") for i in range(40)] +
        ['stat', 'scan keys limit 3'])))


# --------------------------------------------------------------------------
# area: indexes
# --------------------------------------------------------------------------

def area_index():
    add("index", "create_drop", S(
        'put "u1" {age:1}', 'create index age', 'stat', 'checkpoint',
        'stat', 'drop index age', 'stat', 'drop index age'))

    add("index", "empty_store", S(
        'create index age', 'indexes', 'stat',
        'put "a" {age:1}', 'indexes',
        'drop index age', 'indexes', 'stat'))

    add("index", "errors", S(
        'create index a', 'create index a', 'drop index b',
        'create index a.b', 'create index a.b', 'indexes',
        'drop index a', 'drop index a', 'indexes',
        'drop index a.b', 'indexes', 'stat'))

    add("index", "sixteen_slots", S(*(
        ['create index i%02d' % i for i in range(16)] +
        ['create index i16', 'indexes', 'stat'] +
        [put("k%02d" % i, "{" + ",".join("i%02d:%d" % (j, i + j)
                                         for j in range(16)) + "}")
         for i in range(6)] +
        ['indexes', 'stat'] +
        ['drop index i%02d' % i for i in (0, 5, 15)] +
        ['indexes', 'create index zz', 'create index yy', 'indexes',
         'stat'])), force_public=True)

    add("index", "slot_reuse", S(
        'create index a', 'create index b', 'indexes',
        'drop index a', 'indexes', 'create index c', 'indexes',
        'drop index b', 'indexes', 'create index d', 'create index e',
        'indexes', 'stat'))

    add("index", "maintenance", S(*(
        [put("k%02d" % i, '{v:%d,w:"s%02d"}' % (i % 5, i)) for i in range(20)] +
        ['create index v', 'create index w', 'indexes'] +
        ['put "k00" {v:99}', 'indexes',
         'update "k01" v 98', 'indexes',
         'unset "k02" v', 'indexes',
         'delete "k03"', 'indexes',
         'update "k04" w "zz"', 'indexes',
         'put "k05" {v:[1],w:{}}', 'indexes',
         'put "k05" {v:1,w:"x"}', 'indexes',
         'stat'])))

    add("index", "indexable_kinds", S(
        'put "a" {v:null}', 'put "b" {v:true}', 'put "c" {v:false}',
        'put "d" {v:0}', 'put "e" {v:-1}', 'put "f" {v:"s"}',
        'put "g" {v:[]}', 'put "h" {v:{}}', 'put "i" {w:1}',
        'create index v', 'indexes',
        'find v >= null', 'find v == null', 'find v == true',
        'find exists v', 'stat'))

    add("index", "key_too_long_put", S(
        'create index v',
        'put "u" {v:"%s"}' % ("a" * 124),
        'indexes',
        'put "u2" {v:"%s"}' % ("a" * 125),
        'indexes',
        'put "%s" {v:"a"}' % ("k" * 124),
        'put "%s" {v:"a"}' % ("k" * 125),
        'indexes', 'stat'))

    add("index", "key_too_long_create", S(
        'put "u" {v:"%s"}' % ("a" * 125),
        'create index v',
        'indexes',
        'put "u" {v:"%s"}' % ("a" * 124),
        'create index v', 'indexes',
        'put "u2" {v:"%s"}' % ("a" * 125),
        'indexes', 'stat'))

    add("index", "key_zero_bytes", S(
        'create index v',
        'put "u" {v:"a\\u0000b"}', 'indexes', 'find v == "a\\u0000b"',
        'put "u2" {v:"%s"}' % ("\\u0000" * 61),
        'put "u3" {v:"%s"}' % ("\\u0000" * 62),
        'indexes', 'stat'))

    add("index", "key_too_long_update", S(
        'create index v',
        'put "u" {v:"a"}',
        'update "u" v "%s"' % ("a" * 124),
        'update "u" v "%s"' % ("a" * 125),
        'get "u"', 'indexes',
        'unset "u" v', 'indexes', 'stat'))

    add("index", "limit_then_drop", S(*(
        ['create index i%02d' % i for i in range(16)] +
        ['create index extra', 'drop index i07',
         'create index extra', 'indexes',
         'drop index i00', 'drop index i15', 'indexes',
         'create index a', 'create index b', 'create index c', 'indexes',
         'stat'])))

    add("index", "nested_path", S(
        'put "a" {u:{v:1,w:{x:2}}}',
        'put "b" {u:{v:2}}',
        'put "c" {u:1}',
        'create index u.v', 'create index u.w.x', 'indexes',
        'find u.v == 1', 'find u.w.x == 2',
        'update "a" u.v 5', 'indexes', 'find u.v == 5',
        'unset "a" u.w', 'indexes',
        'drop index u.w.x', 'indexes', 'stat'))

    add("index", "txn_rollback", S(
        'put "a" {v:1}', 'begin', 'create index v', 'indexes', 'stat',
        'rollback', 'indexes', 'stat',
        'begin', 'create index v', 'put "b" {v:2}', 'commit',
        'indexes', 'stat',
        'begin', 'drop index v', 'indexes', 'rollback', 'indexes', 'stat'))

    add("index", "multi_page", S(*(
        [put(wide(i, 100), '{v:"%s"}' % wide(i, 20)) for i in range(120)] +
        ['create index v', 'indexes', 'stat',
         'find v == "%s"' % wide(5, 20),
         'find v > "%s" limit 3' % wide(100, 20),
         'drop index v', 'stat', 'indexes'])))

    add("index", "entries_accounting", S(*(
        [put("k%02d" % i, '{v:%d}' % i if i % 3 else '{w:%d}' % i)
         for i in range(30)] +
        ['create index v', 'indexes'] +
        ['update "k%02d" v %d' % (i, i) for i in range(0, 30, 3)] +
        ['indexes'] +
        ['unset "k%02d" v' % i for i in range(1, 30, 3)] +
        ['indexes'] +
        ['delete "k%02d"' % i for i in range(2, 30, 3)] +
        ['indexes', 'stat'])))

    add("index", "same_value_many_keys", S(*(
        [put("k%03d" % i, '{v:7}') for i in range(50)] +
        ['create index v', 'indexes', 'find v == 7 limit 3',
         'find v >= 7 limit 3', 'find v > 7', 'find v < 7',
         'delete "k000"', 'delete "k049"', 'indexes',
         'find v == 7 limit 2', 'stat'])))

    add("index", "drop_rebuild_cycle", S(*(
        [put("k%02d" % i, '{v:%d}' % (i * 7 % 23)) for i in range(40)] +
        ['create index v', 'indexes', 'drop index v',
         'create index v', 'indexes', 'drop index v',
         'create index v', 'indexes', 'stat',
         'find v == 7', 'checkpoint', 'stat'])))

    add("index", "index_only_fields", S(
        'create index v', 'create index w',
        'put "a" {v:1}', 'put "b" {w:2}', 'put "c" {v:3,w:4}',
        'put "d" {}', 'indexes',
        'put "a" 5', 'indexes',
        'put "a" {v:1}', 'indexes',
        'delete "c"', 'indexes', 'stat'))


# --------------------------------------------------------------------------
# area: transactions
# --------------------------------------------------------------------------

def area_txn():
    add("txn", "worked_example", S(
        'begin', 'put "a" 1', 'put "b" 2', 'stat', 'rollback', 'stat',
        'begin', 'put "a" 1', 'commit', 'stat'))

    add("txn", "errors", S(
        'put "a" 1', 'put "a" 2', 'get "zz"', 'delete "zz"', 'frobnicate',
        'put "a"', 'put "a" 007', 'put "a" 9223372036854775808',
        'put "a" {x:1,x:2}', 'put "\\ud800" 1', 'put "" 1',
        'commit', 'rollback', 'begin', 'begin', 'checkpoint'))

    add("txn", "frames", S(
        'begin', 'put "a" 1', 'commit',
        'begin', 'put "b" 2', 'put "c" 3', 'commit',
        'begin', 'commit',
        'begin', 'put "d" ' + strdoc(3000), 'commit',
        'begin', 'rollback', 'stat'))

    add("txn", "failing_inside", S(
        'begin', 'put "a" 1', 'get "zz"', 'put "" 1', 'frobnicate',
        'begin', 'checkpoint', 'stat', 'put "b" 2', 'commit', 'stat',
        'scan keys'))

    add("txn", "left_open", S(
        'put "a" 1', 'begin', 'put "b" 2', 'delete "a"', 'stat'))

    add("txn", "left_open_big", S(*(
        [put("k%02d" % i, listdoc(20)) for i in range(10)] +
        ['begin'] +
        [put("m%02d" % i, listdoc(20)) for i in range(10)] +
        ['delete "k%02d"' % i for i in range(5)] +
        ['stat', 'scan keys'])))

    add("txn", "interleaved", S(
        'put "a" 1', 'begin', 'put "b" 2', 'commit', 'put "c" 3',
        'begin', 'put "d" 4', 'rollback', 'put "e" 5',
        'begin', 'delete "a"', 'commit', 'scan keys', 'stat'))

    add("txn", "reads_see_dirty", S(
        'put "a" {v:1}', 'create index v',
        'begin', 'update "a" v 2', 'get "a"', 'find v == 2',
        'find v == 1', 'indexes', 'scan', 'stat',
        'rollback', 'get "a"', 'find v == 1', 'indexes', 'stat'))

    add("txn", "rollback_after_split", S(*(
        [put("k%d" % i, LIST20) for i in range(1, 6)] +
        ['stat', 'begin', put("k6", LIST20), 'stat', 'rollback', 'stat',
         'scan keys'])))

    add("txn", "rollback_after_merge", S(*(
        [put("k%02d" % i, listdoc(20)) for i in range(12)] +
        ['stat', 'begin'] +
        ['delete "k%02d"' % i for i in range(10)] +
        ['stat', 'rollback', 'stat', 'scan keys'])))

    add("txn", "many_small_txns", S(*(
        sum((['begin', put("k%02d" % i, str(i)), 'commit'] for i in range(20)),
            []) + ['stat', 'scan keys limit 3'])))

    add("txn", "big_txn", S(*(
        ['begin'] +
        [put("k%03d" % i, listdoc(20)) for i in range(60)] +
        ['commit', 'stat', 'scan keys limit 3'])))

    add("txn", "rollback_everything", S(*(
        [put("k%02d" % i, listdoc(20)) for i in range(8)] +
        ['stat', 'begin'] +
        [put("m%02d" % i, strdoc(2500)) for i in range(8)] +
        ['delete "k%02d"' % i for i in range(8)] +
        ['create index v', 'stat', 'rollback', 'stat', 'scan keys',
         'indexes'])))


# --------------------------------------------------------------------------
# area: checkpointing
# --------------------------------------------------------------------------

def area_ckpt():
    add("ckpt", "worked_example", S('put "a" 1', 'checkpoint', 'stat'))

    add("ckpt", "empty_and_repeat", S(
        'checkpoint', 'stat', 'checkpoint', 'put "a" 1', 'checkpoint',
        'checkpoint', 'stat', 'checkpoint', 'stat'))

    add("ckpt", "in_txn", S(
        'put "a" 1', 'begin', 'checkpoint', 'put "b" 2', 'checkpoint',
        'commit', 'checkpoint', 'stat'))

    add("ckpt", "with_index", S(
        'put "u1" {age:1}', 'create index age', 'stat', 'checkpoint',
        'stat', 'drop index age', 'stat', 'drop index age'))

    add("ckpt", "auto_boundary_123", S(*(
        [put("a", "1")] * 123 + ['stat'])))

    add("ckpt", "auto_boundary_124", S(*(
        [put("a", "1")] * 124 + ['stat'] + [put("a", "1")] * 2 + ['stat'])),
        force_public=True)

    add("ckpt", "auto_mixed", S(*(
        [put("k%03d" % i, listdoc(20)) for i in range(200)] +
        ['stat', 'checkpoint', 'stat', 'scan keys limit 3'])))

    add("ckpt", "auto_with_big_txn", S(*(
        [put("a", strdoc(5000))] * 40 + ['stat'] +
        ['begin'] + [put("b%02d" % i, strdoc(3000)) for i in range(20)] +
        ['commit', 'stat'])))

    add("ckpt", "after_checkpoint_writes", S(*(
        [put("k%02d" % i, listdoc(20)) for i in range(20)] +
        ['checkpoint', 'stat'] +
        ['delete "k%02d"' % i for i in range(0, 20, 2)] +
        ['stat', 'checkpoint', 'stat', 'scan keys'])))

    add("ckpt", "shrink_then_grow", S(*(
        [put("k%02d" % i, strdoc(4000)) for i in range(10)] +
        ['checkpoint', 'stat'] +
        ['delete "k%02d"' % i for i in range(10)] +
        ['checkpoint', 'stat'] +
        [put("n%02d" % i, "1") for i in range(10)] +
        ['checkpoint', 'stat'])))


# --------------------------------------------------------------------------
# area: recovery
# --------------------------------------------------------------------------

WAL_HEADER = bytes.fromhex(
    "5445535357414c31000104000000000000000000000000000000000051e72153")


def raw_rec(typ, txn, field12, payload, pad=b"\0\0\0", declared=None,
            crc=None):
    """A record with every header field under the caller's control."""
    if declared is None:
        declared = len(payload)
    head = (bytes([typ]) + pad + struct.pack(">Q", txn) +
            struct.pack(">II", field12, declared))
    if crc is None:
        crc = crc32(head + payload)
    return head + struct.pack(">I", crc) + payload


def rec_page(txn, page_no, payload):
    head = struct.pack(">B3xQII", 1, txn, page_no, len(payload))
    return head + struct.pack(">I", crc32(head + payload)) + payload


def rec_commit(txn, frames):
    head = struct.pack(">B3xQII", 2, txn, frames, 0)
    return head + struct.pack(">I", crc32(head))


def parse_wal(data):
    """Split a well-formed log into (type, txn, field12, payload) records."""
    out = []
    off = 32
    while off + 24 <= len(data):
        typ = data[off]
        txn = int.from_bytes(data[off + 4:off + 12], "big")
        f12 = int.from_bytes(data[off + 12:off + 16], "big")
        plen = int.from_bytes(data[off + 16:off + 20], "big")
        out.append((typ, txn, f12, data[off + 24:off + 24 + plen]))
        off += 24 + plen
    return out


def rebuild(records):
    parts = [WAL_HEADER]
    for typ, txn, f12, payload in records:
        parts.append(rec_page(txn, f12, payload) if typ == 1
                     else rec_commit(txn, f12))
    return b"".join(parts)


SCAN4 = S('scan', 'stat', 'put "c" 3', 'stat', 'scan keys')


def area_recovery():
    # A two-transaction log over the fresh database, as in SPEC.md §21.10.
    base_tdb, base_wal = build(S('put "a" 1', 'put "b" 2'))
    fresh_tdb, _ = build("")
    assert len(base_wal) == 4272, len(base_wal)

    add("recovery", "cut_3000", SCAN4, fresh_tdb, base_wal[:3000])

    add("recovery", "damaged_header", S('scan', 'stat'),
        build(S('put "a" 1', 'checkpoint'))[0], b"0123456789")

    for off in (0, 1, 31, 32, 33, 55, 56, 57, 1079, 1080, 1081, 2127, 2128,
                2151, 2152, 2153, 2175, 2176, 3199, 3200, 4247, 4248, 4271,
                4272):
        add("recovery", "cut_%04d" % off, SCAN4, fresh_tdb, base_wal[:off])

    # The same sweep, but with a checkpointed main.tdb underneath, so recovery
    # has to overlay committed images onto real file pages.
    mid_tdb, mid_wal = build(S('put "a" 1', 'checkpoint', 'put "b" 2',
                               'put "c" 3'))
    for off in (32, 1080, 2152, 2153, 3200, len(mid_wal) - 1, len(mid_wal)):
        add("recovery", "overlay_cut_%04d" % off,
            S('scan', 'stat', 'put "d" 4', 'stat'), mid_tdb, mid_wal[:off])

    add("recovery", "no_wal", S('scan', 'stat', 'put "z" 9', 'stat'),
        build(S('put "a" 1', 'put "b" 2', 'checkpoint'))[0], None)

    add("recovery", "wal_only", SCAN4, None, base_wal)

    add("recovery", "empty_wal", SCAN4, fresh_tdb, b"")

    add("recovery", "header_only_wal", SCAN4, fresh_tdb, WAL_HEADER)

    bad_magic = b"TESSWAL2" + WAL_HEADER[8:]
    add("recovery", "bad_magic", SCAN4, fresh_tdb, bad_magic + base_wal[32:])

    bad_ver = WAL_HEADER[:8] + b"\x00\x02" + WAL_HEADER[10:]
    add("recovery", "bad_version", SCAN4, fresh_tdb, bad_ver + base_wal[32:])

    bad_ps = WAL_HEADER[:10] + b"\x08\x00" + WAL_HEADER[12:]
    add("recovery", "bad_page_size", SCAN4, fresh_tdb, bad_ps + base_wal[32:])

    bad_res = bytearray(WAL_HEADER)
    bad_res[20] = 1
    add("recovery", "bad_reserved", SCAN4, fresh_tdb,
        bytes(bad_res) + base_wal[32:])

    bad_crc = WAL_HEADER[:28] + b"\x00\x00\x00\x00"
    add("recovery", "bad_header_crc", SCAN4, fresh_tdb,
        bad_crc + base_wal[32:])

    add("recovery", "short_header", SCAN4, fresh_tdb, WAL_HEADER[:31])

    add("recovery", "trailing_garbage", SCAN4, fresh_tdb,
        base_wal + b"\xff" * 300)

    add("recovery", "trailing_zeroes", SCAN4, fresh_tdb,
        base_wal + bytes(5000))

    recs = parse_wal(base_wal)
    assert [r[0] for r in recs] == [1, 1, 2, 1, 1, 2], [r[0] for r in recs]

    # A page image whose CRC has been flipped: the scan stops right there.
    broken = bytearray(base_wal)
    broken[2152 + 23] ^= 0xFF
    add("recovery", "bad_record_crc", SCAN4, fresh_tdb, bytes(broken))

    broken2 = bytearray(base_wal)
    broken2[1080 + 500] ^= 0x01
    add("recovery", "bad_payload_crc", SCAN4, fresh_tdb, bytes(broken2))

    # Record header fields that must make the scan stop. Each of these keeps a
    # correct CRC, so only the intended check of §16.3 is what rejects it.
    prefix = rebuild(recs[:3])
    add("recovery", "bad_type", SCAN4, fresh_tdb,
        prefix + raw_rec(3, 2, 1, recs[3][3]))

    add("recovery", "nonzero_pad", SCAN4, fresh_tdb,
        prefix + raw_rec(1, 2, 1, recs[3][3], pad=b"\0\x07\0"))

    add("recovery", "type_zero", SCAN4, fresh_tdb,
        prefix + raw_rec(0, 2, 1, recs[3][3]))

    add("recovery", "page_no_zero", SCAN4, fresh_tdb,
        prefix + rec_page(2, 0, recs[3][3]) + rec_commit(2, 1))

    add("recovery", "frame_count_zero", SCAN4, fresh_tdb,
        rebuild(recs[:3]) + rec_page(2, 1, recs[3][3]) + rec_commit(2, 0))

    add("recovery", "frame_count_wrong", SCAN4, fresh_tdb,
        rebuild(recs[:3]) + rec_page(2, 1, recs[3][3]) + rec_commit(2, 5))

    add("recovery", "commit_without_group", SCAN4, fresh_tdb,
        rebuild(recs[:3]) + rec_commit(2, 1))

    add("recovery", "txn_id_mismatch", SCAN4, fresh_tdb,
        rebuild(recs[:3]) + rec_page(2, 1, recs[3][3]) +
        rec_page(3, 2, recs[4][3]) + rec_commit(2, 2))

    add("recovery", "commit_txn_mismatch", SCAN4, fresh_tdb,
        rebuild(recs[:3]) + rec_page(2, 1, recs[3][3]) +
        rec_page(2, 2, recs[4][3]) + rec_commit(7, 2))

    add("recovery", "unterminated_group", SCAN4, fresh_tdb, rebuild(recs[:5]))

    add("recovery", "bad_payload_len", SCAN4, fresh_tdb,
        prefix + rec_page(2, 1, recs[3][3][:512]))

    add("recovery", "declared_len_short", SCAN4, fresh_tdb,
        prefix + raw_rec(1, 2, 1, recs[3][3], declared=1023))

    add("recovery", "commit_with_payload", SCAN4, fresh_tdb,
        prefix + raw_rec(2, 2, 1, bytes(1024)))

    add("recovery", "commit_declares_payload", SCAN4, fresh_tdb,
        prefix + raw_rec(2, 2, 1, b"", declared=1024))

    # Non-contiguous txn_ids are accepted (§16.3).
    add("recovery", "txn_ids_sparse", SCAN4, fresh_tdb, rebuild(
        [(1, 90, recs[0][2], recs[0][3]), (1, 90, recs[1][2], recs[1][3]),
         (2, 90, 2, b""), (1, 7, recs[3][2], recs[3][3]),
         (1, 7, recs[4][2], recs[4][3]), (2, 7, 2, b"")]))

    # The same page written twice inside one transaction: the later image wins.
    dup = [(1, 1, 1, bytes(1024)), (1, 1, recs[0][2], recs[0][3]),
           (1, 1, recs[1][2], recs[1][3]), (2, 1, 3, b"")]
    add("recovery", "duplicate_page_image", SCAN4, fresh_tdb, rebuild(dup))

    # Restart equivalence: the second half of a script sees the first half's
    # output files as its input.
    halves = [
        (S(*[put("k%02d" % i, listdoc(20)) for i in range(14)]),
         S(*(['delete "k%02d"' % i for i in range(0, 14, 2)] +
             ['stat', 'scan keys']))),
        (S('put "a" {v:1}', 'create index v', 'put "b" {v:2}'),
         S('indexes', 'find v == 2', 'put "c" {v:3}', 'indexes', 'stat')),
        (S(*[put("k%02d" % i, strdoc(2500)) for i in range(8)]),
         S(*(['delete "k%02d"' % i for i in range(8)] + ['stat'] +
             [put("n%02d" % i, "1") for i in range(6)] + ['stat']))),
        (S(*([put(wide(i), "1") for i in range(90)] + ['checkpoint'])),
         S(*(['delete "%s"' % wide(i) for i in range(0, 90, 3)] +
             ['stat', 'scan keys limit 3']))),
        (S('begin', 'put "a" 1', 'put "b" 2'),
         S('scan', 'stat', 'put "c" 3', 'stat')),
    ]
    for i, (first, second) in enumerate(halves):
        t, w = build(first)
        add("recovery", "restart_%d" % i, second, t, w)

    # Recovery followed by an immediate checkpoint, and by an auto checkpoint.
    add("recovery", "then_checkpoint", S('checkpoint', 'stat', 'scan keys'),
        fresh_tdb, base_wal)

    big_tdb, big_wal = build(S(*[put("a", "1")] * 110))
    add("recovery", "then_auto_checkpoint",
        S('stat', *([put("a", "1")] * 20 + ['stat'])), big_tdb, big_wal)

    # A commit record that undercounts its group's page images (§16.3 step 4).
    add("recovery", "frame_count_low", SCAN4, fresh_tdb,
        rebuild(recs[:3]) + rec_page(2, 1, recs[3][3]) +
        rec_page(2, 2, recs[4][3]) + rec_commit(2, 1))


# --------------------------------------------------------------------------
# area: stat and indexes reporting
# --------------------------------------------------------------------------

def area_stat():
    add("stat", "fresh", S('stat', 'indexes', 'scan', 'get "a"'))

    heights = ['stat']
    for i in range(48):
        heights.append(put(wide(i), LIST20))
        if i % 6 == 5:
            heights.append('stat')
    heights.append('scan keys limit 2')
    add("stat", "heights", S(*heights))

    add("stat", "wal_sizes", S(
        'stat', 'put "a" 1', 'stat', 'put "b" 2', 'stat',
        'begin', 'put "c" 3', 'stat', 'commit', 'stat',
        'checkpoint', 'stat', 'put "d" ' + strdoc(3000), 'stat'))

    add("stat", "indexes_listing", S(
        'create index zz', 'create index a.b', 'create index m',
        'indexes', 'put "k" {zz:1,a:{b:2},m:3}', 'indexes',
        'drop index a.b', 'indexes', 'create index q', 'indexes', 'stat'))

    add("stat", "example_19_3", S(
        'put "b" 2', 'put "a" {name:"ada",age:36}', 'get "a"', 'scan',
        'stat'))

    add("stat", "after_everything", S(*(
        [put("k%02d" % i, listdoc(20)) for i in range(20)] +
        ['create index v', 'put "x" {v:1}', 'delete "k00"', 'checkpoint',
         'begin', 'put "y" {v:2}', 'stat', 'commit', 'stat', 'indexes'])))


# --------------------------------------------------------------------------
# area: random workloads
# --------------------------------------------------------------------------

def rnd_doc(rnd, kind):
    """A document literal of a requested size class."""
    if kind == "scalar":
        return rnd.choice(["null", "true", "false", str(rnd.randint(-1000, 1000)),
                           '"%s"' % ("s" * rnd.randint(0, 12)),
                           str(rnd.choice([-(1 << 63), (1 << 63) - 1, 0]))])
    if kind == "obj":
        parts = []
        if rnd.random() < 0.85:
            parts.append("age:%d" % rnd.randint(0, 40))
        if rnd.random() < 0.8:
            parts.append('name:"n%02d"' % rnd.randint(0, 30))
        if rnd.random() < 0.4:
            parts.append('tag:%s' % rnd.choice(
                ['null', 'true', 'false', '"t"', '[1,2]', '{z:1}', '7']))
        if rnd.random() < 0.3:
            parts.append('nest:{deep:%d}' % rnd.randint(0, 9))
        return "{" + ",".join(parts) + "}"
    if kind == "mid":
        return listdoc(rnd.randint(5, 30))
    if kind == "big":
        return strdoc(rnd.randint(200, 2600))
    if kind == "huge":
        return strdoc(rnd.randint(6000, 20000))
    raise AssertionError(kind)


def gen_workload(seed, n, keyspace, size_mix, use_index, use_txn,
                 use_ckpt, keywidth=6):
    """A deterministic pseudo-random command script."""
    rnd = random.Random(seed)
    paths = ["age", "name", "tag", "nest.deep"]

    def key():
        i = rnd.randrange(keyspace)
        body = "k%05d" % i
        return body + "x" * max(0, keywidth - len(body))

    lines = []
    txn_open = False
    for _ in range(n):
        r = rnd.random()
        if r < 0.40:
            lines.append(put(key(), rnd_doc(rnd, rnd.choices(
                ["scalar", "obj", "mid", "big", "huge"],
                weights=size_mix)[0])))
        elif r < 0.52:
            lines.append('delete "%s"' % key())
        elif r < 0.60:
            lines.append('update "%s" %s %s' % (
                key(), rnd.choice(paths), rnd_doc(rnd, rnd.choices(
                    ["scalar", "obj", "mid", "big"],
                    weights=size_mix[:4])[0])))
        elif r < 0.65:
            lines.append('unset "%s" %s' % (key(), rnd.choice(paths)))
        elif r < 0.70:
            lines.append('%s "%s"' % ("get" if rnd.random() < 0.6 else "delete",
                                      key()))
        elif r < 0.76:
            opts = []
            if rnd.random() < 0.5:
                opts.append('from "%s"' % key())
            if rnd.random() < 0.5:
                opts.append('to "%s"' % key())
            opts.append("limit %d" % rnd.randint(0, 4))
            if rnd.random() < 0.5:
                opts.append("reverse")
            if rnd.random() < 0.85:
                opts.append("keys")
            rnd.shuffle(opts)
            lines.append("scan " + " ".join(opts))
        elif r < 0.82:
            p = rnd.choice(paths)
            op = rnd.choice(["==", "!=", "<", "<=", ">", ">="])
            val = rnd.choice(["null", "true", "false", str(rnd.randint(0, 40)),
                              '"n%02d"' % rnd.randint(0, 30), "[1,2]", "{z:1}"])
            pred = "%s %s %s" % (p, op, val)
            if rnd.random() < 0.3:
                pred += " and %s %s %d" % (rnd.choice(paths),
                                           rnd.choice(["==", ">", "<="]),
                                           rnd.randint(0, 40))
            if rnd.random() < 0.2:
                pred = "not(%s)" % pred
            if rnd.random() < 0.15:
                pred = "exists %s or %s" % (rnd.choice(paths), pred)
            lines.append("find %s limit %d" % (pred, rnd.randint(0, 2)))
        elif r < 0.86 and use_index:
            p = rnd.choice(paths)
            lines.append(("create index %s" if rnd.random() < 0.6
                          else "drop index %s") % p)
        elif r < 0.90 and use_txn:
            if txn_open:
                lines.append("commit" if rnd.random() < 0.65 else "rollback")
                txn_open = False
            else:
                lines.append("begin")
                txn_open = True
        elif r < 0.93 and use_ckpt:
            lines.append("checkpoint")
        elif r < 0.96:
            lines.append("stat")
        else:
            lines.append("indexes")
    if rnd.random() < 0.5 and txn_open:
        lines.append("commit")
        txn_open = False
    lines.append("stat")
    lines.append("indexes")
    lines.append("scan keys limit 5")
    return S(*lines)


WORKLOADS = [
    # (name, seed, commands, keyspace, size mix, index, txn, ckpt, key width)
    ("tiny_a", 1001, 40, 8, (6, 4, 2, 0, 0), True, True, True, 6),
    ("tiny_b", 1002, 40, 12, (3, 5, 3, 1, 0), True, True, False, 6),
    ("tiny_c", 1003, 60, 6, (4, 4, 2, 2, 0), False, True, True, 6),
    ("tiny_d", 1004, 60, 20, (2, 6, 3, 1, 0), True, False, True, 6),
    ("small_a", 1101, 120, 24, (3, 5, 3, 1, 0), True, True, True, 6),
    ("small_b", 1102, 120, 12, (2, 3, 4, 3, 1), True, True, False, 6),
    ("small_c", 1103, 150, 40, (4, 5, 2, 1, 0), True, True, True, 6),
    ("small_d", 1104, 150, 16, (1, 2, 5, 3, 0), False, True, True, 6),
    ("small_e", 1105, 180, 30, (3, 4, 3, 1, 0), True, True, True, 20),
    ("small_f", 1106, 180, 10, (5, 5, 1, 0, 0), True, False, False, 6),
    ("mid_a", 1201, 300, 60, (3, 5, 3, 1, 0), True, True, True, 6),
    ("mid_b", 1202, 300, 25, (2, 3, 4, 2, 1), True, True, True, 6),
    ("mid_c", 1203, 400, 100, (4, 5, 2, 1, 0), True, True, False, 6),
    ("mid_d", 1204, 400, 40, (2, 4, 4, 1, 0), True, True, True, 40),
    ("mid_e", 1205, 450, 80, (3, 4, 3, 1, 0), False, True, True, 6),
    ("mid_f", 1206, 450, 50, (1, 3, 5, 2, 0), True, True, True, 6),
    ("mid_g", 1207, 500, 150, (4, 4, 2, 1, 0), True, True, True, 6),
    ("mid_h", 1208, 500, 30, (2, 3, 3, 3, 1), True, True, True, 6),
    ("big_a", 1301, 800, 200, (3, 5, 3, 1, 0), True, True, True, 6),
    ("big_b", 1302, 800, 60, (2, 3, 4, 2, 0), True, True, True, 128),
    ("big_c", 1303, 1000, 300, (4, 5, 2, 1, 0), True, True, True, 6),
    ("big_d", 1304, 1000, 80, (2, 4, 4, 1, 0), True, True, False, 6),
    ("big_e", 1305, 1200, 400, (3, 4, 3, 1, 0), True, True, True, 6),
    ("big_f", 1306, 1200, 120, (1, 3, 5, 2, 0), True, True, True, 6),
    ("big_g", 1307, 1500, 500, (4, 4, 2, 1, 0), True, True, True, 6),
    ("big_h", 1308, 1500, 150, (2, 3, 4, 2, 0), True, True, True, 64),
    ("huge_a", 1401, 2500, 700, (4, 5, 2, 1, 0), True, True, True, 6),
    ("huge_b", 1402, 2500, 250, (2, 4, 4, 1, 0), True, True, True, 6),
    ("huge_c", 1403, 3500, 1000, (4, 5, 2, 1, 0), True, True, True, 6),
    ("huge_d", 1404, 3500, 300, (3, 4, 3, 1, 0), True, True, True, 6),
    ("huge_e", 1405, 5000, 1200, (5, 5, 2, 1, 0), True, True, True, 6),
    ("huge_f", 1406, 5000, 400, (3, 4, 3, 1, 0), True, True, True, 6),
    ("mega_a", 1501, 10000, 3000, (4, 5, 2, 1, 0), True, True, True, 6),
    ("mega_b", 1502, 12000, 2000, (3, 4, 3, 1, 0), True, True, True, 40),
]


def area_random():
    for (name, seed, n, ks, mix, idx, txn, ckpt, kw) in WORKLOADS:
        add("random", name,
            gen_workload(seed, n, ks, mix, idx, txn, ckpt, kw))

    # Workloads replayed in two halves, so the second half starts from the
    # first half's files.
    for name, seed, n, ks, mix, idx, txn, ckpt, kw in WORKLOADS[8:14]:
        first = gen_workload(seed + 50000, n, ks, mix, idx, txn, ckpt, kw)
        second = gen_workload(seed + 60000, n, ks, mix, idx, txn, ckpt, kw)
        t, w = build(first)
        add("random", "restart_" + name, second, t, w)

    # Workloads whose log is cut, so the second half also recovers.
    for name, seed, n, ks, mix, idx, txn, ckpt, kw in WORKLOADS[4:8]:
        first = gen_workload(seed + 70000, n, ks, mix, idx, txn, ckpt, kw)
        t, w = build(first)
        cut = 32 + (len(w) - 32) * 2 // 3
        add("random", "cut_" + name,
            gen_workload(seed + 80000, n // 2, ks, mix, idx, txn, ckpt, kw),
            t, w[:cut])


# --------------------------------------------------------------------------
# area: the worked examples of SPEC.md section 21
# --------------------------------------------------------------------------

def spec_examples():
    """Yield (number, commands, results) for every worked example in §21."""
    with open(os.path.join(HERE, "SPEC.md"), encoding="utf-8") as f:
        text = f.read()
    body = text.split("\n## 21. Worked examples", 1)[1].split("\n## 22.", 1)[0]
    for part in body.split("\n### 21.")[1:]:
        number = int(part.split(" ", 1)[0])
        blocks = part.split("```")
        commands = results = None
        for i in range(1, len(blocks), 2):
            label = blocks[i - 1].rstrip().rsplit("\n", 1)[-1].strip()
            content = blocks[i].lstrip("\n")
            if label == "`commands.txt`":
                commands = content
            elif label == "`results.txt`":
                results = content
        yield number, commands, results


def area_example():
    """Every §21 example, checked against the spec's own results.txt."""
    fresh_tdb, _ = build("")
    two_wal = build(S('put "a" 1', 'put "b" 2'))[1]
    inputs = {
        10: (fresh_tdb, two_wal[:3000]),
        11: (build(S('put "a" 1', 'checkpoint'))[0], b"0123456789"),
    }
    for number, commands, results in spec_examples():
        tdb, twal = inputs.get(number, (None, None))
        got = run_ref(commands, tdb, twal)[0]
        assert got == results, "SPEC.md §21.%d disagrees with the reference" % number
        add("example", "spec_21_%02d" % number, commands, tdb, twal,
            force_public=True)


# --------------------------------------------------------------------------
# writing the suites
# --------------------------------------------------------------------------

AREAS = [area_example, area_value, area_lex, area_scan, area_update, area_find, area_split,
         area_delete, area_overflow, area_free, area_index, area_txn,
         area_ckpt, area_recovery, area_stat, area_random]


def assign_visibility():
    """Mark one case in PUBLIC_STRIDE as public, counted within each area."""
    seen = {}
    for case in CASES:
        i = seen.get(case["area"], 0)
        seen[case["area"]] = i + 1
        case["public"] = case["force_public"] or (i % PUBLIC_STRIDE == 0)


def write_case(number, case):
    root = PUBLIC_DIR if case["public"] else HIDDEN_DIR
    dirname = os.path.join(root, "%03d_%s_%s" % (number, case["area"],
                                                 case["name"]))
    in_dir = os.path.join(dirname, "input")
    exp_dir = os.path.join(dirname, "expected")
    os.makedirs(in_dir)
    os.makedirs(exp_dir)
    with open(os.path.join(in_dir, "commands.txt"), "wb") as f:
        f.write(case["commands"].encode("utf-8"))
    if case["tdb"] is not None:
        with open(os.path.join(in_dir, "main.tdb"), "wb") as f:
            f.write(case["tdb"])
    if case["twal"] is not None:
        with open(os.path.join(in_dir, "main.twal"), "wb") as f:
            f.write(case["twal"])
    results, tdb, twal = run_ref(case["commands"], case["tdb"], case["twal"])
    with open(os.path.join(exp_dir, "results.txt"), "wb") as f:
        f.write(results.encode("utf-8"))
    with open(os.path.join(exp_dir, "main.tdb"), "wb") as f:
        f.write(tdb)
    with open(os.path.join(exp_dir, "main.twal"), "wb") as f:
        f.write(twal)
    return len(results) + len(tdb) + len(twal)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--list", action="store_true",
                    help="print the case table without writing it")
    args = ap.parse_args()

    for build_area in AREAS:
        build_area()
    assign_visibility()

    if args.list:
        for i, case in enumerate(CASES, 1):
            print("%03d %-7s %-24s %s %d lines"
                  % (i, case["area"], case["name"],
                     "public" if case["public"] else "hidden",
                     case["commands"].count("\n")))
        pub = sum(1 for c in CASES if c["public"])
        print("%d cases, %d public, %d hidden" % (len(CASES), pub,
                                                  len(CASES) - pub))
        return 0

    for root in (PUBLIC_DIR, HIDDEN_DIR):
        if os.path.isdir(root):
            shutil.rmtree(root)
        os.makedirs(root)

    sizes = {}
    for number, case in enumerate(CASES, 1):
        n = write_case(number, case)
        sizes[case["public"]] = sizes.get(case["public"], 0) + n
    pub = sum(1 for c in CASES if c["public"])
    print("wrote %d cases: %d public (%.1f MB), %d hidden (%.1f MB)"
          % (len(CASES), pub, sizes.get(True, 0) / 1e6,
             len(CASES) - pub, sizes.get(False, 0) / 1e6))
    return 0


if __name__ == "__main__":
    sys.exit(main())
