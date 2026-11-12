"""Standard Webhooks signing and verification, plus a delivery simulator.

SHA-256, HMAC-SHA-256 and Base64 are implemented from scratch (standard library
only).  Public API::

    sha256(data) -> bytes
    hmac_sha256(key, message) -> bytes
    b64encode / b64urlencode / b64decode
    parse_secret(secret) -> bytes
    sign(keys, msg_id, timestamp, body) -> str
    verify(keys, msg_id, timestamp, header, body, now) -> VerifyResult
    simulate(endpoints, events) -> SimulationResult
"""

from .b64 import Base64Error, b64decode, b64encode, b64urlencode
from .hmac_sha256 import hmac_sha256
from .secret import InvalidSecret, parse_secret
from .sha256 import sha256
from .signing import sign, sign_one, signed_content
from .simulator import Attempt, Delivery, Endpoint, Event, SimulationResult, simulate
from .verification import Failure, VerifyResult, verify

__version__ = "1.0.0"

__all__ = [
    "Attempt", "Base64Error", "Delivery", "Endpoint", "Event", "Failure",
    "InvalidSecret", "SimulationResult", "VerifyResult", "b64decode",
    "b64encode", "b64urlencode", "hmac_sha256", "parse_secret", "sha256",
    "sign", "sign_one", "signed_content", "simulate", "verify",
]
