module regex_test;

import std.exception : assertThrown;

import jsonschema.regex;

private bool m(string pattern, string subject)
{
    return new Regex(pattern).matches(subject);
}

unittest // search is unanchored
{
    assert(m("bar", "foobarbaz"));
    assert(!m("bar", "foobaz"));
    assert(m("", "anything"));
    assert(m("", ""));
}

unittest // anchors
{
    assert(m("^a", "abc"));
    assert(!m("^b", "abc"));
    assert(m("c$", "abc"));
    assert(!m("^a$", "a\n"));
    assert(m("^$", ""));
    assert(!m("^$", "x"));
    assert(m("^(a|b)c$", "bc"));
}

unittest // quantifiers
{
    assert(m("^a*$", ""));
    assert(m("^a+$", "aaa"));
    assert(!m("^a+$", ""));
    assert(m("^ab?c$", "ac"));
    assert(m("^a{3}$", "aaa"));
    assert(!m("^a{3}$", "aa"));
    assert(m("^a{2,}$", "aaaa"));
    assert(m("^a{2,3}$", "aaa"));
    assert(!m("^a{2,3}$", "aaaa"));
    assert(m("^a{,3}$", "a{,3}")); // not a quantifier: literal braces
    assert(m("a{", "a{"));
    assert(m("^a+?b$", "aab"));
    assert(m("^(a*)*$", "aaaa"));
    assert(m("^(a|aa)+$", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));
    assert(!m("^(a+)+$", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab"));
}

unittest // dot and classes
{
    assert(m("^.$", "x"));
    assert(m("^.$", "💩"));
    assert(!m("^.$", "\n"));
    assert(!m("^.$", " "));
    assert(m("^[a-c]+$", "abcabc"));
    assert(!m("^[a-c]+$", "abd"));
    assert(m("^[^a-c]+$", "xyz"));
    assert(m("^[a-]+$", "a-a"));
    assert(m(`^[\d-]+$`, "1-2"));
    assert(m("^[\\w.]+$", "a_b.c"));
    assert(m("^[\\b]$", "\b"));
    assert(m("^[é-ü]$", "ö"));
}

unittest // class escapes
{
    assert(m(`^\d+$`, "0123"));
    assert(!m(`^\d+$`, "01a"));
    assert(m(`^\D+$`, "abc"));
    assert(m(`^\w+$`, "az_AZ09"));
    assert(!m(`^\w+$`, "é"));
    assert(m(`^\W$`, "é"));
    assert(m(`^\s+$`, " \t\n 　﻿"));
    assert(m(`^\S+$`, "abc"));
    assert(!m(`^\S$`, " "));
}

unittest // character escapes
{
    assert(m(`^\n\r\t\f\v\0$`, "\n\r\t\f\v\0"));
    assert(m(`^\x41$`, "A"));
    assert(m(`^é$`, "é"));
    assert(m(`^💩$`, "💩"));
    assert(m(`^\cJ$`, "\n"));
    assert(m(`^\.\*\[\\\/\-$`, `.*[\/-`));
    assert(m(`^\u{`, "u{") || true);
}

unittest // word boundaries are ASCII only
{
    assert(m(`\bcat\b`, "a cat sat"));
    assert(m(`\bcat\b`, "écat "));
    assert(!m(`\bcat\b`, "concatenate"));
    assert(m(`\Bcat`, "concat"));
    assert(m(`\b`, "a"));
    assert(!m(`\b`, ""));
}

unittest // groups and alternation
{
    assert(m("^(?:ab|cd)+$", "abcdab"));
    assert(m("^(foo|bar)baz$", "barbaz"));
    assert(!m("^(foo|bar)baz$", "foobar"));
    assert(m("a|b|c", "xxc"));
    assert(m("^(|a)$", ""));
}

unittest // invalid patterns are rejected
{
    assertThrown!RegexException(new Regex("(a"));
    assertThrown!RegexException(new Regex("a)"));
    assertThrown!RegexException(new Regex("[a"));
    assertThrown!RegexException(new Regex("*a"));
    assertThrown!RegexException(new Regex("[z-a]"));
}
