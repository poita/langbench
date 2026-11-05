module tests.interpreter_test;

import std.array : join, replicate;

import tessera.bytes;
import tessera.database;
import tessera.interpreter;

/// Run a script against a fresh database; returns the text of results.txt.
private string run(string script, Database db = null)
{
    if (db is null)
        db = new Database();
    auto it = new Interpreter(db);
    it.runScript(script);
    return cast(string) it.output.idup;
}

unittest
{
    // Lines are split at LF; a trailing LF does not start another line.
    assert(splitLines("") == []);
    assert(splitLines("a\nb\n") == ["a", "b"]);
    assert(splitLines("a\nb") == ["a", "b"]);
    assert(splitLines("a\nb\n\n") == ["a", "b", ""]);
    assert(run("") == "");
    assert(run("\n") == "[1] error syntax\n");
}

unittest
{
    // §19.3
    auto got = run("put \"b\" 2\nput \"a\" {name:\"ada\",age:36}\nget \"a\"\nscan\nstat\n");
    assert(got == "[1] ok put created
[2] ok put created
[3] ok get value
  {\"age\":36,\"name\":\"ada\"}
[4] ok scan 2
  \"a\" = {\"age\":36,\"name\":\"ada\"}
  \"b\" = 2
[5] ok stat
  pages 2
  free 0
  freehead 0
  docs 2
  root 2
  height 1
  commits 2
  indexes 0
  wal 4272
");
}

unittest
{
    // §21.5 errors
    auto script = [`put "a" 1`, `put "a" 2`, `get "zz"`, `delete "zz"`, `frobnicate`, `put "a"`, `put "a" 007`,
        `put "a" 9223372036854775808`, `put "a" {x:1,x:2}`, `put "\ud800" 1`, `put "" 1`, `commit`, `rollback`,
        `begin`, `begin`, `checkpoint`].join("\n");
    auto lines = run(script);
    assert(lines == "[1] ok put created
[2] ok put replaced
[3] error not-found
[4] error not-found
[5] error unknown-command
[6] error syntax
[7] error syntax
[8] error int-range
[9] error dup-field
[10] error bad-utf8
[11] error bad-key
[12] error no-txn
[13] error no-txn
[14] ok begin
[15] error txn-active
[16] error txn-active
");
}

unittest
{
    // §21.6 secondary index and find
    auto got = run(`put "u1" {name:"ada",age:36}
put "u2" {name:"bob",age:29}
put "u3" {name:"cy",age:36}
create index age
indexes
find age == 36
find age > 30
find age == 36 and name == "cy"
find not(age == 36)
stat`);
    assert(got == "[1] ok put created
[2] ok put created
[3] ok put created
[4] ok create index age entries 3
[5] ok indexes 1
  0 age root 3 entries 3
[6] ok find 2 plan index age
  \"u1\" = {\"age\":36,\"name\":\"ada\"}
  \"u3\" = {\"age\":36,\"name\":\"cy\"}
[7] ok find 2 plan index age
  \"u1\" = {\"age\":36,\"name\":\"ada\"}
  \"u3\" = {\"age\":36,\"name\":\"cy\"}
[8] ok find 1 plan index age
  \"u3\" = {\"age\":36,\"name\":\"cy\"}
[9] ok find 1 plan scan
  \"u2\" = {\"age\":29,\"name\":\"bob\"}
[10] ok stat
  pages 3
  free 0
  freehead 0
  docs 3
  root 2
  height 1
  commits 4
  indexes 1
  wal 8512
");
}

unittest
{
    // §21.8 update and unset
    auto got = run(`put "u1" {name:"ada"}
update "u1" age 36
update "u1" addr.city "oslo"
get "u1"
unset "u1" addr.city
get "u1"
unset "u1" addr.zip
unset "u1" name.first
update "u2" age 1`);
    assert(got == "[1] ok put created
[2] ok update updated
[3] ok update updated
[4] ok get value
  {\"addr\":{\"city\":\"oslo\"},\"age\":36,\"name\":\"ada\"}
[5] ok unset updated
[6] ok get value
  {\"addr\":{},\"age\":36,\"name\":\"ada\"}
[7] error no-field
[8] error not-object
[9] error not-found
");
}

unittest
{
    // §21.12 split, borrow, merge: page numbers and the free list
    enum doc = "[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20]";
    string script;
    foreach (i; 1 .. 7)
        script ~= `put "k` ~ cast(char)('0' + i) ~ `" ` ~ doc ~ "\n";
    script ~= "stat\ndelete \"k1\"\ndelete \"k2\"\ndelete \"k3\"\nstat\nscan keys\n";
    auto got = run(script);
    assert(got == "[1] ok put created
[2] ok put created
[3] ok put created
[4] ok put created
[5] ok put created
[6] ok put created
[7] ok stat
  pages 4
  free 0
  freehead 0
  docs 6
  root 4
  height 2
  commits 6
  indexes 0
  wal 14848
[8] ok delete removed
[9] ok delete removed
[10] ok delete removed
[11] ok stat
  pages 4
  free 2
  freehead 4
  docs 3
  root 2
  height 1
  commits 9
  indexes 0
  wal 25400
[12] ok scan 3
  \"k4\"
  \"k5\"
  \"k6\"
");
}

unittest
{
    // §21.4 rollback; a transaction left open at the end is discarded.
    auto db = new Database();
    auto got = run("begin\nput \"a\" 1\nput \"b\" 2\nstat\nrollback\nstat\nbegin\nput \"a\" 1\n", db);
    assert(got == "[1] ok begin
[2] ok put created
[3] ok put created
[4] ok stat
  pages 2
  free 0
  freehead 0
  docs 2
  root 2
  height 1
  commits 0
  indexes 0
  wal 32
[5] ok rollback
[6] ok stat
  pages 1
  free 0
  freehead 0
  docs 0
  root 0
  height 0
  commits 0
  indexes 0
  wal 32
[7] ok begin
[8] ok put created
");
    assert(!db.inTransaction);
    assert(db.databaseBytes.length == 1024);
    assert(db.logBytes.length == 32);
}

unittest
{
    // §21.7 scan ranges
    auto got = run(`put "a" 1
put "b" 2
put "c" 3
put "d" 4
scan from "b" to "d"
scan reverse limit 2
scan keys reverse
scan from "d" to "b"
scan limit 0
scan from ""`);
    assert(got == "[1] ok put created
[2] ok put created
[3] ok put created
[4] ok put created
[5] ok scan 2
  \"b\" = 2
  \"c\" = 3
[6] ok scan 2
  \"d\" = 4
  \"c\" = 3
[7] ok scan 4
  \"d\"
  \"c\"
  \"b\"
  \"a\"
[8] ok scan 0
[9] ok scan 0
[10] ok scan 4
  \"a\" = 1
  \"b\" = 2
  \"c\" = 3
  \"d\" = 4
");
}

unittest
{
    // §21.1: a checkpoint empties the log and writes the pages to the main file.
    auto db = new Database();
    auto got = run("put \"a\" 1\ncheckpoint\nstat\n", db);
    assert(got[0 .. 54] == "[1] ok put created\n[2] ok checkpoint pages 2\n[3] ok st");
    assert(db.databaseBytes.length == 2048);
    assert(db.logBytes.length == 32);
    assert(db.databaseBytes[0 .. 48] == [0x54, 0x45, 0x53, 0x53, 0x45, 0x52, 0x41, 0x31, 0, 1, 4, 0, 0, 0, 0, 2, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0]);
}

unittest
{
    // Escaping of keys on output.
    auto got = run("put \"a\\u0000\\n\\\"\" 1\nscan keys\n");
    assert(got == "[1] ok put created\n[2] ok scan 1\n  \"a\\u0000\\n\\\"\"\n");
}
