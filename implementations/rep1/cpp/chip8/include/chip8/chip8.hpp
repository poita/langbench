#pragma once
/// @file chip8.hpp
/// Umbrella header for the chip8 library.
///
/// Modules:
///  - rng.hpp      deterministic LCG for CXNN
///  - font.hpp     built-in hex font
///  - display.hpp  64x32 XOR frame buffer
///  - keypad.hpp   key state and key schedule
///  - machine.hpp  CPU/memory model and the cycle loop
///  - job.hpp      parsing of the textual job format, run_job()
///  - report.hpp   formatting of the final state

#include "chip8/display.hpp"
#include "chip8/font.hpp"
#include "chip8/job.hpp"
#include "chip8/keypad.hpp"
#include "chip8/machine.hpp"
#include "chip8/report.hpp"
#include "chip8/rng.hpp"
