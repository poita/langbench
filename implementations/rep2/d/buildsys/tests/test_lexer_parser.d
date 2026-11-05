module test_lexer_parser;

import kiln.errors;
import kiln.lexer;
import kiln.parser;
import kiln.ast;

private string parseErr(string src)
{
    try
    {
        parseProgram(src, "f.kiln");
    }
    catch (KilnError e)
        return e.render();
    return "";
}

unittest
{
    auto lines = lexFile("let a = 1 # comment\n\n  \nlet b = [\n 1,\n 2\n]\n", "f");
    assert(lines.length == 2);
    assert(lines[0].line == 1 && lines[1].line == 4);
    assert(lines[0].tokens.length == 4);
    // `#` inside a string is content
    lines = lexFile("let a = \"x#y\"\n", "f");
    assert(lines[0].tokens[3].text == "x#y");
    // a nested literal inside an interpolation does not close the outer one
    lines = lexFile("cmd write(\"{join(xs, \", \")}\\n\")\n", "f");
    assert(lines[0].tokens.length == 5);
    assert(lines[0].tokens[3].doubleQuoted);
}

unittest
{
    assert(parseErr("let a = 1\nlet b = \"abc\n") == "E_PARSE f.kiln:2");
    assert(parseErr("let = 1\nlet x = \"abc\n") == "E_PARSE f.kiln:2");   // lexical first
    assert(parseErr("let b = f(\n  \"unterminated\n)\n") == "E_PARSE f.kiln:1");
    assert(parseErr("let a = (1\n") == "E_PARSE f.kiln:1");
    assert(parseErr("let a = 1)\n") == "E_PARSE f.kiln:1");
    assert(parseErr("let a = 1 | 2\n") == "E_PARSE f.kiln:1");
    assert(parseErr("let a = 1 & 2\n") == "E_PARSE f.kiln:1");
    assert(parseErr("let a = @\n") == "E_PARSE f.kiln:1");
}

unittest
{
    // blocks
    assert(parseErr("when true {\n}\n") == "");
    assert(parseErr("when true {\n} elsewhen false {\n} otherwise {\n}\n") == "");
    assert(parseErr("when true {\n") == "E_PARSE f.kiln:1");
    assert(parseErr("when true {\n} otherwise {\nlet a = 1\n") == "E_PARSE f.kiln:2");
    assert(parseErr("}\n") == "E_PARSE f.kiln:1");
    assert(parseErr("each x in [] {\n} otherwise {\n}\n") == "E_PARSE f.kiln:2");
    assert(parseErr("when true {\n} otherwise {\n} otherwise {\n}\n") == "E_PARSE f.kiln:3");
    assert(parseErr("when true {\n} otherwise {\n} elsewhen true {\n}\n") == "E_PARSE f.kiln:3");
    assert(parseErr("{\n") == "E_PARSE f.kiln:1");
    assert(parseErr("when true {\n} foo\n") == "E_PARSE f.kiln:2");
    assert(parseErr("out \"out/x\"\n") == "E_PARSE f.kiln:1");
    assert(parseErr("step {\nlet a = 1\n}\n") == "E_PARSE f.kiln:2");
    assert(parseErr("each a, a in [] {\n}\n") == "E_PARSE f.kiln:1");
    assert(parseErr("rule r(a, a) {\n}\n") == "E_PARSE f.kiln:1");
    assert(parseErr("rule r(a = 1, b) {\n}\n") == "E_PARSE f.kiln:1");
    assert(parseErr("rule r(a, b = 1,) {\n}\n") == "");
}

unittest
{
    // reserved words
    assert(parseErr("let cost = 1\n") == "E_PARSE f.kiln:1");
    assert(parseErr("let x = cost\n") == "E_PARSE f.kiln:1");
    assert(parseErr("let x = 1 |> cost\n") == "");           // call name, fails later
    assert(parseErr("let x = true(1)\n") == "");
    assert(parseErr("use r(cost = 1)\n") == "E_PARSE f.kiln:1");
    assert(parseErr("use r(a = 1, 2)\n") == "E_PARSE f.kiln:1");
    assert(parseErr("use cost(1)\n") == "");
}

unittest
{
    // strings
    assert(parseErr("let x = \"a\\qb\"\n") == "E_PARSE f.kiln:1");
    assert(parseErr("let x = \"a}b\"\n") == "E_PARSE f.kiln:1");
    assert(parseErr("let x = \"{}\"\n") == "E_PARSE f.kiln:1");
    assert(parseErr("let x = \"{ }\"\n") == "E_PARSE f.kiln:1");
    assert(parseErr("let x = \"{1 2}\"\n") == "E_PARSE f.kiln:1");
    assert(parseErr("let x = \"{{}}\"\n") == "");
    assert(parseErr("let x = 'a\\qb{'\n") == "");
    assert(parseErr("let x = f(1)(2)\n") == "E_PARSE f.kiln:1");
    assert(parseErr("let x = (f)(2)\n") == "E_PARSE f.kiln:1");
}

unittest
{
    auto prog = parseProgram("let a = 1\nstep {\n out \"out/a\"\n cmd write(\"x\")\n}\n", "f");
    assert(prog.length == 2);
    assert(prog[0].kind == SK.let && prog[0].name == "a");
    assert(prog[1].kind == SK.step && prog[1].fields.length == 2);
    assert(prog[1].fields[1].cmdName == "write");
}
