# chip8: required implementation approach

SPEC.md defines what the program must output. This note defines how it computes
it. Where the two seem to disagree, SPEC.md wins.

## Overall approach

A plain fetch-decode-execute interpreter. Parse the input once into a 4096-byte
memory image, a cycle count and an array of key events. Run one loop of exactly
`N` iterations; each iteration applies a pending key event, fetches the 16-bit
opcode from memory, dispatches on its top nibble with a single branch table,
executes the instruction directly on the machine state, and ticks the timers
every eighth cycle. The display is 32 rows, each held as one 64-bit word, and
sprites are XORed in a whole row at a time. After the loop, format the 34
output lines into one buffer and write it once.

## Required choices

1. **Interpret every cycle from memory.** Fetch `mem[PC]` and
   `mem[(PC + 1) & 0xFFF]` each cycle and decode on the spot. Do not
   pre-decode the ROM, cache decoded instructions, translate basic blocks or
   JIT: programs write memory (`FX33`, `FX55`) and may execute it, so a cache
   needs invalidation and changes the cost model away from "an interpreter
   loop". Work per cycle is O(1) apart from `DXYN` (O(N) rows), `FX55`/`FX65`
   (O(X+1)) and `00E0` (O(32)); total work is O(cycles), independent of ROM
   size.
2. **Fixed-size, flat machine state.** Memory is a 4096-byte array, registers a
   16-byte array, the stack a 16-entry array with an integer `SP`; `PC`, `I`,
   `DT`, `ST`, the key mask (16-bit) and the RNG state (32-bit) are plain
   integers. Everything is allocated once before the loop. The whole cycle
   loop lives in one function, and the hot scalars (`PC`, `I`, `SP`, `DT`,
   `ST`, the key mask, the RNG state, the cycle counter and the event cursor)
   are local variables of that function, written back to a struct/object only
   after the loop if at all; the arrays may be locals or fields of one
   struct/object. Apply the 12-bit and 16-bit masks with bitwise AND, not
   modulo of general integers or range checks.
3. **One dispatch per cycle on the top nibble.** Use one multi-way branch
   (`switch`/`match`, or an `if`/`elif` chain in languages without one) on
   `op >> 12`, with a nested branch on the low nibble for `8XYN` and on the low
   byte for `EXNN`/`FXNN`. The common instructions execute inline in the loop
   body. Do not dispatch through a table of function pointers, closures,
   per-opcode objects or virtual methods, and do not test the full opcode
   against a list of mask/value patterns in sequence (an `if`/`elif` chain is
   acceptable only when it branches on the extracted nibble or byte as
   described here).
4. **Display as 32 row words of 64 bits.** Row `y` is one unsigned 64-bit word;
   column `x` is one bit (any fixed bit order). For each sprite row, `DXYN`
   reads `byte = mem[(I + row) & 0xFFF]`, places its 8 bits at columns
   `sx .. sx+7` with a 64-bit rotate, which gives the horizontal wrap for free
   (with column 0 as the most significant bit: rotate `byte << 56` right by
   `sx`; with column 0 as the least significant bit: bit-reverse the byte,
   by a 256-entry table or a builtin, then rotate left by `sx`), detects
   collision with one AND against row word `(sy + row) & 31`, and applies it
   with one XOR. Per-sprite cost is O(N) word operations, not O(8N) pixel
   operations. `00E0` zeroes the 32 words in place. In a language whose
   integers are arbitrary-precision, keep each row as an integer, build the
   rotate from two shifts and mask the result to 64 bits.
5. **Key schedule as a sorted array with a cursor.** Events are parsed once into
   an array in input order. The loop holds the index of the next event and
   compares its cycle with the current cycle; when equal it loads the mask and
   advances the cursor. O(1) per cycle and O(events) overall; no lookup
   structure, search or per-cycle scan.
6. **Timers and keys as integer arithmetic.** The timer tick tests
   `(cycle + 1) & 7 == 0` (or a counter that wraps at 8). Key tests use
   `(keys >> (VX & 0xF)) & 1`. `FX0A` finds the lowest pressed key with a
   count-trailing-zeros on the 16-bit mask or a loop of at most 16 steps.
7. **RNG with native 32-bit wraparound.** Use unsigned 32-bit multiply-add
   (`s = s * 1103515245 + 12345`); where integers do not wrap, mask with
   `0xFFFFFFFF`. No library random generator.
8. **Input parsing in one pass.** Read all of stdin at once, split into at most
   three lines, convert the ROM hex digit pairs directly into memory at `0x200`,
   parse the cycle count and key events with simple digit loops or the standard
   integer parsers. Parsing is O(input size).
9. **Output built once.** Produce the 32 display rows by testing each of the
   64 bits of each row word into a byte buffer, append the two state lines with
   fixed-width hex formatting, and write the whole buffer to stdout in one
   write (or through one buffered writer flushed once).

## Left to the implementer

- Bit order inside a row word (column 0 as the least or most significant bit),
  as long as the rotate and the output agree.
- Whether the arrays live in locals or one struct/object, and whether rare
  instructions (`FX33`, `FX55`/`FX65`, `DXYN`, the output formatter) are small
  helper functions, provided the hot loop's dispatch stays a direct branch.
- Integer widths for `PC`, `I`, `SP`, the opcode fields and the loop counter,
  and whether opcode fields are extracted before dispatch or inside each case.
- Using a counter instead of `(cycle + 1) & 7` for timers, skipping zero sprite
  bytes, and other micro-optimisations that keep the same structure.
- Exact container types for the key-event array and output buffer, module
  layout, naming and error handling for malformed input (input is always
  well-formed).
- Compiler flags beyond a normal optimised release build.

## Pitfalls

- Drawing pixel by pixel into a byte- or bool-per-pixel grid: eight loads,
  compares and stores per sprite row instead of one AND and one XOR. On the
  sprite-heavy workload this is several times more display work.
- Calling a non-inlined function (or method on a large machine object) per
  cycle for the whole decode/execute step, or per-opcode handler calls through
  a table; per-cycle call overhead and lost register allocation dominate a loop
  of 5 million simple instructions. Reading and writing `PC`, `I` and the other
  scalars as fields through a pointer, reference or `self` on every cycle has
  the same effect (and in interpreted languages costs an attribute lookup per
  access).
- Building the wrapped sprite row as `(b << sx) | (b >> (64 - sx))` with a
  plain shift: a shift by 64 when `sx = 0` is undefined or traps in several
  languages. Use the rotate builtin, or a formulation without a 64-bit shift
  count.
- Allocating per cycle or per instruction: building a new display array on
  `00E0`, creating tuples/objects for decoded fields, boxing integers, or
  formatting strings inside the loop.
- Looking up key events in a map or scanning the event list each cycle instead
  of advancing a cursor.
- Pre-decoding or caching instructions, which either breaks on self-modifying
  code or adds an invalidation check to every memory write.
- Using arbitrary-precision or floating-point arithmetic for the RNG or
  registers where fixed-width unsigned integers are available, or modulo of
  signed values instead of masking.
- Producing output with one unbuffered write per pixel or per line.
