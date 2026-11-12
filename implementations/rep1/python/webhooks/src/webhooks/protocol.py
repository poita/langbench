"""The line-oriented command protocol (see the README for the grammar).

:func:`run` takes the whole input as bytes and returns the output lines.  Every
malformed command yields the single word ``error``; nothing raises.
"""

from __future__ import annotations

import re
from collections.abc import Callable, Iterator

from .b64 import Base64Error, b64decode, b64encode, b64urlencode
from .hmac_sha256 import hmac_sha256
from .secret import InvalidSecret, parse_secret
from .sha256 import sha256
from .signing import sign
from .simulator import Endpoint, Event, simulate
from .timestamp import parse_canonical_int
from .verification import verify

__all__ = ["run", "ProtocolError", "MAX_ENDPOINTS", "MAX_EVENTS", "MAX_SECRETS"]

MAX_ENDPOINTS = 64
MAX_EVENTS = 20000
MAX_SECRETS = 16

ERROR = "error"


class ProtocolError(ValueError):
    """A command line (or simulate block) that violates the grammar."""


_HEX = re.compile(rb"-|(?:[0-9a-f]{2})+")
_SECRET = re.compile(rb"[\x21-\x2b\x2d-\x7e]{1,512}")
_ID = re.compile(rb"[\x21-\x7e]{1,256}")
_RECEIVED_TS = re.compile(rb"[\x21-\x7e]{1,64}")
_NAME = re.compile(rb"[A-Za-z0-9_.\-]{1,64}")
_RESPONSE = re.compile(rb"[1-5][0-9]{2}")


# ---------------------------------------------------------------- field kinds

def _hex(field: bytes) -> bytes:
    if _HEX.fullmatch(field) is None:
        raise ProtocolError("bad hex")
    return b"" if field == b"-" else bytes.fromhex(field.decode("ascii"))


def _secret(field: bytes) -> bytes:
    if _SECRET.fullmatch(field) is None:
        raise ProtocolError("bad secret")
    try:
        return parse_secret(field)
    except InvalidSecret:
        raise ProtocolError("bad secret") from None


def _secrets(field: bytes) -> tuple[bytes, ...]:
    entries = field.split(b",")
    if len(entries) > MAX_SECRETS:
        raise ProtocolError("too many secrets")
    return tuple(_secret(e) for e in entries)


def _id(field: bytes) -> bytes:
    if _ID.fullmatch(field) is None:
        raise ProtocolError("bad id")
    return field


def _int(field: bytes) -> int:
    value = parse_canonical_int(field)
    if value is None:
        raise ProtocolError("bad integer")
    return value


def _name(field: bytes) -> str:
    if _NAME.fullmatch(field) is None:
        raise ProtocolError("bad name")
    return field.decode("ascii")


def _hexout(data: bytes) -> str:
    return data.hex() if data else "-"


def _arity(fields: list[bytes], count: int) -> None:
    if len(fields) != count:
        raise ProtocolError("wrong number of fields")


# ------------------------------------------------------------------- commands

def _cmd_sha256(f: list[bytes]) -> str:
    _arity(f, 2)
    return sha256(_hex(f[1])).hex()


def _cmd_hmac(f: list[bytes]) -> str:
    _arity(f, 3)
    return hmac_sha256(_hex(f[1]), _hex(f[2])).hex()


def _cmd_b64enc(f: list[bytes]) -> str:
    _arity(f, 2)
    return b64encode(_hex(f[1])) or "-"


def _cmd_b64urlenc(f: list[bytes]) -> str:
    _arity(f, 2)
    return b64urlencode(_hex(f[1])) or "-"


def _cmd_b64dec(f: list[bytes]) -> str:
    _arity(f, 2)
    text = _hex(f[1])
    try:
        return _hexout(b64decode(text))
    except Base64Error:
        raise ProtocolError("bad base64") from None


def _cmd_secret(f: list[bytes]) -> str:
    _arity(f, 2)
    return _hexout(_secret(f[1]))


