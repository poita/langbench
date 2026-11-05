# Conventions

Each problem's directory, `problems/<slug>/`, contains:

- `SPEC.md`: what the program does, including the exact input and output
  formats, encodings, ordering and error cases.
- `APPROACH.md`: how the program is built: its core algorithms, their
  complexity, the main data representations, and pitfalls to avoid. Where the
  two seem to disagree, SPEC.md wins.
- `tests/`: the test cases, numbered so they sort roughly by difficulty.
- `verify.py`, for problems where several outputs are valid (a SAT assignment,
  a cube solution, a diff): the test runner calls it to check an output instead
  of comparing it with the expected one.

There are two kinds of problem:

- **Stdin mode.** Each test is `tests/NNN_name.in` with the expected stdout in
  `tests/NNN_name.out`. The program reads all input on stdin and writes all
  output on stdout; it takes no arguments and touches no files. Trailing
  whitespace on each line and trailing newlines are ignored.
- **Directory mode.** Each test is `tests/NNN_name/input` (a file or a
  directory) with the expected output tree in `tests/NNN_name/expected/`. The
  program is run as `run.sh <input path> <output dir>`, reads nothing on stdin,
  and writes its results only into the output directory, which is then compared
  with `expected/`.

In both: text is UTF-8, binary payloads are hex-encoded (lowercase, no
separators), and the program exits 0 on success; a nonzero exit fails the test.
Tests run with the current directory set to `problems/<slug>/`.

## build.sh and run.sh

A project has two scripts at its root:

- `build.sh` builds the project, inside the project directory (a no-op for an
  interpreted language). It must work from any current directory.
- `run.sh` runs the program: reading stdin and writing stdout, or taking
  `<input path> <output dir>` in directory mode. It must work from any current
  directory, so it locates the program relative to `$0`.

## Running the tests

```
python3 run_tests.py <slug> -- <path to run.sh>
```

`-v` prints each test's result and `--filter TEXT` runs only the tests whose
names contain TEXT.
