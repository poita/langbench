module tests.parser_test;

import std.array : replicate;

import tessera.ast;
import tessera.errors;
import tessera.lexer;
import tessera.parser;
import tessera.render;
import tessera.value;

private ErrorKind errorOf(string line)
{
    try
        parseCommand(line);
    catch (TesseraException e)
        return e.kind;
    assert(false, "expected an error for: " ~ line);
}

private bool parses(string line)
{
    try
    {
        parseCommand(line);
        return true;
    }
    catch (TesseraException)
        return false;
}

unittest
{
    // Tokens.
    auto t = tokenize(`put "aé" {x:-12, y:[]} <= >=<`);
    assert(t.length == 15);
    assert(t[1].strValue == "aé");
    assert(t[5].kind == TokenKind.integer && t[5].intValue == -12);
    assert(t[12].op == CmpOp.le && t[13].op == CmpOp.ge && t[14].op == CmpOp.lt);
}

unittest
{
    // Lexical errors are `syntax`.
    foreach (bad; ["=", "!", "-", "put 007", "put -0", "put +1", "put \"abc", "put \"a\\q\"", "put \"a\\u00zz\"",
            "put \"a\tb\"", "put #", "put 1 ;"])
        assert(errorOf(bad) == ErrorKind.syntax, bad);
    assert(errorOf("") == ErrorKind.syntax);
    assert(errorOf(" \t ") == ErrorKind.syntax);
    assert(errorOf("1 2") == ErrorKind.syntax);
    assert(errorOf("frobnicate") == ErrorKind.unknownCommand);
    assert(errorOf("PUT") == ErrorKind.unknownCommand);
}

unittest
{
    // Stage order of the specification.
    assert(errorOf(`frobnicate "\ud800"`) == ErrorKind.unknownCommand);
    assert(errorOf(`put "\ud800" 1`) == ErrorKind.badUtf8);
    assert(errorOf(`put 1 "x"`) == ErrorKind.syntax);
    assert(errorOf(`get "a" "\ud800"`) == ErrorKind.syntax);
    assert(errorOf(`put "a" 1 99999999999999999999`) == ErrorKind.syntax);
    assert(errorOf(`put "a" 9223372036854775808`) == ErrorKind.intRange);
    assert(errorOf(`put "a" -9223372036854775809`) == ErrorKind.intRange);
    assert(parses(`put "a" -9223372036854775808`));
    assert(errorOf(`put "" 1`) == ErrorKind.badKey);
    assert(errorOf(`get "` ~ "k".replicate(129) ~ `"`) == ErrorKind.badKey);
    assert(parses(`get "` ~ "k".replicate(128) ~ `"`));
    assert(errorOf(`put "\ud800A" 1`) == ErrorKind.badUtf8);
    assert(errorOf(`put "\udc00" 1`) == ErrorKind.badUtf8);
    assert(parses(`put "😀" 1`));
    assert(parseCommand(`put "😀" 1`).key == "😀");
}

unittest
{
    // Values.
    assert(errorOf(`put "a" [1,]`) == ErrorKind.syntax);
    assert(errorOf(`put "a" {a:1,}`) == ErrorKind.syntax);
    assert(errorOf(`put "a" {x:1,x}`) == ErrorKind.dupField);
    assert(errorOf(`put "a" {x:1,x 2}`) == ErrorKind.dupField);
    assert(errorOf(`put "a" {"x":1,x:2}`) == ErrorKind.dupField);
    assert(renderToString(parseCommand(`put "a" {b:[1,"x"],a:null}`).value) == `{"a":null,"b":[1,"x"]}`);
}

