module tests.address_test;

import std.array : join;
import std.algorithm : map;

import mime.address;

private string show(string v)
{
    string[] r;
    foreach (a; parseAddressList(v))
        r ~= a.display ~ " | " ~ a.spec;
    return r.join(" ; ");
}

unittest // examples from the specification
{
    assert(show("Real Name <user@example.com>") == "Real Name | user@example.com");
    assert(show("user@example.com (Real Name)") == " | user@example.com");
    assert(show(`"Doe, John" <jd@x.com>`) == "Doe, John | jd@x.com");
    assert(show("a@b.com, (c) d@e.com") == " | a@b.com ;  | d@e.com");
    assert(show("Undisclosed recipients:;") == "");
    assert(show("grp: a@b.com, c@d.com;") == " | a@b.com ;  | c@d.com");
    assert(show("=?utf-8?B?SsO2cmc=?= <j@x.de>") == "Jörg | j@x.de");
    assert(show("foo (c (nested)) <a@b>") == "foo | a@b");
    assert(show("ed <a@[10.0.0.1]>") == "ed | a@[10.0.0.1]");
    assert(show("broken <a@@b>") == " | broken<a@@b>");
    assert(show("John Q. Public <jqp@example.com>") == "John Q. Public | jqp@example.com");
    assert(show("Symantec Email Proxy") == " | SymantecEmailProxy");
    assert(show(`"=?utf-8?Q?x?=" <a@b>`) == "=?utf-8?Q?x?= | a@b");
    assert(show("a <b <c@d.com> , e@f.com>, g@h.com") == " | a<b<c@d.com>,e@f.com> ;  | g@h.com");
    assert(show("John (the third) Public <jqp@x.com>") == "John   Public | jqp@x.com");
}

unittest // address shapes
{
    assert(show("a.b@c.d.e") == " | a.b@c.d.e");
    assert(show(`"q u"@host`) == " | q u@host");
    assert(show("a..b@c") == " | a..b@c");   // fallback rendering joins the tokens
    assert(show("local") == " | local");
    assert(show("a@") == " | a@");
    assert(show("<>") == " | <>");
    assert(show("") == "");
    assert(show(" , ,") == "");
    assert(show("x <a@b") == " | x<a@b");
}

unittest // tokenizer
{
    auto t = tokenize(`a (c) "q" [d] =?utf-8?Q?x?= <>`);
    assert(t.length == 6);
    assert(t[0].kind == TokenKind.atom && t[1].kind == TokenKind.quoted
        && t[2].kind == TokenKind.literal && t[3].kind == TokenKind.encoded
        && t[4].kind == TokenKind.special && t[4].start == 28);
    auto stray = tokenize(") ] \\");
    assert(stray.length == 3 && stray[2].text == "\\");
}
