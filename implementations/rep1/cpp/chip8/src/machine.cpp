#include "chip8/machine.hpp"

#include <algorithm>
#include <string>

#include "chip8/font.hpp"

namespace chip8 {

Machine::Machine() {
  const auto& font = font_data();
  std::copy(font.begin(), font.end(), mem_.begin() + kFontBase);
}

void Machine::load_rom(const std::vector<std::uint8_t>& rom) {
  if (rom.size() > kMaxRomSize) {
    throw std::length_error("ROM of " + std::to_string(rom.size()) + " bytes does not fit in memory");
  }
  std::copy(rom.begin(), rom.end(), mem_.begin() + kProgramBase);
}

void Machine::run(std::uint64_t cycles, KeySchedule& schedule) noexcept {
  for (std::uint64_t n = 0; n < cycles; ++n) {
    if (const KeyEvent* ev = schedule.take_due(cycles_)) keys_.set_mask(ev->mask);
    step();
  }
}

void Machine::run(std::uint64_t cycles) noexcept {
  for (std::uint64_t n = 0; n < cycles; ++n) step();
}

void Machine::step() noexcept {
  const std::uint16_t op = static_cast<std::uint16_t>((mem_[pc_] << 8) | mem_[(pc_ + 1) & 0xFFF]);
  pc_ = (pc_ + 2) & 0xFFF;
  execute(op);
  if ((++cycles_ & 7u) == 0) {
    if (dt_ > 0) --dt_;
    if (st_ > 0) --st_;
  }
}

void Machine::execute(std::uint16_t op) noexcept {
  const unsigned x = (op >> 8) & 0xF;
  const unsigned y = (op >> 4) & 0xF;
  const unsigned n = op & 0xF;
  const unsigned nn = op & 0xFF;
  const unsigned nnn = op & 0xFFF;

  switch (op >> 12) {
    case 0x0:
      if (op == 0x00E0) {
        display_.clear();
      } else if (op == 0x00EE) {
        if (sp_ > 0) pc_ = stack_[--sp_] & 0xFFF;
      }
      break;
    case 0x1:
      pc_ = static_cast<std::uint16_t>(nnn);
      break;
    case 0x2:
      if (sp_ < kStackDepth) {
        stack_[sp_++] = pc_;
        pc_ = static_cast<std::uint16_t>(nnn);
      }
      break;
    case 0x3:
      if (v_[x] == nn) pc_ = (pc_ + 2) & 0xFFF;
      break;
    case 0x4:
      if (v_[x] != nn) pc_ = (pc_ + 2) & 0xFFF;
      break;
    case 0x5:
      if (n == 0 && v_[x] == v_[y]) pc_ = (pc_ + 2) & 0xFFF;
      break;
    case 0x6:
      v_[x] = static_cast<std::uint8_t>(nn);
      break;
    case 0x7:
      v_[x] = static_cast<std::uint8_t>(v_[x] + nn);
      break;
    case 0x8:
      execute_alu(x, y, n);
      break;
    case 0x9:
      if (n == 0 && v_[x] != v_[y]) pc_ = (pc_ + 2) & 0xFFF;
      break;
    case 0xA:
      i_ = static_cast<std::uint16_t>(nnn);
      break;
    case 0xB:
      pc_ = static_cast<std::uint16_t>((nnn + v_[0]) & 0xFFF);
      break;
    case 0xC:
      v_[x] = static_cast<std::uint8_t>(rng_.next_byte() & nn);
      break;
    case 0xD: {
      const bool collision = display_.draw_sprite(v_[x], v_[y], static_cast<int>(n), [this](int row) {
        return mem_[(i_ + row) & 0xFFF];
      });
      v_[0xF] = collision ? 1 : 0;
      break;
    }
    case 0xE:
      if (nn == 0x9E) {
        if (keys_.is_down(v_[x])) pc_ = (pc_ + 2) & 0xFFF;
      } else if (nn == 0xA1) {
        if (!keys_.is_down(v_[x])) pc_ = (pc_ + 2) & 0xFFF;
      }
      break;
    case 0xF:
      execute_misc(x, nn);
      break;
  }
}

void Machine::execute_alu(unsigned x, unsigned y, unsigned n) noexcept {
  const unsigned vx = v_[x];
  const unsigned vy = v_[y];
  // The result is written to VX first, then the flag to VF, so VF wins if X == 0xF.
  switch (n) {
    case 0x0: v_[x] = static_cast<std::uint8_t>(vy); break;
    case 0x1: v_[x] = static_cast<std::uint8_t>(vx | vy); break;
    case 0x2: v_[x] = static_cast<std::uint8_t>(vx & vy); break;
    case 0x3: v_[x] = static_cast<std::uint8_t>(vx ^ vy); break;
    case 0x4:
      v_[x] = static_cast<std::uint8_t>(vx + vy);
      v_[0xF] = (vx + vy > 255) ? 1 : 0;
      break;
    case 0x5:
      v_[x] = static_cast<std::uint8_t>(vx - vy);
      v_[0xF] = (vx >= vy) ? 1 : 0;
      break;
    case 0x6:
      v_[x] = static_cast<std::uint8_t>(vx >> 1);
      v_[0xF] = static_cast<std::uint8_t>(vx & 1);
      break;
    case 0x7:
      v_[x] = static_cast<std::uint8_t>(vy - vx);
      v_[0xF] = (vy >= vx) ? 1 : 0;
      break;
    case 0xE:
      v_[x] = static_cast<std::uint8_t>(vx << 1);
      v_[0xF] = static_cast<std::uint8_t>((vx >> 7) & 1);
      break;
    default: break;  // unassigned: no-op
  }
}

void Machine::execute_misc(unsigned x, unsigned nn) noexcept {
  switch (nn) {
    case 0x07: v_[x] = dt_; break;
    case 0x0A: {
      const int key = keys_.lowest_down();
      if (key >= 0) {
        v_[x] = static_cast<std::uint8_t>(key);
      } else {
        pc_ = (pc_ - 2) & 0xFFF;
      }
      break;
    }
    case 0x15: dt_ = v_[x]; break;
    case 0x18: st_ = v_[x]; break;
    case 0x1E: i_ = static_cast<std::uint16_t>(i_ + v_[x]); break;
    case 0x29: i_ = font_address(v_[x]); break;
    case 0x33: {
      const unsigned value = v_[x];
      mem_[i_ & 0xFFF] = static_cast<std::uint8_t>(value / 100);
      mem_[(i_ + 1) & 0xFFF] = static_cast<std::uint8_t>((value / 10) % 10);
      mem_[(i_ + 2) & 0xFFF] = static_cast<std::uint8_t>(value % 10);
      break;
    }
    case 0x55:
      for (unsigned k = 0; k <= x; ++k) mem_[(i_ + k) & 0xFFF] = v_[k];
      break;
    case 0x65:
      for (unsigned k = 0; k <= x; ++k) v_[k] = mem_[(i_ + k) & 0xFFF];
      break;
    default: break;  // unassigned: no-op
  }
}

}  // namespace chip8
