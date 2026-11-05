module test_parser;

import std.exception : assertThrown;
import jq;

unittest // precedence: '|' loosest, then ',', or, and, comparison, additive, multiplicative
{
    auto n = parseFilter("1, 2 | 3");
    assert(n.kind == NodeKind.pipe && n.a.kind == NodeKind.comma);
    n = parseFilter("1 + 2 * 3");
    assert(n.kind == NodeKind.binary && n.op == BinOp.add && n.b.op == BinOp.mul);
    n = parseFilter("1 < 2 and 3 or 4");
    assert(n.kind == NodeKind.or && n.a.kind == NodeKind.and);
}

unittest // '?' after a path suffix is per-operation; after anything else it is try
{
    assert(parseFilter(".a?").opt);
    assert(parseFilter(".a?").kind == NodeKind.field);
    assert(parseFilter("(.a)?").kind == NodeKind.tryOp);
    assert(parseFilter(".a??").kind == NodeKind.tryOp);
    assert(parseFilter("length?").kind == NodeKind.tryOp);
    assert(parseFilter(".[]?").kind == NodeKind.iterate && parseFilter(".[]?").opt);
}

unittest // negative number literals are folded
{
    auto n = parseFilter("-3");
    assert(n.kind == NodeKind.literal && n.lit.num == -3);
    assert(parseFilter("1 -1").kind == NodeKind.binary);
}

unittest // slices and indexes
{
    assert(parseFilter(".[1:]").kind == NodeKind.slice);
    assert(parseFilter(".[:2]").b is null);
    assert(parseFilter(".[0]").kind == NodeKind.index);
    assert(parseFilter(`."a b"`).name.s == "a b");
}

unittest // variables resolve to binding distance
{
    auto n = parseFilter(`1 as $x | 2 as $y | $x`);
    assert(n.kind == NodeKind.asBind);
    assert(n.b.b.depth == 1);
}

unittest // object construction forms
{
    auto n = parseFilter(`1 as $v | {a, "b": 1, (.k): 2, $v}`);
    auto o = n.b;
    assert(o.kind == NodeKind.object && o.entries.length == 4);
    assert(o.entries[0].litKey.s == "a");
    assert(o.entries[2].key !is null);
    assert(o.entries[3].litKey.s == "v");
    assert(!o.distinctLiteralKeys);
    assert(parseFilter("{a:1,b:2}").distinctLiteralKeys);
    assert(!parseFilter("{a:1,a:2}").distinctLiteralKeys);
}

unittest // syntax errors
{
    assertThrown!ParseException(parseFilter("(1"));
    assertThrown!ParseException(parseFilter("nosuchfunction"));
    assertThrown!ParseException(parseFilter("$undefined"));
    assertThrown!ParseException(parseFilter("1 +"));
    assertThrown!ParseException(parseFilter("select"));
    assertThrown!ParseException(parseFilter("length(1)"));
    assertThrown!ParseException(parseFilter("if 1 then 2"));
}
