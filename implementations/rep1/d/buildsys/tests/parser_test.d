/// Unit tests for kiln.parser.
module parser_test;

import std.exception : collectException;

import kiln.ast;
import kiln.errors;
import kiln.parser;

private string parseError_(string text)
{
    auto e = collectException!KilnError(parseSource("f.kiln", text));
    return e is null ? "" : e.render;
}

unittest // statements of every shape parse
{
    auto prog = parseSource("f", "let a = 1\nset a = 2\nphony p = [\"x\"]\n" ~ "default \"x\"\nwhen a == 1 {\n}\n" ~ "each i, n in [1] {\n}\nrule r(a, b = 2) {\n}\nuse r(1, b = 3)\n" ~ "step {\n  out \"out/x\"\n  cmd write(\"x\")\n}\n");
    assert(prog.length == 9);
    assert(prog[$ - 1].kind == StmtKind.step);
    assert(prog[$ - 1].fields.length == 2);
}

unittest // when / elsewhen / otherwise chain
{
    auto prog = parseSource("f", "when a {\n} elsewhen b {\n} otherwise {\n}\n");
    assert(prog.length == 1);
    assert(prog[0].conds.length == 2 && prog[0].hasOtherwise);
}

unittest // precedence: ~ binds tighter than ++? no: ++ is looser than ~
{
    auto prog = parseSource("f", "let a = 1 + 2 * 3\n");
    auto e = prog[0].expr;
    assert(e.op == Op.add && e.kids[1].op == Op.mul);
}

unittest // pipe desugars into a call with the piped value first
{
    auto prog = parseSource("f", "let a = x |> f |> g(1)\n");
    auto e = prog[0].expr;
    assert(e.kind == ExprKind.call && e.name == "g" && e.kids.length == 2);
    assert(e.kids[0].kind == ExprKind.call && e.kids[0].name == "f");
}

unittest // interpolation is parsed at parse time
{
    auto prog = parseSource("f", "let a = \"v={1 + 2}!\"\n");
    auto e = prog[0].expr;
    assert(e.kind == ExprKind.interp && e.parts.length == 3);
}

unittest // grammar errors report the offending logical line
{
    assert(parseError_("let a = 1\nlet = 2\n") == "E_PARSE f.kiln:2");
    assert(parseError_("let a = 1 2\n") == "E_PARSE f.kiln:1");
    assert(parseError_("let cost = 1\n") == "E_PARSE f.kiln:1");
    assert(parseError_("out \"x\"\n") == "E_PARSE f.kiln:1");
    assert(parseError_("step {\n  let a = 1\n}\n") == "E_PARSE f.kiln:2");
    assert(parseError_("let a = \"{}\"\n") == "E_PARSE f.kiln:1");
    assert(parseError_("let a = \"\\q\"\n") == "E_PARSE f.kiln:1");
    assert(parseError_("let a = \"}\"\n") == "E_PARSE f.kiln:1");
    assert(parseError_("let a = (f)(1)\n") == "E_PARSE f.kiln:1");
    assert(parseError_("use r(a = 1, 2)\n") == "E_PARSE f.kiln:1");
    assert(parseError_("rule r(a, a) {\n}\n") == "E_PARSE f.kiln:1");
    assert(parseError_("rule r(a = 1, b) {\n}\n") == "E_PARSE f.kiln:1");
    assert(parseError_("each a, a in [] {\n}\n") == "E_PARSE f.kiln:1");
}

unittest // block structure errors
{
    assert(parseError_("}\n") == "E_PARSE f.kiln:1");
    assert(parseError_("{\n") == "E_PARSE f.kiln:1");
    assert(parseError_("each a in [] {\n} otherwise {\n}\n") == "E_PARSE f.kiln:2");
    assert(parseError_("when a {\n} otherwise {\n} elsewhen b {\n}\n") == "E_PARSE f.kiln:3");
    assert(parseError_("when a {\n}} foo\n") == "E_PARSE f.kiln:2");
}

unittest // unterminated blocks are reported at the innermost header, last
{
    assert(parseError_("when a {\neach i in [] {\n") == "E_PARSE f.kiln:2");
    assert(parseError_("when a {\n} elsewhen b {\nlet x = 1\n") == "E_PARSE f.kiln:2");
    assert(parseError_("when a {\nlet = 1\n") == "E_PARSE f.kiln:2");
}

unittest // reserved words are call names but not variables
{
    assert(parseError_("let a = cost(1)\n") == "");
    assert(parseError_("let a = 1 |> cost\n") == "");
    assert(parseError_("let a = cost\n") == "E_PARSE f.kiln:1");
    assert(parseError_("use cost()\n") == "");
}
