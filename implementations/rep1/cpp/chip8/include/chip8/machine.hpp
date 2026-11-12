#pragma once
/// @file machine.hpp
/// The CHIP-8 machine: state plus the fetch-decode-execute loop.

#include <array>
#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <vector>

#include "chip8/display.hpp"
#include "chip8/keypad.hpp"
#include "chip8/rng.hpp"

namespace chip8 {

constexpr std::size_t kMemorySize = 4096;
constexpr std::uint16_t kProgramBase = 0x200;
constexpr std::size_t kMaxRomSize = kMemorySize - kProgramBase;  // 3584
constexpr std::size_t kStackDepth = 16;

/// Complete interpreter state. Every instruction is decoded from memory on
/// every cycle (self-modifying programs work).
///
/// Behaviour on stack overflow/underflow is unspecified by the CHIP-8 variant
/// implemented here; this implementation stays memory-safe: a call with a full
/// stack and a return with an empty stack are executed as no-ops (after the PC
/// has advanced).
class Machine {
 public:
  /// Create a machine with the font loaded and everything else cleared.
  Machine();

  /// Copy @p rom to 0x200. Throws std::length_error if it is larger than
  /// kMaxRomSize bytes.
  void load_rom(const std::vector<std::uint8_t>& rom);

  /// Replace the held-key state.
  void set_keys(std::uint16_t mask) noexcept { keys_.set_mask(mask); }

  /// Execute one instruction cycle (fetch, execute, timer tick). Key events
  /// are not applied here; see run().
  void step() noexcept;

  /// Execute @p cycles more cycles, applying each event of @p schedule
  /// immediately before the cycle it names. Event cycles are absolute cycle
  /// numbers (cycles() is 0 for a fresh machine).
  void run(std::uint64_t cycles, KeySchedule& schedule) noexcept;

  /// Execute @p cycles cycles with no key events.
  void run(std::uint64_t cycles) noexcept;

  // --- State accessors -----------------------------------------------------
  std::uint16_t pc() const noexcept { return pc_; }
  std::uint16_t index() const noexcept { return i_; }
  unsigned sp() const noexcept { return sp_; }
  std::uint8_t delay_timer() const noexcept { return dt_; }
  std::uint8_t sound_timer() const noexcept { return st_; }
  std::uint8_t v(std::size_t x) const noexcept { return v_[x & 0xF]; }
  const std::array<std::uint8_t, 16>& registers() const noexcept { return v_; }
  const std::array<std::uint16_t, kStackDepth>& stack() const noexcept { return stack_; }
  const std::array<std::uint8_t, kMemorySize>& memory() const noexcept { return mem_; }
  const Display& display() const noexcept { return display_; }
  const Keypad& keypad() const noexcept { return keys_; }
  const Rng& rng() const noexcept { return rng_; }
  /// Number of cycles completed so far.
  std::uint64_t cycles() const noexcept { return cycles_; }

  /// Direct memory write (address masked to 12 bits); handy for tests/tools.
  void poke(std::uint16_t addr, std::uint8_t value) noexcept { mem_[addr & 0xFFF] = value; }

 private:
  void execute(std::uint16_t op) noexcept;
  void execute_alu(unsigned x, unsigned y, unsigned n) noexcept;
  void execute_misc(unsigned x, unsigned nn) noexcept;

  std::array<std::uint8_t, kMemorySize> mem_{};
  std::array<std::uint8_t, 16> v_{};
  std::array<std::uint16_t, kStackDepth> stack_{};
  Display display_;
  Keypad keys_;
  Rng rng_;
  std::uint64_t cycles_ = 0;
  std::uint16_t pc_ = kProgramBase;
  std::uint16_t i_ = 0;
  std::uint8_t sp_ = 0;
  std::uint8_t dt_ = 0;
  std::uint8_t st_ = 0;
};

}  // namespace chip8
