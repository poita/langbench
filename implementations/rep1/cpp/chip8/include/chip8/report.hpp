#pragma once
/// @file report.hpp
/// Formatting of machine state into the 34-line output format.

#include <string>

#include "chip8/machine.hpp"

namespace chip8 {

/// "PC=0208 I=0000 SP=0 DT=00 ST=00" (no trailing newline).
std::string format_status(const Machine& m);

/// "V=01 01 00 ..." (no trailing newline).
std::string format_registers(const Machine& m);

/// The full report: 32 display lines, status line, register line, each
/// terminated by '\n'.
std::string format_report(const Machine& m);

}  // namespace chip8
