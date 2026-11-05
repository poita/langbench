module tests.render_test;

import mime.buffer;
import mime.message;
import mime.render;

private string esc(string s)
{
    ByteBuffer o;
    putEscaped(o, s);
    return o.toString();
}

unittest // esc
{
    assert(esc("a\\b\n\r\t\"") == `a\\b\n\r\t\"`);
    assert(esc("\x01\x7F") == `\x01\x7f`);
    assert(esc("é€") == "é€");
    assert(esc("\u0080\u009F ") == "\\x80\\x9f ");
    assert(esc("") == "");
}

unittest // the worked example from the specification
{
    auto raw = "Subject: =?utf-8?Q?Caf=C3=A9?= report\n"
        ~ "From: Ann Example <ann@example.com>\n"
        ~ "To: bob@example.org, Carl <carl@example.org>\n"
        ~ "Date: Mon, 1 Sep 2025 12:30:00 +0200\n"
        ~ "MIME-Version: 1.0\n"
        ~ "Content-Type: multipart/mixed; boundary=\"X\"\n\n"
        ~ "ignore me\n--X\nContent-Type: text/plain; charset=iso-8859-1\n\ncaf\xE9\n--X\n"
        ~ "Content-Type: application/octet-stream\nContent-Disposition: attachment; filename=\"a.bin\"\n"
        ~ "Content-Transfer-Encoding: base64\n\nAAECAw==\n--X--\n";
    auto msg = parseMessage(cast(const(ubyte)[]) raw);
    ByteBuffer o;
    renderMessage(o, 1, "mbox:1", msg);
    immutable expected = `[message]
id 0001
source "mbox:1"

[headers]
subject: "Café report"
from: "Ann Example <ann@example.com>"
to: "bob@example.org, Carl <carl@example.org>"
date: "Mon, 1 Sep 2025 12:30:00 +0200"
mime-version: "1.0"
content-type: "multipart/mixed; boundary=\"X\""

[addresses]
from 0 display="Ann Example" spec="ann@example.com"
to 0 display="" spec="bob@example.org"
to 1 display="Carl" spec="carl@example.org"

[date]
raw " Mon, 1 Sep 2025 12:30:00 +0200"
valid yes
utc 2025-09-01T10:30:00Z
offset +0200
epoch 1756722600

[structure]
0 multipart/mixed cte=7bit boundary="X" parts=2 preamble=9 epilogue=0
  1 text/plain charset=iso-8859-1 cte=7bit size=4 adler32=04680214 role=text
  2 application/octet-stream cte=base64 disposition=attachment filename="a.bin" size=4 adler32=000e0007 role=attachment

[body]
text 1 chars 4
| café
html none

[attachments]
2 type=application/octet-stream filename="a.bin" size=4 adler32=000e0007 file=parts/0001/002.bin
`;
    assert(o.toString() == expected);

    ByteBuffer s;
    putSummaryLine(s, 1, "mbox:1", 427, msg);
    assert(s.toString() == "0001 source=\"mbox:1\" bytes=427 parts=3 attachments=1 text=1 html=-\n");
}

unittest // body lines
{
    auto msg = parseMessage(cast(const(ubyte)[]) "\na\n\n");
    ByteBuffer o;
    renderMessage(o, 2, "x.eml", msg);
    import std.algorithm.searching : canFind;
    assert(o.toString().canFind("text 0 chars 3\n| a\n| \nhtml none\n"));
}

unittest // attachment paths
{
    assert(attachmentPath(12, 3) == "parts/0012/003.bin");
}
