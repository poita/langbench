# CHIP-8 emulator

Implement a CHIP-8 interpreter with a fully specified, deterministic variant of
the classic semantics. The program reads a ROM, a cycle budget and an optional
key schedule from stdin, executes exactly that many instruction cycles, and
prints the display and the CPU state.

Everything an implementer needs is in this document. Where real CHIP-8
interpreters historically disagree (shifts, `FX55`/`FX65`, `BNNN`, sprite
wrapping, timer rate, randomness), this specification picks one behaviour and
the tests depend on it. Do not consult other CHIP-8 references for behaviour;
they will disagree with this document on some points.

## Input

Input is ASCII text with `\n` line endings. The trailing newline after the
last line is optional. Lines contain no leading or trailing whitespace, and
nothing follows the last line described below.

```
<rom-hex>
<cycles>
<key-schedule>        (optional third line)
```

- `<rom-hex>`: the ROM bytes as lowercase hexadecimal, two digits per byte, no
  separators. Its length is even, at least 2 digits (1 byte) and at most 7168
  digits (3584 bytes). The ROM is loaded into memory starting at address
  `0x200`; a 3584-byte ROM therefore fills memory up to and including `0xFFF`.
- `<cycles>`: a decimal integer `N`, `0 <= N <= 4000000000`, the exact number of
  instruction cycles to execute. Decimal integers in the input have no sign
  and no leading zeros (`0` itself is written as `0`).
- `<key-schedule>`: zero or more events separated by single spaces. Each event
  is `<cycle>:<mask>` where `<cycle>` is a decimal integer in `[0, N]` and
  `<mask>` is exactly four lowercase hex digits giving a 16-bit key state: bit
  `k` (value `1 << k`) set means key `k` (`0x0`-`0xF`) is held down. Events
  are in strictly increasing order of `<cycle>`. An event with cycle `c` takes
  effect immediately before cycle number `c` (0-based) executes and stays in
  effect until the next event (an event with `<cycle>` equal to `N` therefore
  never affects anything). Before the first event all keys are up. If the
  third line is missing or empty, all keys are up for the whole run.

## Output

Exactly 34 lines, each terminated by `\n`:

1. Lines 1-32: the display, row 0 (top) first. Each line has exactly 64
   characters, column 0 (left) first: `#` for a lit pixel, `.` for an unlit
   pixel.
2. Line 33: `PC=<hex4> I=<hex4> SP=<n> DT=<hex2> ST=<hex2>` — the program
   counter and index register as 4 lowercase hex digits, the stack pointer
   (number of entries on the stack, 0-16) in decimal without padding, and the
   delay and sound timers as 2 lowercase hex digits.
3. Line 34: `V=` followed by the 16 registers `V0`..`VF` in order, each as 2
   lowercase hex digits, separated by single spaces.

All hex output is lowercase and zero-padded to the stated width.

## Machine model

- **Memory**: 4096 bytes, addresses `0x000`-`0xFFF`, all zero initially except:
  - the built-in font at `0x050`-`0x09F` (80 bytes, listed below), and
  - the ROM at `0x200` onward.
  Every memory access (instruction fetch, sprite read, `FX33`, `FX55`, `FX65`)
  uses the address masked to 12 bits: `mem[addr & 0xFFF]`. An access to
  `I + k` therefore wraps from `0xFFF` to `0x000`.
- **Registers**: sixteen 8-bit registers `V0`..`VF`; `VF` doubles as the flag
  register. All start at 0.
- **I**: a 16-bit index register, initially 0. It may hold values above
  `0xFFF` (see `FX1E`); the 12-bit masking is applied at access time only.
  Output prints the full 16-bit value.
- **PC**: 12-bit program counter, initially `0x200`. Every update to PC is
  masked: `PC = value & 0xFFF`. PC may become odd (for example after `BNNN`
  with an odd `V0`) and may point anywhere in memory, including the font
  area, low memory and `0xFFF`; fetching and executing from such addresses
  follows the ordinary rules below with nothing special happening.
- **Stack**: 16 entries of 12-bit return addresses; `SP` counts entries
  (0..16). Tests do fill all 16 entries (`SP = 16`). Test inputs never push a
  17th entry or pop an empty stack, so the behaviour in those situations is
  unspecified.
- **DT, ST**: 8-bit delay and sound timers, initially 0.
- **Display**: 64 columns x 32 rows of 1-bit pixels, all off initially.
- **Keys**: 16 keys, states supplied by the key schedule.
- **RNG**: a 32-bit linear congruential generator, see `CXNN`.

## Cycle

Cycles are numbered `0 .. N-1`. Each cycle:

1. Apply any key-schedule event whose cycle number equals the current cycle.
2. Fetch: `op = (mem[PC] << 8) | mem[(PC + 1) & 0xFFF]`, then
   `PC = (PC + 2) & 0xFFF`. When `PC = 0xFFF` the low byte of the opcode is
   read from address `0x000` and PC becomes `0x001`.
3. Execute `op` as defined below. Instructions that "skip" do
   `PC = (PC + 2) & 0xFFF` once more.
