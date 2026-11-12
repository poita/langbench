"""End-to-end checks of ``results.txt`` and the output files against the worked examples of the spec."""

from tessera import Database, run_script
from tessera.wal import LOG_HEADER

from helpers import check_database

L20 = "[" + ",".join(map(str, range(1, 21))) + "]"


def run(script, db=None):
    db = db or Database.open()
    return run_script(db, script), db


def stat_block(k, pages, free, freehead, docs, root, height, commits, indexes, wal):
    rows = [("pages", pages), ("free", free), ("freehead", freehead), ("docs", docs), ("root", root),
            ("height", height), ("commits", commits), ("indexes", indexes), ("wal", wal)]
    return f"[{k}] ok stat\n" + "".join(f"  {n} {v}\n" for n, v in rows)


def test_small_results_file():
    out, _ = run('put "b" 2\nput "a" {name:"ada",age:36}\nget "a"\nscan\nstat\n')
    assert out == ('[1] ok put created\n[2] ok put created\n[3] ok get value\n'
                   '  {"age":36,"name":"ada"}\n[4] ok scan 2\n  "a" = {"age":36,"name":"ada"}\n'
                   '  "b" = 2\n' + stat_block(5, 2, 0, 0, 2, 2, 1, 2, 0, 4272))


def test_checkpoint_output_files():
    out, db = run('put "a" 1\ncheckpoint\nstat\n')
    assert out == "[1] ok put created\n[2] ok checkpoint pages 2\n" + stat_block(3, 2, 0, 0, 1, 2, 1, 1, 0, 32)
    page1, page2 = db.db_image()[:1024], db.db_image()[1024:]
    assert page1[:48].hex() == ("5445535345524131000104000000000200000000000000000000000200000001"
                                "00000000000000010000000000000000")
    assert not any(page1[48:])
    assert page2[:18].hex() == "0100000103ea" "0000" "00000000" "00000000" "03ea"
    assert page2[1002:].hex() == "00010000000900090000000061" "030000000000000001"
    assert db.wal_image() == LOG_HEADER


def test_delete_everything_then_reuse_the_freed_page():
    out, _ = run('put "k1" "x"\nput "k2" "y"\ndelete "k1"\ndelete "k2"\nstat\nput "k3" "z"\nstat\n')
    assert out.endswith(stat_block(5, 2, 1, 2, 0, 0, 0, 4, 0, 8512) + "[6] ok put created\n"
                        + stat_block(7, 2, 0, 0, 1, 2, 1, 5, 0, 10632))


def test_overflow_chain_pages():
    out, db = run('put "big" ' + "[" + ",".join(map(str, range(1, 26))) + "]\nstat\ndelete \"big\"\nstat\n")
    assert "  root 3\n" in out and "  pages 3\n" in out and "  wal 3200\n" in out
    assert out.endswith(stat_block(4, 3, 2, 3, 0, 0, 0, 2, 0, 6368))


def test_error_kinds():
    script = '''put "a" 1
put "a" 2
get "zz"
delete "zz"
frobnicate
put "a"
put "a" 007
put "a" 9223372036854775808
put "a" {x:1,x:2}
put "\\ud800" 1
put "" 1
commit
rollback
begin
begin
checkpoint
'''
    out, db = run(script)
    assert out.splitlines() == [
        "[1] ok put created", "[2] ok put replaced", "[3] error not-found", "[4] error not-found",
        "[5] error unknown-command", "[6] error syntax", "[7] error syntax", "[8] error int-range",
        "[9] error dup-field", "[10] error bad-utf8", "[11] error bad-key", "[12] error no-txn",
        "[13] error no-txn", "[14] ok begin", "[15] error txn-active", "[16] error txn-active"]
    assert len(db.wal_image()) == 32 + 2 * 2120      # the open transaction was rolled back


def test_blank_and_empty_scripts():
    assert run("")[0] == ""
    assert run("\n")[0] == "[1] error syntax\n"
    assert run('get "a"\n\n')[0] == "[1] error not-found\n[2] error syntax\n"
    assert run("  \t")[0] == "[1] error syntax\n"
    assert run("stat")[0] == stat_block(1, 1, 0, 0, 0, 0, 0, 0, 0, 32)


