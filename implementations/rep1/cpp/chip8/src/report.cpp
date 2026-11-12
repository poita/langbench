#include "chip8/report.hpp"

namespace chip8 {
namespace {

void append_hex(std::string& out, unsigned value, int digits) {
  static const char kDigits[] = "0123456789abcdef";
  for (int shift = (digits - 1) * 4; shift >= 0; shift -= 4) out.push_back(kDigits[(value >> shift) & 0xF]);
}

}  // namespace

std::string format_status(const Machine& m) {
  std::string out = "PC=";
  append_hex(out, m.pc(), 4);
  out += " I=";
  append_hex(out, m.index(), 4);
  out += " SP=" + std::to_string(m.sp());
  out += " DT=";
  append_hex(out, m.delay_timer(), 2);
  out += " ST=";
  append_hex(out, m.sound_timer(), 2);
  return out;
}

std::string format_registers(const Machine& m) {
  std::string out = "V=";
  for (std::size_t i = 0; i < 16; ++i) {
    if (i) out.push_back(' ');
    append_hex(out, m.v(i), 2);
  }
  return out;
}

std::string format_report(const Machine& m) {
  std::string out = m.display().to_text();
  out += format_status(m);
  out.push_back('\n');
  out += format_registers(m);
  out.push_back('\n');
  return out;
}

}  // namespace chip8