4. Timer tick: if the number of cycles completed so far (i.e. this cycle's
   0-based number plus one) is a multiple of 8, then `DT = DT - 1` if `DT > 0`
   and `ST = ST - 1` if `ST > 0`. The tick happens after the instruction in
   the same cycle, so `FX15` executed in cycle 7 (the eighth cycle) is
   decremented immediately afterwards.

A cycle in which `FX0A` is waiting for a key still counts as a cycle (it
fetches, re-executes and ticks the timers like any other). There is no
special handling of infinite loops: a `1NNN` jumping to itself simply consumes
the remaining budget. Execution stops exactly when `N` cycles have completed;
the output describes the state at that point. With `N = 0` nothing executes.

## Instructions

Notation: `X` and `Y` are register indices from the second and third nibble,
`N` is the low nibble, `NN` the low byte, `NNN` the low 12 bits. Arithmetic on
registers is modulo 256. For every instruction that sets `VF` as a flag, the
result is written to `VX` **first** and the flag to `VF` **afterwards**, so
when `X = F` the flag value wins.

| Opcode | Semantics |
|--------|-----------|
| `00E0` | Clear the display (all pixels off). |
| `00EE` | Return: `SP = SP - 1; PC = stack[SP]`. |
| `0NNN` (other) | No operation. Any `0xxx` opcode other than `00E0`/`00EE`. |
| `1NNN` | `PC = NNN`. |
| `2NNN` | Call: `stack[SP] = PC; SP = SP + 1; PC = NNN` (PC already points past the call). |
| `3XNN` | Skip next instruction if `VX == NN`. |
| `4XNN` | Skip next instruction if `VX != NN`. |
| `5XY0` | Skip next instruction if `VX == VY`. |
| `6XNN` | `VX = NN`. |
| `7XNN` | `VX = (VX + NN) & 0xFF`. `VF` is not modified. |
| `8XY0` | `VX = VY`. |
| `8XY1` | `VX = VX \| VY`. `VF` is not modified. |
| `8XY2` | `VX = VX & VY`. `VF` is not modified. |
| `8XY3` | `VX = VX ^ VY`. `VF` is not modified. |
| `8XY4` | `sum = VX + VY; VX = sum & 0xFF; VF = 1 if sum > 255 else 0`. |
| `8XY5` | `diff = VX - VY; VX = diff & 0xFF; VF = 1 if VX >= VY (before the write) else 0` (i.e. `VF = 1` means no borrow). |
| `8XY6` | `flag = VX & 1; VX = VX >> 1; VF = flag`. Shifts `VX` in place; `VY` is ignored. |
| `8XY7` | `diff = VY - VX; VX = diff & 0xFF; VF = 1 if VY >= VX (before the write) else 0`. |
| `8XYE` | `flag = (VX >> 7) & 1; VX = (VX << 1) & 0xFF; VF = flag`. Shifts `VX` in place; `VY` is ignored. |
| `9XY0` | Skip next instruction if `VX != VY`. |
| `ANNN` | `I = NNN`. |
| `BNNN` | `PC = (NNN + V0) & 0xFFF`. Always uses `V0`. |
| `CXNN` | `VX = random_byte() & NN`. See RNG below. The RNG advances even when `NN = 0`. `VF` is not modified unless `X = F`. |
| `DXYN` | Draw sprite. See below. |
| `EX9E` | Skip next instruction if key `VX & 0xF` is down. |
| `EXA1` | Skip next instruction if key `VX & 0xF` is up. |
| `FX07` | `VX = DT`. |
| `FX0A` | Wait for key: if any key is down, `VX = index of the lowest-numbered key that is down` and execution continues. If no key is down, `PC = (PC - 2) & 0xFFF` so the same instruction executes again next cycle. |
| `FX15` | `DT = VX`. |
| `FX18` | `ST = VX`. |
| `FX1E` | `I = (I + VX) & 0xFFFF`. `VF` is not modified. |
| `FX29` | `I = 0x050 + (VX & 0xF) * 5` (address of the font glyph for the low nibble of `VX`). |
| `FX33` | BCD: `mem[I] = VX / 100; mem[I+1] = (VX / 10) % 10; mem[I+2] = VX % 10` (integer division; each address masked to 12 bits). `I` is not modified. |
| `FX55` | `mem[I + k] = Vk` for `k = 0 .. X` inclusive (addresses masked). `I` is not modified. |
| `FX65` | `Vk = mem[I + k]` for `k = 0 .. X` inclusive (addresses masked). `I` is not modified. |

Any opcode not listed above (for example `5XY1`, `8XY8`, `9XY3`, `E000`,
`F0FF`) is a no-op: PC has already advanced past it and nothing else changes.

The skip instructions always skip exactly 2 bytes (one instruction).

### `DXYN` — draw sprite

```
sx = VX & 63            (VX mod 64)
sy = VY & 31            (VY mod 32)
VF = 0
for row in 0 .. N-1:
    byte = mem[(I + row) & 0xFFF]
    for bit in 0 .. 7:
        if (byte >> (7 - bit)) & 1:
            px = (sx + bit) & 63
            py = (sy + row) & 31
            if pixel[py][px] is on: VF = 1
            pixel[py][px] = not pixel[py][px]     (XOR)
```