def _cmd_sign(f: list[bytes]) -> str:
    _arity(f, 5)
    keys = _secrets(f[1])
    msg_id = _id(f[2])
    ts = _int(f[3])
    payload = _hex(f[4])
    return sign(keys, msg_id, ts, payload)


def _cmd_verify(f: list[bytes]) -> str:
    _arity(f, 7)
    keys = _secrets(f[1])
    msg_id = _id(f[2])
    if _RECEIVED_TS.fullmatch(f[3]) is None:
        raise ProtocolError("bad timestamp field")
    now = _int(f[4])
    header = _hex(f[5])
    payload = _hex(f[6])
    return str(verify(keys, msg_id, f[3], header, payload, now))


# ------------------------------------------------------------ simulate blocks

def _endpoint(f: list[bytes]) -> Endpoint:
    _arity(f, 5)
    ep_id = _name(f[1])
    keys = _secrets(f[2])
    if f[3] == b"*":
        types = None
    else:
        entries = f[3].split(b",")
        if len(entries) > 16:
            raise ProtocolError("too many event types")
        types = frozenset(_name(e) for e in entries)
    entries = f[4].split(b",")
    if len(entries) > 64:
        raise ProtocolError("script too long")
    script = []
    for e in entries:
        if e == b"timeout":
            script.append(None)
        elif _RESPONSE.fullmatch(e):
            script.append(int(e))
        else:
            raise ProtocolError("bad response")
    return Endpoint(ep_id, keys, types, tuple(script))


def _event(f: list[bytes]) -> Event:
    _arity(f, 5)
    return Event(_name(f[1]), _int(f[2]), _name(f[3]), _hex(f[4]))


def _read_block(lines: Iterator[bytes]) -> list[str]:
    """Consume a simulate block (after ``simulate``) and return its output."""
    endpoints: list[Endpoint] = []
    events: list[Event] = []
    ep_ids: set[str] = set()
    ev_ids: set[str] = set()
    valid = True
    terminated = False
    for line in lines:
        if line == b"end":
            terminated = True
            break
        if not valid:
            continue  # skip to the terminating "end"
        fields = line.split(b" ")
        try:
            if fields[0] == b"endpoint" and not events:
                ep = _endpoint(fields)
                if ep.id in ep_ids or len(endpoints) >= MAX_ENDPOINTS:
                    raise ProtocolError("duplicate or too many endpoints")
                ep_ids.add(ep.id)
                endpoints.append(ep)
            elif fields[0] == b"event":
                ev = _event(fields)
                if ev.id in ev_ids or len(events) >= MAX_EVENTS:
                    raise ProtocolError("duplicate or too many events")
                ev_ids.add(ev.id)
                events.append(ev)
            else:
                raise ProtocolError("unexpected line in block")
        except ProtocolError:
            valid = False
    if not (terminated and valid and endpoints):
        return [ERROR]
    return simulate(endpoints, events).lines()


# ------------------------------------------------------------------- dispatch

_COMMANDS: dict[bytes, Callable[[list[bytes]], str]] = {
    b"sha256": _cmd_sha256,
    b"hmac": _cmd_hmac,
    b"b64enc": _cmd_b64enc,
    b"b64urlenc": _cmd_b64urlenc,
    b"b64dec": _cmd_b64dec,
    b"secret": _cmd_secret,
    b"sign": _cmd_sign,
    b"verify": _cmd_verify,
}


def _significant_lines(data: bytes) -> Iterator[bytes]:
    for line in data.split(b"\n"):
        if line.strip(b" "):
            yield line


def run(data: bytes) -> list[str]:
    """Execute every command in *data*; return the output lines in order."""
    out: list[str] = []
    lines = _significant_lines(data)
    for line in lines:
        fields = line.split(b" ")
        if fields == [b"simulate"]:
            out.extend(_read_block(lines))
            continue
        handler = _COMMANDS.get(fields[0])
        if handler is None:
            out.append(ERROR)
            continue
        try:
            out.append(handler(fields))
        except ProtocolError:
            out.append(ERROR)
    return out