def test_secondary_index_and_find_plans():
    out, db = run('''put "u1" {name:"ada",age:36}
put "u2" {name:"bob",age:29}
put "u3" {name:"cy",age:36}
create index age
indexes
find age == 36
find age > 30
find age == 36 and name == "cy"
find not(age == 36)
stat
''')
    assert out.splitlines()[3:] == [
        "[4] ok create index age entries 3", "[5] ok indexes 1", "  0 age root 3 entries 3",
        "[6] ok find 2 plan index age", '  "u1" = {"age":36,"name":"ada"}', '  "u3" = {"age":36,"name":"cy"}',
        "[7] ok find 2 plan index age", '  "u1" = {"age":36,"name":"ada"}', '  "u3" = {"age":36,"name":"cy"}',
        "[8] ok find 1 plan index age", '  "u3" = {"age":36,"name":"cy"}',
        "[9] ok find 1 plan scan", '  "u2" = {"age":29,"name":"bob"}',
    ] + stat_block(10, 3, 0, 0, 3, 2, 1, 4, 1, 8512).splitlines()
    check_database(db)


def test_scan_option_combinations():
    out, _ = run('put "a" 1\nput "b" 2\nput "c" 3\nput "d" 4\nscan from "b" to "d"\n'
                 'scan reverse limit 2\nscan keys reverse\nscan from "d" to "b"\nscan limit 0\n')
    assert out.splitlines()[4:] == [
        "[5] ok scan 2", '  "b" = 2', '  "c" = 3', "[6] ok scan 2", '  "d" = 4', '  "c" = 3',
        "[7] ok scan 4", '  "d"', '  "c"', '  "b"', '  "a"', "[8] ok scan 0", "[9] ok scan 0"]


def test_update_and_unset():
    out, _ = run('put "u1" {name:"ada"}\nupdate "u1" age 36\nupdate "u1" addr.city "oslo"\nget "u1"\n'
                 'unset "u1" addr.city\nget "u1"\nunset "u1" addr.zip\nunset "u1" name.first\nupdate "u2" age 1\n')
    assert out.splitlines()[3:] == [
        "[4] ok get value", '  {"addr":{"city":"oslo"},"age":36,"name":"ada"}', "[5] ok unset updated",
        "[6] ok get value", '  {"addr":{},"age":36,"name":"ada"}', "[7] error no-field",
        "[8] error not-object", "[9] error not-found"]


def test_split_borrow_and_merge():
    puts = "".join(f'put "k{i}" {L20}\n' for i in range(1, 7))
    out, db = run(puts + 'stat\nscan keys\ndelete "k1"\ndelete "k2"\ndelete "k3"\nstat\nscan keys\n')
    assert stat_block(7, 4, 0, 0, 6, 4, 2, 6, 0, 14848) in out
    assert stat_block(12, 4, 2, 4, 3, 2, 1, 9, 0, 25400) in out
    check_database(db)


def test_thin_page_after_replace_then_borrow():
    puts = "".join(f'put "k{i}" {L20}\n' for i in range(1, 7))
    out, _ = run(puts + 'put "k1" 1\nput "k2" 2\nstat\ndelete "k3"\nstat\n')
    assert stat_block(9, 4, 0, 0, 6, 4, 2, 8, 0, 19088) in out
    assert stat_block(11, 4, 0, 0, 5, 4, 2, 9, 0, 23304) in out


def test_checkpoint_and_drop_index():
    out, db = run('put "u1" {age:1}\ncreate index age\nstat\ncheckpoint\nstat\ndrop index age\nstat\ndrop index age\n')
    assert "[4] ok checkpoint pages 3\n" in out and "[6] ok drop index age pages 1\n" in out
    assert out.endswith(stat_block(7, 3, 1, 3, 1, 2, 1, 3, 0, 2152) + "[8] error index-missing\n")


def test_explicit_transactions():
    out, db = run('begin\nput "a" 1\nput "b" 2\nstat\nrollback\nstat\nbegin\nput "a" 1\ncommit\nstat\n')
    assert out.splitlines()[3:] == (stat_block(4, 2, 0, 0, 2, 2, 1, 0, 0, 32).splitlines()
                                    + ["[5] ok rollback"] + stat_block(6, 1, 0, 0, 0, 0, 0, 0, 0, 32).splitlines()
                                    + ["[7] ok begin", "[8] ok put created", "[9] ok commit 1 frames 2"]
                                    + stat_block(10, 2, 0, 0, 1, 2, 1, 1, 0, 2152).splitlines())
    assert len(db.db_image()) == 1024