The sprite's origin is reduced modulo 64/32, and pixels that extend past the
right or bottom edge wrap around to the left/top (no clipping). `VF` becomes
1 if any pixel was turned off by this draw, else 0. `N = 0` draws nothing and
sets `VF = 0`.

### `CXNN` — random numbers

The RNG state is a 32-bit unsigned integer `s`, initially `0x12345678`.
Every execution of `CXNN` (and nothing else) advances it once:

```
s = (s * 1103515245 + 12345) mod 2^32
random_byte = (s >> 16) & 0xFF
VX = random_byte & NN
```

The first three states after the seed are `0x0b719151`, `0x6f47bdb6`,
`0x2e1d6ab7`, giving random bytes `0x71`, `0x47`, `0x1d`.

### Font

80 bytes stored at `0x050`, five bytes per glyph for `0`..`F` in order:

```
F0 90 90 90 F0   20 60 20 20 70   F0 10 F0 80 F0   F0 10 F0 10 F0
90 90 F0 10 10   F0 80 F0 10 F0   F0 80 F0 90 F0   F0 10 20 40 40
F0 90 F0 90 F0   F0 90 F0 10 F0   F0 90 F0 90 90   E0 90 E0 90 E0
F0 80 80 80 F0   E0 90 90 90 E0   F0 80 F0 80 F0   F0 80 F0 80 80
```

## Worked examples

### Example 1: arithmetic and a self-loop

Input:

```
60ff7001610180141208
6
```

The ROM is `60FF` (`V0 = 0xFF`), `7001` (`V0 += 1` -> `0x00`, VF untouched),
`6101` (`V1 = 1`), `8014` (`V0 = V0 + V1 = 1`, VF = 0), `1208` (jump to
`0x208`, itself). Cycles 0-3 run the four instructions, cycles 4 and 5 both
execute the self-jump. Output: 32 lines of 64 dots, then

```
PC=0208 I=0000 SP=0 DT=00 ST=00
V=01 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00
```

### Example 2: drawing with wrap-around and collision

Input:

```
6a3e6b1e6000f029dab5dab5
5
```

`V[A] = 62`, `V[B] = 30`, `V0 = 0`, `I = font('0') = 0x050`, draw the 5-row
glyph `0` at (62, 30). Only five cycles run, so the second `DAB5` is not
executed. Rows 30 and 31 receive `F0` and `90`; rows 0, 1 and 2 receive `90`,
`90`, `F0` (vertical wrap), and columns 62, 63, 0, 1 are used (horizontal
wrap). No pixel was already lit, so `VF = 0`. Output:

```
.#............................................................#.
.#............................................................#.
##............................................................##
................................................................
   ... (26 more all-dot rows: rows 4 to 29) ...
##............................................................##
.#............................................................#.
PC=020a I=0050 SP=0 DT=00 ST=00
V=00 00 00 00 00 00 00 00 00 00 3e 1e 00 00 00 00
```

With `6` cycles the second draw XORs the same pixels off again: the display
is blank and `VF = 01`, PC is `020c`.

### Example 3: random numbers, timers and keys

Input:

```
c0ffc1ffc20f6408f415f007e2a11200e4a1120af00a
14
9:0300
```

Cycles 0-2 execute `C0FF`, `C1FF`, `C20F`: the LCG produces
`s = (0x12345678 * 1103515245 + 12345) mod 2^32 = 0x0b719151` -> byte `0x71`,
then `s = 0x6f47bdb6` -> byte `0x47`, then `s = 0x2e1d6ab7` -> byte `0x1d`,
masked with `0x0F` to `0x0d`. So `V0 = 71`, `V1 = 47`, `V2 = 0d`.
Cycle 3: `6408` (`V4 = 8`). Cycle 4: `F415` (`DT = 8`). Cycle 5: `F007`
(`V0 = DT = 8`). Cycle 6: `E2A1` — key 7 is up, so skip `1200`. Cycle 7:
`E4A1` — key 8 is up, skip `120A`; the tick after cycle 7 (8 cycles done)
sets `DT = 7`. Cycle 8: `F00A` — no key down, PC stays at `0x214`. Before
cycle 9 the event `9:0300` presses keys 8 and 9. Cycle 9: `F00A` stores the
lowest pressed key, `V0 = 8`, PC = `0x216`. Cycles 10-13 fetch `0000` from
untouched memory (no-ops); after cycle 13 nothing more happens to DT because
16 cycles were not completed. Output: 32 blank rows, then

```
PC=021e I=0000 SP=0 DT=07 ST=00
V=08 47 0d 00 08 00 00 00 00 00 00 00 00 00 00 00
```

## Performance

ROMs are at most 3584 bytes. The largest tests execute 5,000,000 cycles,
one of them drawing a 5-row sprite every 9 cycles. The reference Python
implementation runs each of the largest tests in about 3-4 s; a compiled
implementation should take well under a second. Suggested timeout: 30 s (the
runner's default).

Input parsing is not part of the challenge: the input is always well-formed as
described above.
