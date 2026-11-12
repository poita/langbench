import subprocess
import sys
from pathlib import Path

import pytest

from webhooks.protocol import run

ROOT = Path(__file__).resolve().parent.parent

P = "7b2274657374223a20323433323233323331347d"
H = "76312c6730684d395373452b4f54504a5447742f746d494b7453795a6c453375464a454c566c4e494f4c4a314f453d"
S = "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw"
ID = "msg_p5jXN8AQM9LWM0D4loKWxJek"

SPEC_INPUT = f"""sha256 -
sha256 616263
hmac - -
b64enc 666f6f
b64urlenc fbff
b64dec 5a6d3976
b64dec -
secret {S}
sign {S} {ID} 1614265330 {P}
verify {S} {ID} 1614265330 1614265400 {H} {P}
verify {S} {ID} 1614265330 1614265631 {H} {P}
verify {S} {ID} 1614265330 1614265400 {H} 7b7d
verify {S} {ID} 1614265330 1614265400 - {P}
sha256 ABCD
sha256 abc
frobnicate 1
"""

SPEC_OUTPUT = """e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
b613679a0814d9ec772f95d778c35fc5ff1697c493715653c6c712144292c5ad
Zm9v
-_8
666f6f
-
31f290f6bf06298aab4f08d43c3f082cf648a362da2da4b0
v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=
ok 0 0
fail timestamp-too-old
fail no-match
fail missing-signature
error
error
error"""

SIM_INPUT = """simulate
endpoint ep_a whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw * 500,timeout,200
endpoint ep_b whsec_c2VjcmV0,whsec_b3RoZXI user.created 200
event msg_1 1700000000 user.created 7b7d
event msg_2 1700000100 repo.pushed 7b7d
end
"""

SIM_OUTPUT = """sim 5 3
attempt 1 msg_1 ep_a 1 1700000000 failure 500
attempt 2 msg_1 ep_b 1 1700000000 success 200
attempt 3 msg_1 ep_a 2 1700000005 timeout -
attempt 4 msg_2 ep_a 1 1700000100 success 200
attempt 5 msg_1 ep_a 3 1700000305 success 200
delivery msg_1 ep_a delivered 3 1700000305 v1,x5lVgj0b/JJJaUYaa1+6I5J/EECcryrPlFN4VrkmI94=
delivery msg_1 ep_b delivered 1 1700000000 v1,A5oIrJxXPB/PkULSoVu0e4khvPiqpF9vljmhkSKg0FI= v1,+y5T5nCYgPC5Y9oXnau3uEIax3TN0x8LoF05LBfU83s=
delivery msg_2 ep_a delivered 1 1700000100 v1,Cu35wCUZTS4YnAIA1waQmIXPFLh46qYAWpcHufrxa9U="""


def out(text):
    return "\n".join(run(text.encode()))


def test_spec_examples():
    assert out(SPEC_INPUT) == SPEC_OUTPUT


def test_simulate_example():
    assert out(SIM_INPUT) == SIM_OUTPUT


def test_no_trailing_newline_and_blank_lines():
    assert run(b"\n   \nsha256 -\n  \nsha256 616263") == [
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
    ]


@pytest.mark.parametrize(
    "line",
    [
        "sha256  -", " sha256 -x", "sha256 -", "sha256\t-", "sha256 0", "sha256 A0",
        "b64dec 5a6d397", "secret a,b", "secret !", "secret whsec_",
        f"sign {S} {ID} 01 7b7d", f"sign {S} {ID} -0 7b7d", f"sign {S}, {ID} 1 7b7d",
        f"sign {','.join([S] * 17)} {ID} 1 7b7d", f"verify {S} {ID} 1 +5 - -",
        "b64dec 41", "end", "endpoint", "simulate now",
    ],
)
def test_errors(line):
    got = run(line.encode())
    if line == "sha256 -":
        assert got != ["error"]
    else:
        assert got == ["error"]


def test_verify_noncanonical_timestamp_is_fail_not_error():
    assert run(f"verify {S} {ID} 007 1 {H} -".encode()) == ["fail invalid-timestamp"]


def test_simulate_errors_consume_to_end():
    text = "simulate\nendpoint a x * 200\nevent e 0 t -\nendpoint b x * 200\nend\nsha256 -\n"
    assert run(text.encode())[0] == "error"
    assert len(run(text.encode())) == 2


@pytest.mark.parametrize(
    "block",
    [
        "simulate\nevent e 0 t -\nend\n",                    # no endpoints
        "simulate\nendpoint a whsec_c2VjcmV0 * 200\n",        # unterminated
        "simulate\nendpoint a whsec_c2VjcmV0 * 200\nendpoint a whsec_c2VjcmV0 * 200\nend\n",
        "simulate\nendpoint a whsec_c2VjcmV0 * 99\nend\n",
        "simulate\nendpoint a whsec_c2VjcmV0 * 600\nend\n",
        "simulate\nendpoint a whsec_c2VjcmV0 *,t 200\nend\n",
        "simulate\nendpoint a whsec_c2VjcmV0 * 200\nsimulate\nend\n",
    ],
)
def test_simulate_block_errors(block):
    assert run(block.encode()) == ["error"]


def test_empty_event_list():
    assert run(b"simulate\nendpoint a whsec_c2VjcmV0 * 200\nend\n") == ["sim 0 0"]


def test_stray_end_after_bad_simulate_line():
    assert run(b"simulate now\nend\n") == ["error", "error"]


def test_large_line():
    payload = "ab" * 32768
    assert len(run(f"sha256 {payload}".encode())[0]) == 64


def test_cli_subprocess():
    proc = subprocess.run(
        [str(ROOT / "run.sh")], input=SPEC_INPUT.encode(), capture_output=True, check=True
    )
    assert proc.stdout.decode().rstrip("\n") == SPEC_OUTPUT
