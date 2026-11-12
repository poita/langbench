#pragma once
#include <array>
#include <cstddef>
#include <cstdint>
#include <vector>

#include "chip8/display.hpp"
#include "chip8/rng.hpp"

namespace chip8 {

constexpr std::size_t kMemorySize = 4096;
constexpr std::uint16_t kProgramBase = 0x200;
constexpr std::size_t kMaxRomSize = kMemorySize - kProgramBase;  // 3584
constexpr std::size_t kStackDepth = 16;

/// A CHIP-8 machine with the deterministic semantics of SPEC.md.
///
/// Typical use: construct, `load_rom()`, then alternate `set_keys()` (when the
/// key state changes) and `step()`.
class Machine {
public:
    /// Create a machine with the font loaded and everything else zeroed.
    Machine();

    /// Copy `rom` to 0x200. Bytes beyond the end of memory are ignored.
    void load_rom(const std::vector<std::uint8_t>& rom);

    /// Set the 16-bit key state: bit k set means key k is held down.
    void set_keys(std::uint16_t mask) noexcept { keys_ = mask; }

    /// Execute exactly one cycle: fetch, execute, timer tick.
    void step() noexcept;

    // --- state inspection -------------------------------------------------
    std::uint16_t pc() const noexcept { return pc_; }
    std::uint16_t index() const noexcept { return i_; }
    std::size_t sp() const noexcept { return sp_; }
    std::uint8_t delay_timer() const noexcept { return dt_; }
    std::uint8_t sound_timer() const noexcept { return st_; }
    std::uint16_t keys() const noexcept { return keys_; }
    std::uint64_t cycles() const noexcept { return cycles_; }
    std::uint8_t reg(std::size_t i) const noexcept { return v_[i & 0xF]; }
    const std::array<std::uint8_t, 16>& registers() const noexcept { return v_; }
    std::uint8_t peek(std::uint16_t addr) const noexcept { return mem_[addr & 0xFFF]; }
    const Display& display() const noexcept { return display_; }

    /// Write a byte to memory (address masked to 12 bits). Useful for tests.
    void poke(std::uint16_t addr, std::uint8_t value) noexcept { mem_[addr & 0xFFF] = value; }

private:
    void execute(std::uint16_t op) noexcept;
    void draw(unsigned x, unsigned y, unsigned n) noexcept;
    void set_pc(unsigned value) noexcept { pc_ = static_cast<std::uint16_t>(value & 0xFFF); }
    void skip_if(bool cond) noexcept {
        if (cond) set_pc(pc_ + 2u);
    }

    std::array<std::uint8_t, kMemorySize> mem_{};
    std::array<std::uint8_t, 16> v_{};
    std::array<std::uint16_t, kStackDepth> stack_{};
    std::size_t sp_ = 0;
    std::uint16_t pc_ = kProgramBase;
    std::uint16_t i_ = 0;
    std::uint8_t dt_ = 0;
    std::uint8_t st_ = 0;
    std::uint16_t keys_ = 0;
    std::uint64_t cycles_ = 0;
    Rng rng_;
    Display display_;
};

}  // namespace chip8
