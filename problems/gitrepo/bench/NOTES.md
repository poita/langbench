# gitrepo performance inputs

Regenerate with `python3 problems/gitrepo/bench/gen_bench.py` (fixed seeds).
Run with `python3 run_tests.py gitrepo --tests-dir problems/gitrepo/bench -- <impl>/run.sh`.
All three use the largest corpus repositories and the spec's maximum of 999
commands. Expected outputs come from `reference/main.py`, and the generator
checks every answer against the git command line (`gen_tests.oracle`).

- `001_log_history_walks` (jscookie: 1085 commits, 4279 objects, 1.2 MiB pack,
  at the spec's size limits): 56 full-history `log` walks (from HEAD, main,
  all 39 tags and 15 points deep in first-parent history), plus 943 bounded
  `log <rev> <n>` walks (n from 1 to 200) starting from `HEAD~k`, tags, merge `^2`
  sides and full or abbreviated ids. It measures commit inflate and parse
  throughput and the date-ordered walk. Programs that cache parsed commits
  across commands win here, as `git log` itself does.
- `002_cat_file_reconstruct` (jscookie): 999 `cat-file` commands (20% using
  abbreviated ids) over 520 small and medium blobs, 30 blobs between 50 and
  450 KiB, 293 trees, 130 commits and all 26 annotated tags. Many of them are
  stored as OFS_DELTA chains up to 25 deep. It measures inflate, delta
  reconstruction and SHA-1 verification of every object read: the core
  object-store path, run over realistic content.
- `003_mixed_session` (itsdangerous: 678 commits, 241 merges, gpg-signed
  commits): a shuffled mix of 300 `diff` commands (merge vs. first parent,
  tag vs. tag, arbitrary revisions), 170 `ls-tree` (most with sub-paths),
  190 `rev-parse` (abbreviations, peels, `^2~n`, `~n^{tree}`), 150 bounded
  `log`, 180 `cat-file` and 9 `count-objects`. It measures the
  recursive tree flatten and sorted diff along with revision resolution, which
  is the kind of query mix a repository browser or CI tool issues. Three of
  the commands correctly answer `error`: they ask `ls-tree` for
  `docs/_themes`, which in those commits is a submodule (gitlink), not a tree.

## Long tier

`python3 bench/gen_bench.py --long` writes `bench-long/` over the same repositories with each session's command mix
repeated K times from the same seeded generators: 001 4x (3,996 commands: 224 full-history walks plus bounded walks),
002 4x (3,996 `cat-file`, four independent samples of the same object mix, so objects are re-read and re-verified),
003 10x (9,990 commands; 17 correctly answer `error`, the gitlink `ls-tree` cases). SPEC.md's limit is raised from 999 to
9,999 commands, with output files named by the command number zero-padded to at least three digits (`1000.out`, ...,
which is what `%03d` already produces). Expected outputs come from `reference/main.py` and every answer is again checked
against the git command line (about 11 min for all three).

| input | fastest (wall s, best of 2) | user + sys of fastest | others (wall s) | python (wall / user, RSS) | size |
| --- | --- | --- | --- | --- | --- |
| 001_log_history_walks | cpp 0.71 | 0.11 + 0.44 | rust 0.76, go 0.88, d 0.94 | 2.0 s / 0.7 s, 60 MB | 46 MB |
| 002_cat_file_reconstruct | rust 0.98 | 0.31 + 0.46 | cpp 1.02, go 1.11, d 1.22 | 83 s / 61 s, 98 MB | 60 MB |
| 003_mixed_session | rust 2.35 | 0.30 + 1.52 | go 2.35, d 2.34, cpp 2.42 | 13 s / 8 s, 48 MB | 51 MB |

Peak RSS of the compiled builds is at most 67 MB. `bench-long/` is 158 MB. This tier is far from 5 s: with the caches
APPROACH.md requires, every command costs microseconds once the repository is parsed, so the run time is dominated by
creating one output file per command (most of it is system time) and by output volume. Reaching 6 s would need tens of
thousands of output files and over 1 GB of expected output per input, or much larger repositories than the corpus holds.
All five implementations pass all three. Times were measured on a heavily loaded machine.
