/// Unit tests for regexvm.parser (via the S-expression dump).
module regexvm.test_parser;

import std.exception : assertThrown;
import regexvm.ast;
import regexvm.errors;
import regexvm.parser;

private string sexp(string pattern) { return toSExpr(parse(pattern).root); }

unittest // literals, sequences, alternation
{
    assert(sexp("") == "(seq)");
    assert(sexp("abc") == "(seq a b c)");
    assert(sexp("a|b") == "(alt (seq a) (seq b))");
    assert(sexp("a||") == "(alt (seq a) (seq) (seq))");
    assert(sexp(" a ") == "(seq   a  )");
}

unittest // quantifiers and precedence
{
    assert(sexp("a*") == "(seq (rep 0 inf a))");
    assert(sexp("ab+") == "(seq a (rep 1 inf b))");
    assert(sexp("a?") == "(seq (rep 0 1 a))");
    assert(sexp("a{3}") == "(seq (rep 3 3 a))");
    assert(sexp("a{2,}") == "(seq (rep 2 inf a))");
    assert(sexp("a{0,5}") == "(seq (rep 0 5 a))");
    assert(sexp("ab|c*") == "(alt (seq a b) (seq (rep 0 inf c)))");
}

unittest // groups are numbered by their opening parenthesis
{
    auto ast = parse("(a(b)c)(d)");
    assert(ast.groupCount == 3);
    assert(toSExpr(ast.root) ==
        "(seq (group 1 (seq a (group 2 (seq b)) c)) (group 3 (seq d)))");
    assert(sexp("()") == "(seq (group 1 (seq)))");
    assert(sexp("(|b)") == "(seq (group 1 (alt (seq) (seq b))))");
    assert(sexp("(a)+") == "(seq (rep 1 inf (group 1 (seq a))))");
}

unittest // escapes and classes
{
    assert(sexp(`\.\\\(`) == "(seq . \\ ()");
    assert(sexp(`\d`) == "(seq [set:10])");
    assert(sexp(`\W`) == "(seq [set:193])");
    assert(sexp(`[abc]`) == "(seq [set:3])");
    assert(sexp(`[a-z]`) == "(seq [set:26])");
    assert(sexp(`[^a-z]`) == "(seq [set:230])");
    assert(sexp(`[-a]`) == "(seq [set:2])");
    assert(sexp(`[a-]`) == "(seq [set:2])");
    assert(sexp(`[a\-c]`) == "(seq [set:3])");
    assert(sexp(`[\]\\]`) == "(seq [set:2])");
    assert(sexp(`[a^]`) == "(seq [set:2])");
    assert(sexp(`[\d_]`) == "(seq [set:11])");
    assert(sexp(`[.]`) == "(seq [set:1])");
}

unittest // anchors
{
    assert(sexp("^a$") == "(seq bol a eol)");
    assert(sexp("a^b") == "(seq a bol b)");
}

unittest // syntax errors
{
    assertThrown!RegexException(parse("(a"));
    assertThrown!RegexException(parse("a)"));
    assertThrown!RegexException(parse("*a"));
    assertThrown!RegexException(parse("a**"));
    assertThrown!RegexException(parse("^*"));
    assertThrown!RegexException(parse("a{2,1}"));
    assertThrown!RegexException(parse("a{"));
    assertThrown!RegexException(parse("a{x}"));
    assertThrown!RegexException(parse("[abc"));
    assertThrown!RegexException(parse("[z-a]"));
    assertThrown!RegexException(parse(`\q`));
    assertThrown!RegexException(parse(`a\`));
    assertThrown!RegexException(parse("a{99999}"));
}
