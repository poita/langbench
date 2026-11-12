#include <gtest/gtest.h>

#include <initializer_list>

#include "chip8/machine.hpp"

using namespace chip8;

namespace {

// Build a machine whose ROM is the given opcodes and run `cycles` cycles.
Machine run(std::initializer_list<unsigned> ops, std::uint64_t cycles, KeySchedule sched = {}) {
  std::vector<std::uint8_t> rom;
  for (unsigned op : ops) {
    rom.push_back(static_cast<std::uint8_t>(op >> 8));
    rom.push_back(static_cast<std::uint8_t>(op & 0xFF));
  }
  Machine m;
  m.load_rom(rom);
  m.run(cycles, sched);
  return m;
}

Machine run_all(std::initializer_list<unsigned> ops) { return run(ops, ops.size()); }

}  // namespace

TEST(Machine, InitialState) {
  Machine m;
  EXPECT_EQ(m.pc(), 0x200);
  EXPECT_EQ(m.sp(), 0u);
  EXPECT_EQ(m.memory()[0x050], 0xF0);
  EXPECT_EQ(m.memory()[0x09F], 0x80);
  EXPECT_EQ(m.memory()[0x0A0], 0x00);
}

TEST(Machine, LoadRomTooLargeThrows) {
  Machine m;
  EXPECT_THROW(m.load_rom(std::vector<std::uint8_t>(kMaxRomSize + 1)), std::length_error);
  EXPECT_NO_THROW(m.load_rom(std::vector<std::uint8_t>(kMaxRomSize, 1)));
  EXPECT_EQ(m.memory()[0xFFF], 1);
}

TEST(Machine, ZeroCyclesDoesNothing) {
  Machine m = run({0x6001}, 0);
  EXPECT_EQ(m.pc(), 0x200);
  EXPECT_EQ(m.v(0), 0);
}

TEST(Control, JumpCallReturn) {
  Machine m = run({0x2206}, 1);  // call 0x206
  EXPECT_EQ(m.sp(), 1u);
  EXPECT_EQ(m.stack()[0], 0x202);
  EXPECT_EQ(m.pc(), 0x206);
  m = run({0x2204, 0x1210, 0x00EE}, 2);  // call 0x204 (a return) -> back to 0x202
  EXPECT_EQ(m.sp(), 0u);
  EXPECT_EQ(m.pc(), 0x202);
  EXPECT_EQ(run({0x1ABC}, 1).pc(), 0xABC);
}

TEST(Control, StackCanHoldSixteenEntries) {
  // each address holds "call next"
  std::vector<std::uint8_t> rom;
  for (int i = 1; i <= 16; ++i) {
    unsigned op = 0x2000 | (0x200 + 2 * i);
    rom.push_back(op >> 8);
    rom.push_back(op & 0xFF);
  }
  Machine m;
  m.load_rom(rom);
  m.run(16);
  EXPECT_EQ(m.sp(), 16u);
  EXPECT_EQ(m.stack()[15], 0x220);
}

TEST(Control, SkipInstructions) {
  EXPECT_EQ(run({0x6005, 0x3005}, 2).pc(), 0x206);
  EXPECT_EQ(run({0x6005, 0x3006}, 2).pc(), 0x204);
  EXPECT_EQ(run({0x6005, 0x4006}, 2).pc(), 0x206);
  EXPECT_EQ(run({0x6005, 0x4005}, 2).pc(), 0x204);
  EXPECT_EQ(run({0x5010}, 1).pc(), 0x204);   // V0 == V1
  EXPECT_EQ(run({0x6001, 0x5010}, 2).pc(), 0x204);  // V0 != V1: no skip
  EXPECT_EQ(run({0x9010}, 1).pc(), 0x202);
  EXPECT_EQ(run({0x6001, 0x9010}, 2).pc(), 0x206);
}

TEST(Control, MalformedSkipVariantsAreNoOps) {
  EXPECT_EQ(run({0x5011}, 1).pc(), 0x202);
  EXPECT_EQ(run({0x9011}, 1).pc(), 0x202);
}

TEST(Control, BnnnUsesV0AndWraps) {
  EXPECT_EQ(run({0x6005, 0xB300}, 2).pc(), 0x305);
  EXPECT_EQ(run({0x60FF, 0xBF01}, 2).pc(), 0x000);  // 0xF01 + 0xFF = 0x1000 -> 0
}

