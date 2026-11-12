from chip8 import Machine


def test_initial_state():
    m = Machine()
    assert (m.pc, m.i, m.sp, m.dt, m.st) == (0x200, 0, 0, 0, 0)
    assert m.memory[0x50:0x55] == bytes([0xF0, 0x90, 0x90, 0x90, 0xF0])
    assert m.memory[0x9F] == 0x80


def test_rom_loaded_at_0x200():
    assert Machine(b"\x12\x34").memory[0x200:0x202] == b"\x12\x34"


def test_arithmetic_flag_wins_when_x_is_f(make_machine):
    m = make_machine(0x6FFF, 0x6001, 0x8F04)
    m.run(3)
    assert m.v[0xF] == 1  # flag written after result


def test_add_carry_and_sub_borrow(make_machine):
    m = make_machine(0x60FF, 0x6102, 0x8014, 0x6005, 0x6107, 0x8015)
    m.run(3)
    assert (m.v[0], m.v[0xF]) == (1, 1)
    m.run(3)
    assert (m.v[0], m.v[0xF]) == (0xFE, 0)


def test_subn(make_machine):
    m = make_machine(0x6005, 0x6103, 0x8017)
    m.run(3)
    assert (m.v[0], m.v[0xF]) == (0xFE, 0)


def test_shifts_ignore_vy(make_machine):
    m = make_machine(0x6003, 0x61FF, 0x8016, 0x6080, 0x801E)
    m.run(3)
    assert (m.v[0], m.v[0xF]) == (1, 1)
    m.run(2)
    assert (m.v[0], m.v[0xF]) == (0, 1)


def test_7xnn_leaves_vf(make_machine):
    m = make_machine(0x6F05, 0x60FF, 0x7002)
    m.run(3)
    assert (m.v[0], m.v[0xF]) == (1, 5)


def test_skips(make_machine):
    m = make_machine(0x6001, 0x3001, 0x6AFF, 0x4001, 0x6BFF, 0x5010, 0x9010)
    m.run(2)
    assert m.pc == 0x206
    m.run(1)
    assert m.pc == 0x208
    m.run(1)  # 5010: V0 == V1 (0 != 1) no skip
    assert m.pc == 0x20A


def test_unknown_opcodes_are_noops(make_machine):
    m = make_machine(0x5011, 0x8018, 0x9013, 0xE000, 0xF0FF, 0x0123)
    m.run(6)
    assert m.pc == 0x20C and m.v == [0] * 16 and m.sp == 0


def test_call_return(make_machine):
    m = make_machine(0x2204, 0x1200, 0x00EE)
    m.run(1)
    assert (m.pc, m.sp, m.stack[0]) == (0x204, 1, 0x202)
    m.run(1)
    assert (m.pc, m.sp) == (0x202, 0)


def test_bnnn_uses_v0_and_wraps(make_machine):
    m = make_machine(0x60FF, 0xBFFF)
    m.run(2)
    assert m.pc == 0xFE


def test_odd_pc_and_wrap_fetch():
    m = Machine()
    m.memory[0xFFF] = 0x60
    m.memory[0x000] = 0x2A
    m.pc = 0xFFF
    m.run(1)
    assert (m.v[0], m.pc) == (0x2A, 0x001)


def test_font_and_bcd(make_machine):
    m = make_machine(0x60AB, 0xF029, 0x61F5, 0xA300, 0xF133)
    m.run(2)
    assert m.i == 0x50 + 0xB * 5
    m.run(3)
    assert m.memory[0x300:0x303] == bytes([2, 4, 5])


def test_store_load_wrap_memory(make_machine):
    m = make_machine(0x6011, 0x6122, 0xAFFF, 0xF155, 0xF165)
    m.run(4)
    assert m.memory[0xFFF] == 0x11 and m.memory[0x000] == 0x22
    m.v[0] = m.v[1] = 0
    m.run(1)
    assert (m.v[0], m.v[1], m.i) == (0x11, 0x22, 0xFFF)


def test_fx1e_i_wraps_16_bits(make_machine):
    m = make_machine(0x60FF, 0xF01E)
    m.i = 0xFFFF
    m.run(2)
    assert m.i == 0x00FE


def test_timers_tick_after_eighth_cycle(make_machine):
    m = make_machine(0x6003, 0xF015, 0xF018, *([0x1206] * 100))
    m.run(8)
    assert (m.dt, m.st) == (2, 2)


def test_timer_phase_is_global_across_runs(make_machine):
    m = make_machine(0x6009, 0xF015, 0x1204)
    m.run(3)
    m.run(5)
    assert m.dt == 8
    m.run(8)
    assert m.dt == 7


def test_keys_and_wait(make_machine):
    m = make_machine(0xF00A, 0x6105, 0xE19E)
    m.run(2)
    assert m.pc == 0x200  # waiting
    m.set_keys(0b1100000)
    m.run(1)
    assert (m.v[0], m.pc) == (5, 0x202)


def test_ex9e_masks_vx(make_machine):
    m = make_machine(0x6013, 0xE09E, 0x6AFF)
    m.set_keys(1 << 3)
    m.run(2)
    assert m.pc == 0x206


def test_cxnn_advances_rng_even_with_zero_mask(make_machine):
    m = make_machine(0xC000, 0xC1FF)
    m.run(2)
    assert m.v[0] == 0 and m.v[1] == 0x47


def test_draw_sets_vf(make_machine):
    m = make_machine(0xF029, 0xD005, 0xD005)
    m.run(2)
    assert m.v[0xF] == 0
    m.run(1)
    assert m.v[0xF] == 1 and not any(m.display.pixels)


def test_self_modifying_code(make_machine):
    # Stores V0/V1 (0x6155 = "V1 = 0x55") over the program's own next word and runs it.
    m = make_machine(0x6061, 0x6155, 0xA20A, 0xF155, 0x6100, 0x0000)
    m.run(5)
    assert m.v[1] == 0
    m.run(1)
    assert m.v[1] == 0x55
