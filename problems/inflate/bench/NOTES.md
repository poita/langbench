# inflate performance benchmark

Regenerate with `python3 problems/inflate/bench/gen_bench.py` (fixed seed). Every input is a raw DEFLATE stream
from zlib that inflates to exactly 1 MiB, the maximum SPEC.md allows; expected outputs come from reference/main.py and are
cross-checked against zlib. Because the spec caps output at 1 MiB per stream (one stream per input), fast compiled decoders
take only ~25-60 ms per input including process start-up (~5-10 ms); the inputs are as heavy as the spec permits.

- `001_literal_heavy_sensor_1mb` — 4-channel 16-bit noisy sine telemetry, zlib level 6 (994 KB stream, 64 dynamic blocks).
  Almost all literals from a wide alphabet with long codes and few short matches: measures raw Huffman decode throughput
  and the largest allowed hex input (~2 MB) to parse.
- `002_many_dynamic_blocks_1mb` — English-like prose mixed with program-source text, zlib level 1 memLevel 1 (2386 dynamic
  blocks of ~128 symbols each). Stresses per-block work: reading code-length codes and rebuilding literal/length and distance
  tables thousands of times, as a low-memory streaming compressor really produces.
- `003_mixed_archive_1mb` — tar-like concatenation of text, source, binary records, run-heavy bitmaps, random (stored) data
  and duplicated files, zlib level 9 with a sync flush every 256 KiB. Mixes stored copies, long overlapping and near-32 KiB
  back-references and dynamic blocks, like decompressing an ordinary archive.

## Long tier

`python3 bench/gen_bench.py --long` writes `bench-long/` with the same three streams (same generators, seed and zlib
settings) at 16 MiB of output each instead of 1 MiB. SPEC.md's limit is raised to 16 MiB of output (32 MiB of hex) and
about 34 MiB of hex input. Expected outputs come from `reference/main.py` and are cross-checked against zlib (the whole
tier generates in about 30 s).

| input | fastest (user s, best of 2) | others (user s) | peak RSS compiled | python (wall / user, RSS) | size |
| --- | --- | --- | --- | --- | --- |
| 001_literal_heavy_sensor_1mb | rust 0.11 | cpp 0.15, d 0.15, go 0.22 | 129 MB | 8.6 s / 5.6 s, 196 MB | 65 MB |
| 002_many_dynamic_blocks_1mb | rust 0.21 | cpp 0.21, d 0.23, go 0.27 | 98 MB | 13.3 s / 9.3 s, 160 MB | 50 MB |
| 003_mixed_archive_1mb | rust 0.05 | d 0.06, cpp 0.07, go 0.08 | 95 MB | 2.8 s / 1.8 s, 192 MB | 45 MB |

`bench-long/` is 153 MB. This tier is far from 5 s and cannot get there: the format is one stream per input with the
whole decompressed output printed as hex, and a compiled decoder handles ~100-300 MiB of output per second, so 6 s would
need 1-2 GiB of output per input (2-4 GB of expected hex per file). The size was chosen to keep the tier near the disk
budget. All five implementations pass all three. Times were measured on a heavily loaded machine.
