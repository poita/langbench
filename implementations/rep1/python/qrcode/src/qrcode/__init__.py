"""A dependency-free QR Code Model 2 (ISO/IEC 18004) encoder.

Public API::

    from qrcode import encode_text, encode_bytes, ErrorCorrection, QrCode

    qr = encode_text("HELLO WORLD", ErrorCorrection.M)   # auto mask
    print(qr.version, qr.mask)
    print(qr.to_text())

A single data segment is emitted (numeric, alphanumeric or byte mode, chosen
automatically) and no ECI header is written.
"""

from .encoder import encode_bytes, encode_text
from .errors import DataTooLongError, InvalidQueryError, QrError
from .symbol import QrCode
from .tables import ErrorCorrection

__all__ = [
    "DataTooLongError",
    "ErrorCorrection",
    "InvalidQueryError",
    "QrCode",
    "QrError",
    "encode_bytes",
    "encode_text",
]

__version__ = "1.0.0"
