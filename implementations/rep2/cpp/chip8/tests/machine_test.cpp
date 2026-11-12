#include <gtest/gtest.h>

#include <initializer_list>

#include "chip8/font.hpp"
#include "chip8/machine.hpp"

using namespace chip8;

namespace {

/// Build a machine whose ROM is the given 16-bit opcodes.
Machine make(std::initializer_list<std::uint16_t> ops) {
    std::vector<std::uint8_t> rom;
    for (auto op : ops) {
        rom.push_back(static_cast<std::uint8_t>(op >> 8));
        rom.push_back(static_cast<std::uint8_t>(op & 0xFF));
    }
    Machine m;
    m.load_rom(rom);
    return m;
}

void steps(Machine& m, int n) {
    for (int i = 0; i < n; ++i) m.step();
}

}  // namespace

TEST(Machine, InitialState) {
    Machine m;
    EXPECT_EQ(m.pc(), 0x200);
    EXPECT_EQ(m.index(), 0);
    EXPECT_EQ(m.sp(), 0u);
    EXPECT_EQ(m.peek(0x050), 0xF0);
    EXPECT_EQ(m.peek(0x09F), 0x80);
    EXPECT_EQ(m.peek(0x0A0), 0);
}

TEST(Machine, LoadRomAtMaxSizeFillsToEndOfMemory) {
    Machine m;
    m.load_rom(std::vector<std::uint8_t>(kMaxRomSize, 0xAB));
    EXPECT_EQ(m.peek(0x200), 0xAB);
    EXPECT_EQ(m.peek(0xFFF), 0xAB);
}

TEST(Machine, JumpsCallsReturns) {
    Machine m = make({0x2206, 0x1200, 0, 0x00EE});  // call 0x206 ... ret
    m.step();
    EXPECT_EQ(m.pc(), 0x206);
    EXPECT_EQ(m.sp(), 1u);
    m.poke(0x206, 0x00);
    m.poke(0x207, 0xEE);
    m.step();
    EXPECT_EQ(m.pc(), 0x202);
    EXPECT_EQ(m.sp(), 0u);
}

TEST(Machine, SkipsAreTwoBytes) {
    Machine m = make({0x6005, 0x3005, 0x0000, 0x4005, 0x5000, 0x0000});
    steps(m, 2);
    EXPECT_EQ(m.pc(), 0x206);  // 3XNN skipped
    steps(m, 1);               // 4XNN not taken
    EXPECT_EQ(m.pc(), 0x208);
    steps(m, 1);               // 5000: V0==V0, skip
    EXPECT_EQ(m.pc(), 0x20C);
}

TEST(Machine, SevenXNNDoesNotTouchVF) {
    Machine m = make({0x6FAA, 0x70FF, 0x7F01});
    steps(m, 2);
    EXPECT_EQ(m.reg(0), 0xFF);
    EXPECT_EQ(m.reg(0xF), 0xAA);
    steps(m, 1);
    EXPECT_EQ(m.reg(0xF), 0xAB);
}

TEST(Machine, AddCarry) {
    Machine m = make({0x60FF, 0x6102, 0x8014});
    steps(m, 3);
    EXPECT_EQ(m.reg(0), 0x01);
    EXPECT_EQ(m.reg(0xF), 1);
}

TEST(Machine, SubNoBorrowFlag) {
    Machine m = make({0x6005, 0x6105, 0x8015});  // equal -> VF = 1
    steps(m, 3);
    EXPECT_EQ(m.reg(0), 0);
    EXPECT_EQ(m.reg(0xF), 1);
    Machine n = make({0x6003, 0x6105, 0x8015});
    steps(n, 3);
    EXPECT_EQ(n.reg(0), 0xFE);
    EXPECT_EQ(n.reg(0xF), 0);
}

TEST(Machine, ReverseSub) {
    Machine m = make({0x6003, 0x6105, 0x8017});
    steps(m, 3);
    EXPECT_EQ(m.reg(0), 2);
    EXPECT_EQ(m.reg(0xF), 1);
}

