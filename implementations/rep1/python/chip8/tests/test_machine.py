import pytest

from chip8 import FONT, FONT_ADDRESS, KeyEvent, Machine


def run(rom_hex: str, cycles: int, keys=()):
    m = Machine(bytes.fromhex(rom_hex))
    m.run(cycles, keys)
    return m


def test_initial_state():
    m = Machine()
    assert m.pc == 0x200 and m.i == 0 and m.stack == [] and m.v == [0] * 16
    assert bytes(m.memory[FONT_ADDRESS : FONT_ADDRESS + 80]) == FONT
    assert m.rng_state == 0x12345678


def test_rom_too_large():
    with pytest.raises(ValueError):
        Machine(bytes(3585))
    Machine(bytes(3584))


def test_zero_cycles():
    m = run("6001", 0)
    assert m.v[0] == 0 and m.pc == 0x200


def test_add_with_carry_and_flag_wins_when_x_is_f():
    m = run("60ff61018014", 3)
    assert m.v[0] == 0 and m.v[0xF] == 1
    m = run("6fff 6101 8f14".replace(" ", ""), 3)
    assert m.v[0xF] == 1  # flag written after result


def test_sub_flags():
    m = run("6005610580158015", 4)  # 5-5? v0=5,v1=5 -> 0, vf=1 ; then 0-5 -> borrow
    assert m.v[0] == 0xFB and m.v[0xF] == 0
    m = run("6003610580178017", 3)  # v0 = v1 - v0 = 2, vf=1
    assert m.v[0] == 2 and m.v[0xF] == 1


def test_shifts_ignore_vy_and_set_flag():
    m = run("60816100 8016".replace(" ", ""), 3)
    assert m.v[0] == 0x40 and m.v[0xF] == 1
    m = run("6081610080 1e".replace(" ", ""), 3)
    assert m.v[0] == 0x02 and m.v[0xF] == 1


def test_seven_xnn_leaves_vf():
    m = run("6f01 60ff 70ff".replace(" ", ""), 3)
    assert m.v[0] == 0xFE and m.v[0xF] == 1


def test_call_and_return():
    # 0x200: call 0x206 ; 0x202: v1=1 ; 0x204: jump self ; 0x206: v0=7 ; 0x208: ret
    m = run("2206" "6101" "1204" "6007" "00ee", 3)
    assert m.v[0] == 7 and m.stack == [] and m.pc == 0x202
    m = run("2206" "6101" "1204" "6007" "00ee", 1)
    assert m.stack == [0x202]


def test_jump_with_v0_wraps():
    m = run("60ffbfff", 2)
    assert m.pc == (0xFFF + 0xFF) & 0xFFF


def test_pc_wraps_at_fff():
    m = Machine()
    m.pc = 0xFFF
    m.memory[0xFFF] = 0x60
    m.memory[0x000] = 0x2A
    m.step()
    assert m.v[0] == 0x2A and m.pc == 0x001


def test_skips():
    m = run("6001 3001 6105 6106".replace(" ", ""), 3)
    assert m.v[1] == 6
    m = run("6001 4001 6105".replace(" ", ""), 3)
    assert m.v[1] == 5


def test_unknown_opcodes_are_nops():
    m = run("5011 8018 9013 e000 f0ff 0123", 6)
    assert m.pc == 0x20C and m.v == [0] * 16


def test_random_sequence():
    m = run("c0ffc1ffc20f", 3)
    assert m.v[:3] == [0x71, 0x47, 0x0D]
    assert m.rng_state == 0x2E1D6AB7


def test_random_advances_with_zero_mask():
    m = run("c000c0ff", 2)
    assert m.v[0] == 0x47


def test_draw_wrap_and_collision():
    rom = "6a3e6b1e6000f029dab5dab5"
    m = run(rom, 5)
    assert m.pixel(62, 30) and m.pixel(63, 30) and m.pixel(0, 2) and m.pixel(1, 2)
    assert m.v[0xF] == 0 and sum(m.display) == 14
    m = run(rom, 6)
    assert sum(m.display) == 0 and m.v[0xF] == 1


def test_draw_n0_clears_vf():
    m = run("6f01d000", 2)
    assert m.v[0xF] == 0


def test_cls():
    m = run("f029d005 00e0".replace(" ", ""), 4)
    assert sum(m.display) == 0


def test_bcd_and_register_blocks_wrap_memory():
    m = Machine(bytes.fromhex("60fe a" "fff f033".replace(" ", "")))
    m.run(3)
    assert m.memory[0xFFF] == 2 and m.memory[0] == 5 and m.memory[1] == 4


def test_store_load_do_not_change_i():
    m = run("6001 6102 a300 f155 6000 6100 f165".replace(" ", ""), 7)
    assert m.v[0] == 1 and m.v[1] == 2 and m.i == 0x300


def test_font_pointer_and_add_i():
    m = run("600a f029 f01e".replace(" ", ""), 3)
    assert m.i == 0x050 + 0xA * 5 + 0x0A
    m = run("af ff".replace(" ", "") + "60ff f01e" + "6001 f01e".replace(" ", ""), 1)
    assert m.i == 0xFFF


def test_add_i_keeps_16_bits():
    m = Machine()
    m.i = 0xFFFF
    m.v[0] = 2
    m.memory[0x200:0x202] = bytes.fromhex("f01e")
    m.step()
    assert m.i == 0x0001


def test_timers_tick_every_eight_cycles():
    # v0=20; DT=v0 (cycle 1); then self loop
    m = run("6014f0151204".replace("1204", "1204"), 8)
    assert m.dt == 0x13
    m = run("6014f0151204", 16)
    assert m.dt == 0x12
    m = run("6014f018" "1204", 8)
    assert m.st == 0x13


def test_fx15_at_cycle_seven_is_ticked_immediately():
    m = run("6008" + "6100" * 6 + "f015", 8)
    assert m.dt == 7


def test_wait_for_key_spins_then_takes_lowest():
    m = run("f00a", 5)
    assert m.pc == 0x200
    m = run("f00a", 4, [KeyEvent(3, 0x0300)])
    assert m.v[0] == 8 and m.pc == 0x202


def test_key_skips():
    m = run("6003 e09e 6101 6202", 3, [(0, 0x0008)])
    assert m.v[1] == 0 and m.v[2] == 2
    m = run("6003 e0a1 6101 6202".replace(" ", ""), 3, [(0, 0x0008)])
    assert m.v[1] == 1


def test_key_event_at_cycle_n_has_no_effect():
    m = run("f00a", 3, [(3, 1)])
    assert m.keys == 0 and m.pc == 0x200


def test_key_state_replaced_by_later_event():
    m = run("f00a" * 4, 4, [(0, 0x1), (1, 0x0), (2, 0x4)])
    assert m.keys == 4


def test_self_modifying_code():
    # v0=0x61, v1=0x2a, I=0x20a, store v0..v1 at 0x20a (overwriting following opcode)
    rom = "6061" "612a" "a20a" "f155" "0000"
    m = run(rom, 6)
    assert m.v[0] == 0x61 and m.memory[0x20A] == 0x61
    m = run(rom, 5)
    assert m.v[0] == 0x61 and m.v[1] == 0x2A
