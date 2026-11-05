module tests.lexer_test;

import jtemplate;

private Tok[] types(string src, size_t seg = 0)
{
    auto r = lex(src);
    Tok[] out_;
    foreach (t; r.tokens[r.segments[seg].tokBegin .. r.segments[seg].tokEnd])
        out_ ~= t.type;
    return out_;
}

unittest // text and tags are split
{
    auto r = lex("a{{ x }}b{% if y %}c{# note #}d");
    assert(r.segments.length == 6);
    assert(r.segments[0].kind == SegKind.text && r.segments[0].text == "a");
    assert(r.segments[1].kind == SegKind.print);
    assert(r.segments[2].text == "b");
    assert(r.segments[3].kind == SegKind.stmt);
    assert(r.segments[4].text == "c");
    assert(r.segments[5].text == "d");
}

unittest // tokens of an expression
{
    assert(types("{{ a.b[1] ** 2 // 3 }}") ==
        [Tok.name, Tok.dot, Tok.name, Tok.lbracket, Tok.integer, Tok.rbracket,
         Tok.pow, Tok.integer, Tok.floorDiv, Tok.integer]);
    assert(types("{{ x <= 1.5 ~ 'a' }}") ==
        [Tok.name, Tok.le, Tok.floating, Tok.tilde, Tok.str]);
    assert(types("{{ not a in b }}") == [Tok.kwNot, Tok.name, Tok.kwIn, Tok.name]);
}

unittest // number literals
{
    auto r = lex("{{ 12 3.25 }}");
    assert(r.tokens[0].type == Tok.integer && r.tokens[0].ival == 12);
    assert(r.tokens[1].type == Tok.floating && r.tokens[1].fval == 3.25);
}

unittest // string escapes
{
    auto r = lex(`{{ "a\n\t\\\"b" 'it\'s' }}`);
    assert(r.tokens[0].text == "a\n\t\\\"b");
    assert(r.tokens[1].text == "it's");
}

unittest // a closer inside a string does not end the tag
{
    auto r = lex(`{{ "}}" }}x`);
    assert(r.segments.length == 2);
    assert(r.tokens[0].text == "}}");
}

unittest // whitespace control trims neighbouring text only
{
    auto r = lex("a  \n {{- x -}}  \n b {%- if y -%} \t c");
    assert(r.segments[0].text == "a");
    assert(r.segments[2].text == "b");
    assert(r.segments[4].text == "c");
}

unittest // comments support whitespace control as well
{
    auto r = lex("a  {#- note -#}  b");
    assert(r.segments.length == 2);
    assert(r.segments[0].text == "a" && r.segments[1].text == "b");
}

unittest // whitespace is not trimmed across another tag
{
    auto r = lex("{{ a }} {# c #} {{- b }}");
    // the space between the first tag and the comment survives
    assert(r.segments[1].text == " ");
}

unittest // "-}}" closes with trimming, "- }}" is a minus operator
{
    assert(types("{{ x -}}") == [Tok.name]);
    assert(types("{{ x - }}") == [Tok.name, Tok.minus]);
}

unittest // lexical errors
{
    foreach (bad; ["{{ x", "{% if", "{# open", `{{ "abc }}`, `{{ "a\q" }}`,
                   "{{ a ! b }}", "{{ a $ b }}", "{{{ x }}}"])
    {
        bool threw;
        try
        {
            auto r = lex(bad);
            // "{{{ x }}}" lexes the brace as a bad character
        }
        catch (TemplateError e)
        {
            threw = e.kind == ErrorKind.syntax;
        }
        assert(threw, bad);
    }
}

unittest // a lone brace is text
{
    auto r = lex("a { b } c {x}");
    assert(r.segments.length == 1);
}