TEST(Control, UnknownOpcodesAreNoOps) {
  for (unsigned op : {0x0123u, 0x8018u, 0xE000u, 0xF0FFu, 0x0000u, 0x00E1u}) {
    Machine m = run({op}, 1);
    EXPECT_EQ(m.pc(), 0x202) << std::hex << op;
    EXPECT_EQ(m.index(), 0);
  }
}

TEST(Control, PcWrapsAtEndOfMemory) {
  Machine m;
  m.poke(0xFFF, 0x61);  // high byte at 0xFFF, low byte from 0x000
  m.poke(0x000, 0x2A);
  m.poke(0x200, 0x1F);
  m.poke(0x201, 0xFF);
  m.run(2);
  EXPECT_EQ(m.v(1), 0x2A);
  EXPECT_EQ(m.pc(), 0x001);
}

TEST(Alu, LoadAddNoFlag) {
  Machine m = run_all({0x6F07, 0x60FF, 0x7001});
  EXPECT_EQ(m.v(0), 0);
  EXPECT_EQ(m.v(0xF), 7);  // 7XNN leaves VF alone, even on overflow
}

TEST(Alu, Logic) {
  Machine m = run_all({0x60CC, 0x610F, 0x8010});
  EXPECT_EQ(m.v(0), 0x0F);
  Machine a = run_all({0x60CC, 0x610F, 0x8011});
  EXPECT_EQ(a.v(0), 0xCF);
  Machine b = run_all({0x60CC, 0x610F, 0x8012});
  EXPECT_EQ(b.v(0), 0x0C);
  Machine c = run_all({0x60CC, 0x610F, 0x8013});
  EXPECT_EQ(c.v(0), 0xC3);
}

TEST(Alu, AddCarry) {
  Machine m = run_all({0x60FF, 0x6102, 0x8014});
  EXPECT_EQ(m.v(0), 1);
  EXPECT_EQ(m.v(0xF), 1);
  m = run_all({0x60FE, 0x6101, 0x8014});
  EXPECT_EQ(m.v(0), 0xFF);
  EXPECT_EQ(m.v(0xF), 0);
}

TEST(Alu, SubNoBorrowFlag) {
  Machine m = run_all({0x6005, 0x6105, 0x8015});
  EXPECT_EQ(m.v(0), 0);
  EXPECT_EQ(m.v(0xF), 1);  // VX >= VY
  m = run_all({0x6003, 0x6105, 0x8015});
  EXPECT_EQ(m.v(0), 0xFE);
  EXPECT_EQ(m.v(0xF), 0);
  m = run_all({0x6003, 0x6105, 0x8017});
  EXPECT_EQ(m.v(0), 2);
  EXPECT_EQ(m.v(0xF), 1);
  m = run_all({0x6005, 0x6103, 0x8017});
  EXPECT_EQ(m.v(0), 0xFE);
  EXPECT_EQ(m.v(0xF), 0);
}

TEST(Alu, ShiftsInPlaceIgnoreVy) {
  Machine m = run_all({0x6003, 0x61F0, 0x8016});
  EXPECT_EQ(m.v(0), 1);
  EXPECT_EQ(m.v(0xF), 1);
  m = run_all({0x6081, 0x610F, 0x801E});
  EXPECT_EQ(m.v(0), 0x02);
  EXPECT_EQ(m.v(0xF), 1);
  m = run_all({0x6040, 0x801E});
  EXPECT_EQ(m.v(0), 0x80);
  EXPECT_EQ(m.v(0xF), 0);
}

TEST(Alu, FlagWinsWhenXIsF) {
  Machine m = run_all({0x6FFF, 0x6001, 0x8F04});
  EXPECT_EQ(m.v(0xF), 1);  // sum 0x100 -> VF=0 written first, flag 1 after
  m = run_all({0x6F01, 0x6001, 0x8F05});
  EXPECT_EQ(m.v(0xF), 1);
  m = run_all({0x6F02, 0x8F06});
  EXPECT_EQ(m.v(0xF), 0);
  m = run_all({0x6F81, 0x8F0E});
  EXPECT_EQ(m.v(0xF), 1);
}

TEST(Misc, IndexAndFontAddress) {
  Machine m = run_all({0xA123, 0x60FF, 0xF01E});
  EXPECT_EQ(m.index(), 0x222);
  m = run_all({0xAFFF, 0x6002, 0xF01E});
  EXPECT_EQ(m.index(), 0x1001);  // no 12-bit masking of I
  m = run_all({0x601A, 0xF029});
  EXPECT_EQ(m.index(), 0x050 + 0xA * 5);
}

