//! Tests of the public library API.

use mime::{Kind, Message};

#[test]
fn nested_message_and_attachments() {
    let raw = b"Subject: outer\r\n\
Content-Type: multipart/mixed; boundary=\"outer\"\r\n\
\r\n\
--outer\r\n\
Content-Type: multipart/alternative; boundary=inner\r\n\
\r\n\
--inner\r\n\
Content-Type: text/plain; charset=utf-8\r\n\
Content-Transfer-Encoding: quoted-printable\r\n\
\r\n\
caf=C3=A9 =\r\n\
au lait\r\n\
--inner\r\n\
Content-Type: text/html\r\n\
\r\n\
<b>hi</b>\r\n\
--inner--\r\n\
--outer\r\n\
Content-Type: message/rfc822\r\n\
\r\n\
Subject: forwarded\r\n\
Content-Type: text/plain\r\n\
\r\n\
inner text\r\n\
--outer--\r\n";
    let m = Message::parse(raw);
    assert_eq!(m.parts.len(), 6);
    assert_eq!(m.text_body, Some(2));
    assert_eq!(m.html_body, Some(3));
    assert_eq!(m.attachments, vec![5]);
    assert_eq!(m.parts[2].text.as_deref(), Some("café au lait"));
    assert!(matches!(m.parts[4].kind, Kind::Message));
    assert_eq!(m.parts[5].content, b"inner text");
    assert_eq!(m.size, raw.len());
    assert_eq!(m.parts[4].children, 1);
}

#[test]
fn degenerate_input_does_not_panic() {
    for raw in [&b""[..], b"\n", b"\r\n\r\n", b":", b"A:", b"Content-Type: multipart/mixed; boundary=\n\n--\n"] {
        let m = Message::parse(raw);
        assert_eq!(m.parts[0].index, 0);
    }
}

#[test]
fn dates_and_addresses() {
    let m = Message::parse(b"Date: Tue, 1 Jan 2036 00:00:60 +0000\nCc: g: a@b.c, d@e.f;\n\n");
    let d = m.date().unwrap().parsed.unwrap();
    assert_eq!(d.epoch, 2082758460);
    assert_eq!(d.utc(), "2036-01-01T00:01:00Z");
    let specs: Vec<String> = m.addresses("cc").into_iter().map(|a| a.spec).collect();
    assert_eq!(specs, ["a@b.c", "d@e.f"]);
}
