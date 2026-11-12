/// A MIME email parser written from scratch.
///
/// Import `mime` to get the whole public API:
///
/// ---
/// import mime;
///
/// auto raw = cast(const(ubyte)[]) "Subject: =?utf-8?Q?hi?=\r\n\r\nbody\r\n";
/// auto msg = parseMessage(raw, "example");
/// assert(msg.textBody.text == "body\n");
/// assert(decodeUnstructured(msg.header("subject").raw) == "hi");
/// ---
///
/// Modules, by responsibility:
/// $(UL
///   $(LI `mime.mailbox`   – mbox splitting and `.eml` directories)
///   $(LI `mime.lines`     – line splitting, CRLF normalisation)
///   $(LI `mime.header`    – header block parsing and unfolding)
///   $(LI `mime.charset`   – ASCII / UTF-8 / Latin-1 / cp1252 decoding)
///   $(LI `mime.encodedword` – RFC 2047 encoded words)
///   $(LI `mime.params`    – structured values and RFC 2231 parameters)
///   $(LI `mime.address`   – address lists)
///   $(LI `mime.date`      – `Date` header and calendar maths)
///   $(LI `mime.transfer`  – quoted-printable, base64, Adler-32)
///   $(LI `mime.multipart` – boundary scanning)
///   $(LI `mime.part`      – the part tree, body and attachment selection)
///   $(LI `mime.escape`    – dump-format escaping)
///   $(LI `mime.report`    – dump rendering and output writing))
module mime;

public import mime.address;
public import mime.charset;
public import mime.date;
public import mime.encodedword;
public import mime.escape;
public import mime.header;
public import mime.lines;
public import mime.mailbox;
public import mime.multipart;
public import mime.params;
public import mime.part;
public import mime.report;
public import mime.text;
public import mime.transfer;
