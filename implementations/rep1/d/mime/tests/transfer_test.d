module tests.transfer_test;

import mime.transfer;

private const(ubyte)[] b(string s) { return cast(const(ubyte)[]) s; }

unittest // quoted-printable
{
    assert(decodeQuotedPrintable(b("a=20b")) == b("a b"));
    assert(decodeQuotedPrintable(b("a=\nb")) == b("ab"));
    assert(decodeQuotedPrintable(b("a=3Db")) == b("a=b"));
    assert(decodeQuotedPrintable(b("a=Zb")) == b("a=Zb"));
    assert(decodeQuotedPrintable(b("a=3\n")) == b("a=3\n"));
    assert(decodeQuotedPrintable(b("abc=")) == b("abc"));
    assert(decodeQuotedPrintable(b("=0D=0A")) == b("\r\n"));
    assert(decodeQuotedPrintable(b("x  \ny")) == b("x  \ny"));
    assert(decodeQuotedPrintable(b("=e9")) == b("\xE9"));
}

unittest // base64
{
    assert(decodeBase64(b("AAECAw==")) == [0, 1, 2, 3]);
    assert(decodeBase64(b("TWFu")) == b("Man"));
    assert(decodeBase64(b("TW\nFu\n")) == b("Man"));
    assert(decodeBase64(b("TWE")) == b("Ma"));
    assert(decodeBase64(b("TQ")) == b("M"));
    assert(decodeBase64(b("T")) == []);
    assert(decodeBase64(b("")) == []);
    assert(decodeBase64(b("T!Q?=")) == b("M"));
}

unittest // decodeBody dispatch
{
    assert(decodeBody(b("a=20"), "7bit") == b("a=20"));
    assert(decodeBody(b("a=20"), "x-unknown") == b("a=20"));
    assert(decodeBody(b("a=20"), "quoted-printable") == b("a "));
    assert(decodeBody(b("TWFu"), "base64") == b("Man"));
}
