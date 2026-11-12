#include "chip8/job.hpp"

#include <limits>
#include <utility>

namespace chip8 {
namespace {

int hex_value(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

std::uint64_t parse_decimal(std::string_view s, const char* what) {
  if (s.empty()) throw ParseError(std::string("missing ") + what);
  std::uint64_t value = 0;
  for (char c : s) {
    if (c < '0' || c > '9') throw ParseError(std::string("invalid ") + what + ": '" + std::string(s) + "'");
    const std::uint64_t digit = static_cast<std::uint64_t>(c - '0');
    if (value > (std::numeric_limits<std::uint64_t>::max() - digit) / 10) {
      throw ParseError(std::string(what) + " out of range");
    }
    value = value * 10 + digit;
  }
  return value;
}

std::string_view trim(std::string_view s) {
  while (!s.empty() && (s.back() == '\r' || s.back() == ' ' || s.back() == '\t')) s.remove_suffix(1);
  while (!s.empty() && (s.front() == ' ' || s.front() == '\t')) s.remove_prefix(1);
  return s;
}

}  // namespace

std::vector<std::uint8_t> parse_hex(std::string_view hex) {
  if (hex.size() % 2 != 0) throw ParseError("hex string has odd length");
  std::vector<std::uint8_t> out;
  out.reserve(hex.size() / 2);
  for (std::size_t i = 0; i < hex.size(); i += 2) {
    const int hi = hex_value(hex[i]);
    const int lo = hex_value(hex[i + 1]);
    if (hi < 0 || lo < 0) throw ParseError("invalid hex digit in ROM");
    out.push_back(static_cast<std::uint8_t>(hi * 16 + lo));
  }
  return out;
}

KeySchedule parse_key_schedule(std::string_view line) {
  std::vector<KeyEvent> events;
  line = trim(line);
  std::size_t pos = 0;
  while (pos < line.size()) {
    std::size_t end = line.find(' ', pos);
    if (end == std::string_view::npos) end = line.size();
    const std::string_view token = line.substr(pos, end - pos);
    pos = end + 1;
    if (token.empty()) continue;
    const std::size_t colon = token.find(':');
    if (colon == std::string_view::npos) throw ParseError("key event without ':'");
    const std::uint64_t cycle = parse_decimal(token.substr(0, colon), "key event cycle");
    const std::string_view mask_text = token.substr(colon + 1);
    if (mask_text.size() != 4) throw ParseError("key mask must have four hex digits");
    unsigned mask = 0;
    for (char c : mask_text) {
      const int d = hex_value(c);
      if (d < 0) throw ParseError("invalid hex digit in key mask");
      mask = mask * 16 + static_cast<unsigned>(d);
    }
    if (!events.empty() && events.back().cycle >= cycle) {
      throw ParseError("key events must be in strictly increasing cycle order");
    }
    events.push_back({cycle, static_cast<std::uint16_t>(mask)});
  }
  return KeySchedule(std::move(events));
}

Job parse_job(std::string_view text) {
  std::string_view lines[3];
  int count = 0;
  std::size_t pos = 0;
  while (pos <= text.size() && count < 3) {
    std::size_t nl = text.find('\n', pos);
    if (nl == std::string_view::npos) nl = text.size();
    lines[count++] = trim(text.substr(pos, nl - pos));
    pos = nl + 1;
  }
  if (count < 2 || lines[0].empty()) throw ParseError("input needs a ROM line and a cycle-count line");

  Job job;
  job.rom = parse_hex(lines[0]);
  if (job.rom.empty()) throw ParseError("ROM is empty");
  if (job.rom.size() > kMaxRomSize) throw ParseError("ROM is larger than 3584 bytes");
  job.cycles = parse_decimal(lines[1], "cycle count");
  if (count == 3) job.schedule = parse_key_schedule(lines[2]);
  return job;
}

Machine run_job(Job job) {
  Machine m;
  m.load_rom(job.rom);
  m.run(job.cycles, job.schedule);
  return m;
}

}  // namespace chip8
