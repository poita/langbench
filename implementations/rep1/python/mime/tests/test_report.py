from mimedump import parse_message, render_message
from mimedump.report import esc, q

WORKED_EXAMPLE_MESSAGE = (
    b"Subject: =?utf-8?Q?Caf=C3=A9?= report\n"
    b"From: Ann Example <ann@example.com>\n"
    b"To: bob@example.org, Carl <carl@example.org>\n"
    b"Date: Mon, 1 Sep 2025 12:30:00 +0200\n"
    b"MIME-Version: 1.0\n"
    b'Content-Type: multipart/mixed; boundary="X"\n'
    b"\n"
    b"ignore me\n"
    b"--X\n"
    b"Content-Type: text/plain; charset=iso-8859-1\n"
    b"\n"
    b"caf\xe9\n"
    b"--X\n"
    b"Content-Type: application/octet-stream\n"
    b'Content-Disposition: attachment; filename="a.bin"\n'
    b"Content-Transfer-Encoding: base64\n"
    b"\n"
    b"AAECAw==\n"
    b"--X--\n"
)

EXPECTED = """\
[message]
id 0001
source "mbox:1"

[headers]
subject: "Café report"
from: "Ann Example <ann@example.com>"
to: "bob@example.org, Carl <carl@example.org>"
date: "Mon, 1 Sep 2025 12:30:00 +0200"
mime-version: "1.0"
content-type: "multipart/mixed; boundary=\\"X\\""

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
"""


def test_worked_example():
    msg = parse_message(WORKED_EXAMPLE_MESSAGE)
    assert msg.size == 427
    assert render_message(msg, 1, "mbox:1") == EXPECTED
    assert msg.attachments[0].content == b"\x00\x01\x02\x03"


def test_esc_table():
    assert esc('\\\n\r\t"\x00\x1f\x7f\x80\x9f\xa0é€') == '\\\\\\n\\r\\t\\"\\x00\\x1f\\x7f\\x80\\x9f\xa0é€'
    assert q("a") == '"a"'


def test_body_line_splitting():
    def body(text_lines):
        raw = b"Content-Type: text/plain\n\n" + text_lines
        out = render_message(parse_message(raw), 1, "s")
        return out.split("[body]\n")[1].split("\n\n")[0].splitlines()

    assert body(b"a\nb\n") == ["text 0 chars 4", "| a", "| b", "html none"]
    assert body(b"a\n\n") == ["text 0 chars 3", "| a", "| ", "html none"]
    assert body(b"a") == ["text 0 chars 1", "| a", "html none"]
    assert body(b"") == ["text 0 chars 0", "html none"]


def test_headerless_message_renders_all_sections():
    out = render_message(parse_message(b""), 7, "x.eml")
    assert out.startswith("[message]\nid 0007\nsource \"x.eml\"\n\n[headers]\n\n[addresses]\n\n[date]\nnone\n")
    assert out.endswith("[attachments]\n")


def test_invalid_date_rendering():
    out = render_message(parse_message(b"Date: nope\n\nx"), 1, "s")
    assert '[date]\nraw " nope"\nvalid no\n\n[structure]' in out
