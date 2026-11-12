#pragma once
/// @file job.hpp
/// The textual job format: ROM hex, cycle budget and optional key schedule.

#include <cstdint>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

#include "chip8/keypad.hpp"
#include "chip8/machine.hpp"

namespace chip8 {

/// Thrown when job text is malformed.
class ParseError : public std::runtime_error {
 public:
  using std::runtime_error::runtime_error;
};

/// A fully parsed job.
struct Job {
  std::vector<std::uint8_t> rom;
  std::uint64_t cycles = 0;
  KeySchedule schedule;
};

/// Decode a lowercase/uppercase hex string (even length) into bytes.
/// Throws ParseError on odd length or non-hex characters.
std::vector<std::uint8_t> parse_hex(std::string_view hex);

/// Parse a key schedule line such as "9:0300 12:0000". An empty string gives
/// an empty schedule. Throws ParseError if malformed or not strictly increasing.
KeySchedule parse_key_schedule(std::string_view line);

/// Parse the whole input text (`<rom-hex>\n<cycles>\n[<key-schedule>]`).
/// Throws ParseError on malformed input.
Job parse_job(std::string_view text);

/// Build a machine from @p job, run it to completion and return it.
Machine run_job(Job job);

}  // namespace chip8
