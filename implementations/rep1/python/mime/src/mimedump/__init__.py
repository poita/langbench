"""mimedump: a from-scratch MIME email parser.

Public API::

    from mimedump import parse_message, read_mailbox, render_message

    msg = parse_message(raw_bytes)
    msg.text_part.text            # decoded plain-text body
    for part in msg.attachments:
        part.filename, part.content

    for number, raw in enumerate(read_mailbox("archive.mbox"), 1):
        print(render_message(parse_message(raw.data), number, raw.source_id))

``dump_mailbox(input_path, output_dir)`` does what the command-line tool does.
Lower-level pieces (charset decoding, RFC 2047, addresses, dates, transfer
decoding) are available from their own modules.
"""

from .addresses import Address, parse_address_list
from .charsets import decode as decode_charset
from .checksum import adler32
from .dates import ParsedDate, parse_date
from .headers import Header
from .mailbox import RawMessage, read_mailbox, split_mbox
from .message import Message, parse_message
from .parts import Kind, Part
from .report import dump_mailbox, dump_messages, render_message
from .rfc2047 import decode_unstructured
from .structured import StructuredValue, parse_structured
from .transfer import decode_base64, decode_body, decode_quoted_printable

__version__ = "1.0.0"

__all__ = [
    "Address",
    "Header",
    "Kind",
    "Message",
    "ParsedDate",
    "Part",
    "RawMessage",
    "StructuredValue",
    "adler32",
    "decode_base64",
    "decode_body",
    "decode_charset",
    "decode_quoted_printable",
    "decode_unstructured",
    "dump_mailbox",
    "dump_messages",
    "parse_address_list",
    "parse_date",
    "parse_message",
    "parse_structured",
    "read_mailbox",
    "render_message",
    "split_mbox",
]