TEST(Misc, FxIeWrapsAt16Bits) {
  Machine m;
  std::vector<std::uint8_t> rom = {0xAF, 0xFF, 0x60, 0xFF, 0xF0, 0x1E};
  m.load_rom(rom);
  for (int i = 0; i < 3; ++i) m.step();
  EXPECT_EQ(m.index(), 0x10FE);
}

TEST(Misc, Bcd) {
  Machine m = run_all({0x60F7, 0xA300, 0xF033});
  EXPECT_EQ(m.memory()[0x300], 2);
  EXPECT_EQ(m.memory()[0x301], 4);
  EXPECT_EQ(m.memory()[0x302], 7);
  EXPECT_EQ(m.index(), 0x300);
}

TEST(Misc, BcdWrapsAddresses) {
  Machine m = run_all({0x60F7, 0xAFFF, 0xF033});
  EXPECT_EQ(m.memory()[0xFFF], 2);
  EXPECT_EQ(m.memory()[0x000], 4);
  EXPECT_EQ(m.memory()[0x001], 7);
}

TEST(Misc, StoreAndLoadRegistersLeaveIUnchanged) {
  Machine m = run_all({0x6011, 0x6122, 0x6233, 0xA300, 0xF255});
  EXPECT_EQ(m.memory()[0x300], 0x11);
  EXPECT_EQ(m.memory()[0x301], 0x22);
  EXPECT_EQ(m.memory()[0x302], 0x33);
  EXPECT_EQ(m.memory()[0x303], 0);
  EXPECT_EQ(m.index(), 0x300);
  m = run_all({0x6011, 0x6122, 0xA300, 0xF155, 0x6000, 0x6100, 0xF165});
  EXPECT_EQ(m.v(0), 0x11);
  EXPECT_EQ(m.v(1), 0x22);
  EXPECT_EQ(m.index(), 0x300);
}

TEST(Misc, RegisterTransferWrapsMemory) {
  Machine m = run_all({0x6011, 0x6122, 0xAFFF, 0xF155});
  EXPECT_EQ(m.memory()[0xFFF], 0x11);
  EXPECT_EQ(m.memory()[0x000], 0x22);
}

TEST(Misc, RandomUsesSpecLcgAndMask) {
  Machine m = run_all({0xC0FF, 0xC1FF, 0xC20F, 0xC300});
  EXPECT_EQ(m.v(0), 0x71);
  EXPECT_EQ(m.v(1), 0x47);
  EXPECT_EQ(m.v(2), 0x0D);
  EXPECT_EQ(m.v(3), 0);
  EXPECT_NE(m.rng().state(), Rng::kDefaultSeed);
}

TEST(Misc, RandomAdvancesEvenWithZeroMask) {
  Machine m = run_all({0xC000, 0xC1FF});
  EXPECT_EQ(m.v(1), 0x47);
}

TEST(Draw, SetsAndClearsCollisionFlag) {
  Machine m = run_all({0xA050, 0xD015});
  EXPECT_EQ(m.v(0xF), 0);
  EXPECT_TRUE(m.display().pixel(0, 0));
  EXPECT_TRUE(m.display().pixel(3, 4));
  EXPECT_FALSE(m.display().pixel(1, 1));
  m = run_all({0xA050, 0xD015, 0xD015});
  EXPECT_EQ(m.v(0xF), 1);
  EXPECT_EQ(m.display(), Display());
}

TEST(Draw, ZeroHeightClearsFlag) {
  Machine m = run_all({0x6F01, 0xD010});
  EXPECT_EQ(m.v(0xF), 0);
}

TEST(Draw, CoordinatesAreModuloAndSpriteReadWraps) {
  Machine m;
  m.poke(0xFFF, 0x80);
  m.poke(0x000, 0x80);
  m.poke(0x200, 0xAF);  // I = 0xFFF
  m.poke(0x201, 0xFF);
  m.poke(0x202, 0x60);  // V0 = 70
  m.poke(0x203, 70);
  m.poke(0x204, 0x61);  // V1 = 33
  m.poke(0x205, 33);
  m.poke(0x206, 0xD0);
  m.poke(0x207, 0x12);
  m.run(4);
  EXPECT_TRUE(m.display().pixel(6, 1));
  EXPECT_TRUE(m.display().pixel(6, 2));
}