unittest
{
    // Depth is checked before the token at level 33 is examined.
    auto open = "[".replicate(32);
    auto close = "]".replicate(32);
    assert(parses(`put "a" ` ~ open ~ close));
    assert(errorOf(`put "a" ` ~ open ~ "1" ~ close) == ErrorKind.depth);
    assert(errorOf(`put "a" ` ~ open ~ "99999999999999999999") == ErrorKind.depth);
    assert(errorOf(`put "a" ` ~ open ~ `"\ud800"`) == ErrorKind.depth);
    assert(errorOf(`put "a" ` ~ open) == ErrorKind.depth);
    assert(errorOf(`put "a" ` ~ open ~ ")") == ErrorKind.depth);
    assert(errorOf(`put "a" ` ~ open ~ "-") == ErrorKind.syntax);
    assert(errorOf(`put "a" ` ~ "[".replicate(30) ~ `{x:[[1]],x:1}`) == ErrorKind.depth);
    assert(errorOf(`put "a" ` ~ "[".replicate(30) ~ `{x:1,x:[[1]]}`) == ErrorKind.dupField);
}

unittest
{
    // Paths.
    assert(parseCommand(`unset "k" a . b.c`).path == ["a", "b", "c"]);
    assert(errorOf(`unset "k" a.b.c.d.e.f.g.h.i.`) == ErrorKind.badPath);
    assert(errorOf(`unset "k" ` ~ "x".replicate(31) ~ ".") == ErrorKind.badPath);
    assert(parses(`unset "k" ` ~ "x".replicate(30)));
    assert(errorOf(`unset "k" aaaaaaaaa.bbbbbbbbb.ccccccccc.dd`) == ErrorKind.badPath);
    assert(errorOf(`update "k" a.`) == ErrorKind.syntax);
}

unittest
{
    // scan options.
    auto c = parseCommand(`scan reverse limit 3 from "a" to "z" keys`);
    assert(c.scan.reverse && c.scan.keysOnly && c.scan.hasFrom && c.scan.hasTo);
    assert(c.scan.limit == 3 && c.scan.from == "a" && c.scan.to == "z");
    assert(errorOf(`scan limit 1 limit 2`) == ErrorKind.syntax);
    assert(errorOf(`scan reverse reverse`) == ErrorKind.syntax);
    assert(errorOf(`scan limit -1`) == ErrorKind.syntax);
    assert(errorOf(`scan limit 2147483648`) == ErrorKind.syntax);
    assert(errorOf(`scan limit 9223372036854775808`) == ErrorKind.intRange);
    assert(parses(`scan limit 2147483647`));
    assert(parses(`scan from ""`));
    assert(parses(`scan from "` ~ "k".replicate(200) ~ `"`));
}

unittest
{
    // Predicates: precedence and the keyword disambiguation rules.
    auto c = parseCommand(`find a == 1 or b == 2 and c == 3 limit 5`);
    assert(c.hasLimit && c.limit == 5);
    assert(c.pred.kind == PredKind.or);
    assert(c.pred.kids[1].kind == PredKind.and);
    c = parseCommand(`find not(a == 1) and exists b.c and missing d`);
    assert(c.pred.kind == PredKind.and);
    assert(c.pred.kids[0].kind == PredKind.and);
    assert(c.pred.kids[0].kids[0].kind == PredKind.not);
    assert(c.pred.kids[0].kids[1].kind == PredKind.exists);
    assert(c.pred.kids[1].kind == PredKind.missing);
    // `exists` and `not` used as ordinary field names.
    c = parseCommand(`find exists == 1`);
    assert(c.pred.kind == PredKind.compare && c.pred.path == ["exists"]);
    c = parseCommand(`find not == 1`);
    assert(c.pred.kind == PredKind.compare && c.pred.path == ["not"]);
    assert(errorOf(`find`) == ErrorKind.syntax);
    assert(errorOf(`find a`) == ErrorKind.syntax);
    assert(errorOf(`find a == 1 limit`) == ErrorKind.syntax);
    assert(errorOf(`find a == 1 extra`) == ErrorKind.syntax);
    assert(errorOf(`find (a == 1`) == ErrorKind.syntax);
    assert(errorOf(`find a = 1`) == ErrorKind.syntax);
}
