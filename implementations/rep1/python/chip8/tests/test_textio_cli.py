import subprocess
import sys
from pathlib import Path

import pytest

from chip8 import parse_input, simulate

ROOT = Path(__file__).resolve().parent.parent

EX1 = "60ff7001610180141208\n6\n"
EX3 = "c0ffc1ffc20f6408f415f007e2a11200e4a1120af00a\n14\n9:0300\n"


def test_parse_input_basic():
    p = parse_input(EX3)
    assert p.cycles == 14 and p.rom[:2] == b"\xc0\xff"
    assert [tuple(e) for e in p.key_schedule] == [(9, 0x0300)]


def test_parse_input_variants():
    assert parse_input("00\n0").key_schedule == ()
    assert parse_input("00\n0\n\n").key_schedule == ()
    p = parse_input("00\n4000000000\n0:0001 3:0000")
    assert p.cycles == 4000000000 and len(p.key_schedule) == 2


@pytest.mark.parametrize("bad", ["", "00", "0\n1", "zz\n1", "00\nx"])
def test_parse_input_rejects_garbage(bad):
    with pytest.raises(ValueError):
        parse_input(bad)


def test_simulate_example1():
    out = simulate(EX1).split("\n")
    assert out[:32] == ["." * 64] * 32
    assert out[32] == "PC=0208 I=0000 SP=0 DT=00 ST=00"
    assert out[33] == "V=01 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00"
    assert out[34:] == [""]


def test_simulate_example3():
    out = simulate(EX3).split("\n")
    assert out[32] == "PC=021e I=0000 SP=0 DT=07 ST=00"
    assert out[33].startswith("V=08 47 0d 00 08")


def test_simulate_example2_display():
    out = simulate("6a3e6b1e6000f029dab5dab5\n5\n").split("\n")
    assert out[0] == ".#" + "." * 60 + "#."
    assert out[2] == "##" + "." * 60 + "##"
    assert out[31] == ".#" + "." * 60 + "#."
    assert out[32] == "PC=020a I=0050 SP=0 DT=00 ST=00"


def test_cli_subprocess():
    result = subprocess.run(
        [sys.executable, "-m", "chip8"],
        input=EX1,
        capture_output=True,
        text=True,
        env={"PYTHONPATH": str(ROOT / "src")},
        check=True,
    )
    assert len(result.stdout.splitlines()) == 34
    assert result.stdout.endswith("00 00 00 00 00 00\n")


def test_cli_rejects_bad_input():
    result = subprocess.run(
        [sys.executable, "-m", "chip8"],
        input="nothex\n1\n",
        capture_output=True,
        text=True,
        env={"PYTHONPATH": str(ROOT / "src")},
    )
    assert result.returncode == 1 and "invalid input" in result.stderr