TEST(Draw, ClearScreen) {
  Machine m = run_all({0xA050, 0xD015, 0x00E0});
  EXPECT_EQ(m.display(), Display());
}

TEST(Keys, SkipIfDownAndUp) {
  KeySchedule s({{0, 0x0020}});
  Machine m = run({0x6005, 0xE09E}, 2, s);
  EXPECT_EQ(m.pc(), 0x206);
  m = run({0x6005, 0xE0A1}, 2, s);
  EXPECT_EQ(m.pc(), 0x204);
  m = run({0x6025, 0xE09E}, 2, KeySchedule({{0, 0x0020}}));  // key index masked: 0x25 & 0xF = 5
  EXPECT_EQ(m.pc(), 0x206);
}

TEST(Keys, EventAppliesBeforeItsCycle) {
  // cycle 0: V0=1 ; cycle 1: EXA1 on key 1 -> event at cycle 1 presses key 1 beforehand
  Machine m = run({0x6001, 0xE0A1}, 2, KeySchedule({{1, 0x0002}}));
  EXPECT_EQ(m.pc(), 0x204);  // key 1 is down, so EXA1 does not skip
  m = run({0x6001, 0xE0A1}, 2);
  EXPECT_EQ(m.pc(), 0x206);  // without the event it does
}

TEST(Keys, EventAtBudgetNeverApplies) {
  Machine m = run({0xF00A, 0x1200}, 1, KeySchedule({{1, 0x0001}}));
  EXPECT_EQ(m.pc(), 0x200);
}

TEST(Keys, WaitForKeySpinsThenTakesLowest) {
  Machine m = run({0xF00A}, 3, KeySchedule({{2, 0x0A00}}));
  EXPECT_EQ(m.v(0), 9);
  EXPECT_EQ(m.pc(), 0x202);
  m = run({0xF00A}, 2, KeySchedule({{2, 0x0A00}}));
  EXPECT_EQ(m.pc(), 0x200);
  EXPECT_EQ(m.cycles(), 2u);
}

TEST(Timers, TickEveryEightCompletedCycles) {
  // V0=8 ; DT=V0 (cycle 1) ; then no-ops. Ticks after cycles 8, 16.
  Machine m = run({0x6008, 0xF015}, 7);
  EXPECT_EQ(m.delay_timer(), 8);
  m = run({0x6008, 0xF015}, 8);
  EXPECT_EQ(m.delay_timer(), 7);
  m = run({0x6008, 0xF015}, 16);
  EXPECT_EQ(m.delay_timer(), 6);
}

TEST(Timers, SetInEighthCycleIsDecrementedImmediately) {
  Machine m = run({0x6001, 0x6001, 0x6001, 0x6001, 0x6001, 0x6001, 0x6001, 0xF015}, 8);
  EXPECT_EQ(m.delay_timer(), 0);  // V0 == 1 -> DT=1 then tick
}

TEST(Timers, SoundTimerAndSaturation) {
  Machine m = run({0x6001, 0xF018}, 8);
  EXPECT_EQ(m.sound_timer(), 0);
  m = run({0x600A, 0xF018}, 8);
  EXPECT_EQ(m.sound_timer(), 9);
  m = run({0x600A, 0xF018, 0xF007}, 100);
  EXPECT_EQ(m.sound_timer(), 0);
  EXPECT_EQ(m.delay_timer(), 0);
}

TEST(Timers, ReadDelayTimer) {
  Machine m = run_all({0x6020, 0xF015, 0xF107});
  EXPECT_EQ(m.v(1), 0x20);
}

TEST(Machine, SelfModifyingCodeIsExecuted) {
  // Write 0x6A77 over the instruction at 0x20A, then run it.
  // V0=0x6A, V1=0x0A... stores bytes 6A,77 at 0x20C then executes them.
  Machine m = run({0x606A, 0x6177, 0xA20C, 0xF155, 0x1200 | 0x20C, 0x0000, 0x0000}, 5);
  EXPECT_EQ(m.pc(), 0x20C);
  m.run(1);
  EXPECT_EQ(m.v(0xA), 0x77);
  EXPECT_EQ(m.pc(), 0x20E);
}

TEST(Machine, SelfJumpConsumesBudget) {
  Machine m = run({0x1200}, 1000);
  EXPECT_EQ(m.pc(), 0x200);
  EXPECT_EQ(m.cycles(), 1000u);
}
