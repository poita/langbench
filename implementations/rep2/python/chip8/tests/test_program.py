import pytest

from chip8 import (
    KeyEvent,
    Machine,
    parse_key_schedule,
    parse_program,
    run_program,
    run_with_schedule,
)

EX1 = "60ff7001610180141208\n6\n"
EX3 = "c0ffc1ffc20f6408f415f007e2a11200e4a1120af00a\n14\n9:0300\n"
BLANK = ("." * 64 + "\n") * 32


def test_parse_program():
    p = parse_program("6001\n10\n0:0001 5:0000\n")
    assert p.rom == b"\x60\x01" and p.cycles == 10
    assert p.schedule == [KeyEvent(0, 1), KeyEvent(5, 0)]


def test_parse_without_schedule_or_trailing_newline():
    assert parse_program("6001\n10").schedule == []
    assert parse_program("6001\n10\n\n").schedule == []


def test_parse_key_schedule():
    assert parse_key_schedule("") == []
    assert parse_key_schedule("9:0300") == [KeyEvent(9, 0x300)]


def test_example1():
    assert run_program(EX1) == (
        BLANK
        + "PC=0208 I=0000 SP=0 DT=00 ST=00\n"
        + "V=01 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00\n"
    )


def test_example2():
    out = run_program("6a3e6b1e6000f029dab5dab5\n5\n").split("\n")
    assert out[0] == ".#" + "." * 60 + "#."
    assert out[2] == "##" + "." * 60 + "##"
    assert out[3] == "." * 64
    assert out[32] == "PC=020a I=0050 SP=0 DT=00 ST=00"
    assert out[33].startswith("V=00 00 00 00 00 00 00 00 00 00 3e 1e")
    again = run_program("6a3e6b1e6000f029dab5dab5\n6\n").split("\n")
    assert again[:32] == ["." * 64] * 32
    assert again[32].startswith("PC=020c") and again[33].endswith("00 00 00 01")


def test_example3():
    out = run_program(EX3).split("\n")
    assert out[32] == "PC=021e I=0000 SP=0 DT=07 ST=00"
    assert out[33] == "V=08 47 0d 00 08 00 00 00 00 00 00 00 00 00 00 00"


def test_zero_cycles():
    assert run_program("6001\n0\n").split("\n")[32] == "PC=0200 I=0000 SP=0 DT=00 ST=00"


def test_event_at_n_never_applies():
    m = Machine(bytes.fromhex("f00a"))
    run_with_schedule(m, 3, [KeyEvent(3, 1)])
    assert m.pc == 0x200 and m.keys == 0


def test_event_at_cycle_zero():
    m = Machine(bytes.fromhex("f00a"))
    run_with_schedule(m, 1, [KeyEvent(0, 0x0004)])
    assert m.v[0] == 2


def test_keys_released_again():
    m = Machine(bytes.fromhex("f00af00a"))
    run_with_schedule(m, 2, [KeyEvent(0, 1), KeyEvent(1, 0)])
    assert m.pc == 0x202  # second FX0A is waiting


def test_output_is_34_lines():
    assert run_program(EX1).count("\n") == 34


def test_oversized_rom_rejected():
    with pytest.raises(ValueError):
        Machine(bytes(3585))