TEST(Machine, ShiftsUseVxAndIgnoreVy) {
    Machine m = make({0x6003, 0x6140, 0x8016, 0x6081, 0x801E});
    steps(m, 3);
    EXPECT_EQ(m.reg(0), 1);
    EXPECT_EQ(m.reg(0xF), 1);
    steps(m, 2);
    EXPECT_EQ(m.reg(0), 0x02);
    EXPECT_EQ(m.reg(0xF), 1);
}

TEST(Machine, FlagWinsWhenXIsF) {
    Machine m = make({0x6FFF, 0x61FF, 0x8F14});  // VF = 0xFF + 0xFF -> result 0xFE, flag 1
    steps(m, 3);
    EXPECT_EQ(m.reg(0xF), 1);
    Machine s = make({0x6F03, 0x8F06});
    steps(s, 2);
    EXPECT_EQ(s.reg(0xF), 1);
}

TEST(Machine, BitwiseOpsLeaveVfAlone) {
    Machine m = make({0x6FAA, 0x600F, 0x61F0, 0x8011, 0x8012, 0x8013});
    steps(m, 6);
    EXPECT_EQ(m.reg(0xF), 0xAA);
}

TEST(Machine, BnnnUsesV0AndMasks) {
    Machine m = make({0x6003, 0xBFFF});
    steps(m, 2);
    EXPECT_EQ(m.pc(), 0x002);
}

TEST(Machine, IndexRegisterKeepsHighBits) {
    Machine m = make({0xAFFF, 0x60FF, 0xF01E});
    steps(m, 3);
    EXPECT_EQ(m.index(), 0x10FE);
}

TEST(Machine, FontAddress) {
    Machine m = make({0x601A, 0xF029});
    steps(m, 2);
    EXPECT_EQ(m.index(), 0x050 + 0xA * 5);
}

TEST(Machine, Bcd) {
    Machine m = make({0x60FE, 0xA300, 0xF033});
    steps(m, 3);
    EXPECT_EQ(m.peek(0x300), 2);
    EXPECT_EQ(m.peek(0x301), 5);
    EXPECT_EQ(m.peek(0x302), 4);
}

TEST(Machine, BcdWrapsAtEndOfMemory) {
    Machine m = make({0x60FE, 0xAFFF, 0xF033});
    steps(m, 3);
    EXPECT_EQ(m.peek(0xFFF), 2);
    EXPECT_EQ(m.peek(0x000), 5);
    EXPECT_EQ(m.peek(0x001), 4);
}

TEST(Machine, StoreAndLoadRegistersLeaveIUnchanged) {
    Machine m = make({0x6001, 0x6102, 0x6203, 0xA400, 0xF255, 0x6001, 0x6100, 0xF265});
    steps(m, 5);
    EXPECT_EQ(m.peek(0x400), 1);
    EXPECT_EQ(m.peek(0x402), 3);
    EXPECT_EQ(m.peek(0x403), 0);
    EXPECT_EQ(m.index(), 0x400);
    steps(m, 3);
    EXPECT_EQ(m.reg(0), 1);
    EXPECT_EQ(m.reg(1), 2);
    EXPECT_EQ(m.index(), 0x400);
}

TEST(Machine, RandomAdvancesEvenWithZeroMask) {
    Machine m = make({0xC000, 0xC1FF});
    steps(m, 2);
    EXPECT_EQ(m.reg(0), 0);
    EXPECT_EQ(m.reg(1), 0x47);
}

TEST(Machine, DrawWrapsAndCollides) {
    Machine m = make({0x6A3E, 0x6B1E, 0xF029, 0xDAB5, 0xDAB5});
    steps(m, 4);
    EXPECT_EQ(m.reg(0xF), 0);
    EXPECT_TRUE(m.display().get(62, 30));
    EXPECT_TRUE(m.display().get(1, 2));
    EXPECT_FALSE(m.display().get(2, 2));
    EXPECT_TRUE(m.display().get(0, 2));
    EXPECT_TRUE(m.display().get(63, 2));
    steps(m, 1);
    EXPECT_EQ(m.reg(0xF), 1);
    EXPECT_EQ(m.display(), Display{});
}

