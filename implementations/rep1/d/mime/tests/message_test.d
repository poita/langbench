module tests.message_test;

import mime.message;

private Message parse(string s)
{
    return parseMessage(cast(const(ubyte)[]) s);
}

unittest // line endings
{
    assert(normalizeLineEndings(cast(const(ubyte)[]) "a\r\nb\rc\r\n\r\n") == cast(const(ubyte)[]) "a\nb\rc\n\n");
    assert(normalizeLineEndings([]) == []);
}

unittest // a simple text message with defaults
{
    auto m = parse("Subject: hi\n\nhello\n");
    assert(m.parts.length == 1);
    assert(m.parts[0].mediaType == "text/plain");
    assert(m.parts[0].charset == "us-ascii");
    assert(m.parts[0].encoding == "7bit");
    assert(m.textIndex == 0 && m.htmlIndex == noPart);
    assert(m.text == "hello\n");
    assert(m.attachments.length == 0);
}

unittest // multipart structure, preamble and epilogue
{
    auto m = parse("Content-Type: multipart/mixed; boundary=\"X\"\r\n\r\nignore me\r\n--X\r\n"
        ~ "Content-Type: text/plain; charset=iso-8859-1\r\n\r\ncaf\xE9\r\n--X\r\n"
        ~ "Content-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=\"a.bin\"\r\n"
        ~ "Content-Transfer-Encoding: base64\r\n\r\nAAECAw==\r\n--X--\r\nbye\r\n");
    assert(m.parts.length == 3);
    assert(m.parts[0].kind == PartKind.multipart);
    assert(m.parts[0].childCount == 2);
    assert(m.parts[0].preambleLength == 9);
    assert(m.parts[0].hasEpilogue && m.parts[0].epilogueLength == 4);
    assert(m.textIndex == 1 && m.text == "café");
    assert(m.attachments == [2]);
    assert(m.parts[2].filename == "a.bin" && m.parts[2].content == [0, 1, 2, 3]);
    assert(m.parts[2].checksum == 0x000e0007);
    assert(m.parts[2].depth == 1);
}

unittest // degenerate multiparts
{
    auto none = parse("Content-Type: multipart/mixed; boundary=X\n\nno delimiters\n");
    assert(none.parts.length == 1 && none.parts[0].childCount == 0);
    assert(none.parts[0].preambleLength == 14 && !none.parts[0].hasEpilogue);

    auto empty = parse("Content-Type: multipart/mixed; boundary=X\n\n--X\n--X\n\n--X--\n");
    assert(empty.parts.length == 3);
    assert(empty.parts[1].content.length == 0);   // two delimiters in a row bound an empty part

    auto open = parse("Content-Type: multipart/mixed; boundary=X\n\n--X\n\nlast\n");
    assert(open.parts.length == 2 && open.parts[0].hasEpilogue == false);
    assert(open.text == "last");

    auto blank = parse("Content-Type: multipart/mixed; boundary=\n\nx\n");
    assert(blank.parts[0].kind == PartKind.leaf);
}

unittest // delimiter lines tolerate trailing blanks, not trailing text
{
    auto m = parse("Content-Type: multipart/mixed; boundary=X\n\n--X \t\n\na\n--Xy\nb\n--X--  \n");
    assert(m.parts.length == 2);
    assert(m.text == "a\n--Xy\nb");
}

unittest // message/rfc822 and digest defaults
{
    auto m = parse("Content-Type: message/rfc822\n\nSubject: inner\n\ninner body\n");
    assert(m.parts.length == 2 && m.parts[0].kind == PartKind.messageContainer);
    assert(m.parts[1].depth == 1);
    assert(m.textIndex == noPart);          // inner parts are never body candidates
    assert(m.attachments == [1]);

    auto d = parse("Content-Type: multipart/digest; boundary=D\n\n--D\n\nSubject: s\n\nb\n--D--\n");
    assert(d.parts[1].mediaType == "message/rfc822");
    assert(d.parts.length == 3);
}

unittest // body selection
{
    auto m = parse("Content-Type: multipart/mixed; boundary=B\n\n"
        ~ "--B\nContent-Type: text/plain\nContent-Disposition: attachment; filename=n.txt\n\nfile\n"
        ~ "--B\nContent-Type: text/plain\n\nbody\n"
        ~ "--B\nContent-Type: text/plain\n\nsecond\n"
        ~ "--B\nContent-Type: text/html\n\n<p>x</p>\n--B--\n");
    assert(m.textIndex == 2 && m.htmlIndex == 4);
    assert(m.attachments == [1, 3]);
    assert(m.parts[1].role == Role.attachment && m.parts[2].role == Role.text);
}

unittest // invalid content types fall back to text/plain
{
    assert(parse("Content-Type: bogus\n\nx").parts[0].mediaType == "text/plain");
    assert(parse("Content-Type: a b/c\n\nx").parts[0].mediaType == "text/plain");
    assert(parse("Content-Type: Text/HTML; charset=\" UTF-8 \"\n\nx").parts[0].charset == "utf-8");
}

unittest // filenames come from the disposition first, then the type
{
    auto m = parse("Content-Type: application/x; name=t.bin\nContent-Disposition: attachment; filename*=utf-8''d.bin\n\nx");
    assert(m.parts[0].filename == "d.bin");
    m = parse("Content-Type: application/x; name=t.bin\n\nx");
    assert(m.parts[0].hasFilename && m.parts[0].filename == "t.bin");
    m = parse("Content-Type: application/x\n\nx");
    assert(!m.parts[0].hasFilename);
}
