module tests.mailbox_test;

import mime.mailbox;

private const(ubyte)[] b(string s) { return cast(const(ubyte)[]) s; }

unittest // separator rules
{
    // text before the first separator is discarded
    auto m = splitMbox(b("preamble\n\nFrom a\nS: 1\n\nbody\n\nFrom b\nS: 2\n\n"));
    assert(m.length == 2);
    assert(m[0].data == b("S: 1\n\nbody\n"));
    assert(m[1].data == b("S: 2\n"));
}

unittest // messages, the trailing blank line and source ids
{
    auto m = splitMbox(b("From x Mon\nS: 1\n\nbody\n\nFrom y\nS: 2\n\nbody2\n"));
    assert(m.length == 2);
    assert(m[0].sourceId == "mbox:1" && m[1].sourceId == "mbox:2");
    assert(m[0].data == b("S: 1\n\nbody\n"));
    assert(m[1].data == b("S: 2\n\nbody2\n"));
}

unittest // a "From " line not preceded by an empty line is body text
{
    // this "From " line follows an empty line, so it is a separator
    auto m = splitMbox(b("From x\nS: 1\n\nFrom y?\n\nbody\n"));
    assert(m.length == 2);
    auto m2 = splitMbox(b("From x\nS: 1\nFrom y\nmore\n"));
    assert(m2.length == 1 && m2[0].data == b("S: 1\nFrom y\nmore\n"));
}

unittest // no separator, no messages; empty message
{
    assert(splitMbox(b("S: 1\n\nbody\n")).length == 0);
    assert(splitMbox(b("")).length == 0);
    auto m = splitMbox(b("From x\n"));
    assert(m.length == 1 && m[0].data.length == 0);
    auto crlf = splitMbox(b("From x\r\nS: 1\r\n\r\nFrom y\r\nT: 2\r\n"));
    assert(crlf.length == 2);
}
