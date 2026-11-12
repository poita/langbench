import pytest

from webhooks import (
    Failure, InvalidSecret, parse_secret, sign, signed_content, verify,
)

SECRET = "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw"
KEY = parse_secret(SECRET)
MSG_ID = "msg_p5jXN8AQM9LWM0D4loKWxJek"
TS = "1614265330"
BODY = b'{"test": 2432232314}'
SIG = "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE="


def test_secret_forms():
    assert KEY.hex() == "31f290f6bf06298aab4f08d43c3f082cf648a362da2da4b0"
    assert parse_secret("MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw") == KEY
    assert len(parse_secret("whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSwBr")) == 25


def test_secret_prefix_stripped_once():
    # the second prefix is base64 data: "whsec_QQ" is 8 url-safe characters
    from webhooks import b64decode

    assert parse_secret("whsec_whsec_QQ") == b64decode("whsec_QQ")
    assert len(parse_secret("whsec_whsec_QQ")) == 6


@pytest.mark.parametrize("bad", ["", "whsec_", "!!!", "A", "ab+-"])
def test_invalid_secrets(bad):
    with pytest.raises(InvalidSecret):
        parse_secret(bad)


def test_signed_content():
    assert signed_content(MSG_ID, TS, BODY) == b'msg_p5jXN8AQM9LWM0D4loKWxJek.1614265330.{"test": 2432232314}'


def test_sign_vector_and_rotation():
    assert sign([KEY], MSG_ID, TS, BODY) == SIG
    two = sign([KEY, b"other"], MSG_ID, int(TS), BODY)
    assert two.startswith(SIG + " v1,") and two.count(" ") == 1


def test_sign_rejects_noncanonical_timestamp():
    with pytest.raises(ValueError):
        sign([KEY], MSG_ID, "007", BODY)


def v(header=SIG, ts=TS, now=1614265400, body=BODY, keys=(KEY,)):
    return verify(list(keys), MSG_ID, ts, header, body, now)


def test_verify_ok():
    r = v()
    assert r.ok and (r.secret_index, r.token_index) == (0, 0)
    assert str(r) == "ok 0 0"


def test_verify_tolerance_boundaries():
    assert v(now=1614265330 + 300).ok
    assert v(now=1614265330 - 300).ok
    assert v(now=1614265330 + 301).reason is Failure.TIMESTAMP_TOO_OLD
    assert v(now=1614265330 - 301).reason is Failure.TIMESTAMP_TOO_NEW


def test_verify_failures():
    assert str(v(header="")) == "fail missing-signature"
    assert str(v(header="  ")) == "fail missing-signature"
    assert v(ts="01614265330").reason is Failure.INVALID_TIMESTAMP
    assert v(body=b"{}").reason is Failure.NO_MATCH
    # step order: an empty header beats a bad timestamp
    assert v(header="", ts="x").reason is Failure.MISSING_SIGNATURE


def test_verify_skips_garbage_and_indexes_all_tokens():
    r = v(header="garbage  v2,AAAA v1,!!! " + SIG)
    assert r.ok and r.token_index == 4
    assert v(header="v2" + SIG[2:]).reason is Failure.NO_MATCH


def test_verify_rotation_prefers_secret_order():
    other = parse_secret("whsec_c2VjcmV0")
    header = sign([other, KEY], MSG_ID, TS, BODY)
    r = v(header=header, keys=(KEY, other))
    assert (r.secret_index, r.token_index) == (0, 1)