TEST(Machine, DrawZeroRowsClearsVf) {
    Machine m = make({0x6F01, 0xD000});
    steps(m, 2);
    EXPECT_EQ(m.reg(0xF), 0);
}

TEST(Machine, DrawOriginReducedModulo) {
    Machine m = make({0x6045, 0x6125, 0xA050, 0xD011});  // x=69->5, y=37->5
    steps(m, 4);
    EXPECT_TRUE(m.display().get(5, 5));
}

TEST(Machine, ClearScreen) {
    Machine m = make({0xA050, 0xD005, 0x00E0});
    steps(m, 3);
    EXPECT_EQ(m.display(), Display{});
}

TEST(Machine, KeySkips) {
    Machine m = make({0x6003, 0xE09E, 0x0000, 0xE0A1, 0x0000});
    m.set_keys(1u << 3);
    steps(m, 2);
    EXPECT_EQ(m.pc(), 0x206);  // EX9E skipped
    steps(m, 1);               // EXA1: key down, no skip
    EXPECT_EQ(m.pc(), 0x208);
}

TEST(Machine, KeyIndexUsesLowNibble) {
    Machine m = make({0x6013, 0xE09E});
    m.set_keys(1u << 3);
    steps(m, 2);
    EXPECT_EQ(m.pc(), 0x206);
}

TEST(Machine, WaitForKeyPicksLowest) {
    Machine m = make({0xF00A});
    steps(m, 3);
    EXPECT_EQ(m.pc(), 0x200);
    m.set_keys(0x0C00);
    m.step();
    EXPECT_EQ(m.reg(0), 10);
    EXPECT_EQ(m.pc(), 0x202);
}

TEST(Machine, TimersTickEveryEighthCycleAfterInstruction) {
    // cycles 0..6 are 6008 ... then F015 at cycle 7: DT=8 then immediately 7.
    Machine m = make({0x6008, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0xF015});
    steps(m, 8);
    EXPECT_EQ(m.delay_timer(), 7);
    steps(m, 8);
    EXPECT_EQ(m.delay_timer(), 6);
}

TEST(Machine, SoundTimerDecrementsAndStopsAtZero) {
    Machine m = make({0x6001, 0xF018});
    steps(m, 8);
    EXPECT_EQ(m.sound_timer(), 0);
    steps(m, 16);
    EXPECT_EQ(m.sound_timer(), 0);
}

TEST(Machine, UnknownOpcodesAreNoOps) {
    Machine m = make({0x5001, 0x8008, 0x9003, 0xE000, 0xF0FF, 0x0123});
    steps(m, 6);
    EXPECT_EQ(m.pc(), 0x20C);
    for (int i = 0; i < 16; ++i) EXPECT_EQ(m.reg(i), 0);
}

TEST(Machine, FetchWrapsAtEndOfMemory) {
    Machine m;
    m.poke(0xFFF, 0x60);
    m.poke(0x000, 0x42);  // opcode 0x6042 straddling the end
    m.poke(0x200, 0x1F);
    m.poke(0x201, 0xFF);  // jump to 0xFFF
    steps(m, 2);
    EXPECT_EQ(m.reg(0), 0x42);
    EXPECT_EQ(m.pc(), 0x001);
}

TEST(Machine, OddPcAllowed) {
    Machine m = make({0x6001, 0xB200});  // V0 = 1 -> PC = 0x201
    steps(m, 2);
    EXPECT_EQ(m.pc(), 0x201);
}

TEST(Machine, FullStack) {
    Machine m;
    // 16 nested calls: each instruction at 0x200+2k calls the next.
    for (int k = 0; k < 16; ++k) {
        std::uint16_t target = 0x202 + 2 * k;
        m.poke(0x200 + 2 * k, 0x20 | (target >> 8));
        m.poke(0x201 + 2 * k, target & 0xFF);
    }
    steps(m, 16);
    EXPECT_EQ(m.sp(), 16u);
}
