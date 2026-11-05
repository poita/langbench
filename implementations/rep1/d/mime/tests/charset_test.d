module tests.charset_test;

import mime.charset;

private const(ubyte)[] b(string s) { return cast(const(ubyte)[]) s; }

unittest // charset names
{
    assert(charsetFor(" UTF-8 ") == Charset.utf8);
    assert(charsetFor("ISO-8859-1") == Charset.latin1);
    assert(charsetFor("US-ASCII") == Charset.ascii);
    assert(charsetFor("windows-1252") == Charset.cp1252);
    assert(charsetFor("koi8-r") == Charset.cp1252);
    assert(charsetFor("") == Charset.cp1252);
}

unittest // single-byte tables
{
    assert(decode(b("caf\xE9"), "latin1") == "café");
    assert(decode(b("smart\x92quote"), "windows-1252") == "smart’quote");
    assert(decode(b("\x81\x80"), "cp1252") == "\u0081€");
    assert(decode(b("a\xE9"), "us-ascii") == "a�");
    assert(decode(b("\x80"), "latin1") == "\u0080");
}

unittest // UTF-8 maximal subpart replacement
{
    assert(decode(b("\xE2\x28\xA1"), "utf-8") == "�(�");
    assert(decode(b("ab\xF0\x9F"), "utf-8") == "ab�");
    assert(decode(b("\xC0\xAF"), "utf-8") == "��");
    assert(decode(b("\xED\xA0\x80"), "utf-8") == "���");
    assert(decode(b("\xE0\x80\x80"), "utf-8") == "���");
    assert(decode(b("\xF4\x90\x80\x80"), "utf-8") == "����");
    assert(decode(b("\xE1\x80\x41"), "utf-8") == "�A");
    assert(decode(b("héllo € \U0001F600"), "utf-8") == "héllo € \U0001F600");
}

unittest // code point counting
{
    assert(codePointCount("café €") == 6);
    assert(codePointCount("") == 0);
}
