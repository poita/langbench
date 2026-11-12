# langvm

`langvm` is a compiler and stack virtual machine for **Vellum**, a small
statically typed language with modules, structs, sum types with exhaustive
pattern matching, generics, traits, closures, 64-bit wrapping integers,
IEEE-754 doubles, lists, insertion-ordered maps and a 132-function standard
library. It is written in Haskell (GHC 9.14) using only the packages that ship
with GHC; `hspec` and `QuickCheck` are used by the test suite.

The language is defined by the specification in [`docs/SPEC.md`](docs/SPEC.md). In
short, `langvm` reads a *module stream* on standard input, type-checks it,
compiles it to bytecode and runs it:

* if the program does not compile, the only output is one line,
  `error: <kind> at <line>:<col>`;
* if it compiles and runs, the output is whatever it printed;
* if it panics at run time, the output so far is followed by `panic: <message>`.

The exit code is always 0 for these outcomes.

## Building

```sh
./build.sh          # cabal build, then copies the executable to bin/langvm
cabal test          # the library's own tests (needs hspec and QuickCheck)
```

`build.sh` and `run.sh` work from any directory. Requirements: GHC 9.14 and
cabal-install 3.18; the build is a plain `cabal build` with the default
optimisation level and needs no packages beyond GHC's boot libraries.

## Command-line use

```sh
./run.sh < program.vel        # or: bin/langvm < program.vel
```

The program is a sequence of modules, each introduced by a header line
`@module <name>`; the module `main` must declare `fn main()`:

```
@module main
use util;

fn main() {
    print(util::greet("world"));
}
@module util
pub fn greet(who: Str) -> Str {
    "hello, " ++ who
}
```

```
$ ./run.sh < program.vel
hello, world
```

A type error is reported as a single line with a module-local position:

```
@module main
fn main() {
    let n: Int = 1;
    print(n + "x");
}
```

```
error: type-mismatch at 3:15
```

## Using the library

The `Langvm` module is the public entry point; each phase is also exposed
through its own module (`Langvm.Lexer`, `Langvm.Parser`, `Langvm.Check`, ...).

```haskell
import Langvm

main :: IO ()
main = do
  let source = unlines
        [ "@module main"
        , "fn main() { print(showInt(6 * 7)); }" ]

  -- Compile and run, collecting what the program prints.
  result <- runSource source putStr
  print result            -- Right Finished

  -- Or get exactly what the command-line tool would write to stdout.
  executeText source >>= putStr

  -- Or compile once and run the bytecode later.
  case compileText source of
    Left d     -> putStrLn (renderDiagnostic d)
    Right prog -> () <$ run prog putStr
```

* `compileText :: String -> Either Diagnostic Program` runs every compile-time
  pass and returns the first diagnostic, if any.
* `run :: Program -> (String -> IO ()) -> IO Outcome` executes a program;
  `Outcome` is `Finished` or `Panicked message`.
* `runSource` and `executeText` combine the two for a module stream held in a
  `String`.

## Design

The pipeline follows the phases of the specification, one module per phase:

| Module | Responsibility |
|---|---|
| `Langvm.Source` | split the input into modules (pass 0) |
| `Langvm.Lexer`, `Langvm.Parser`, `Langvm.Syntax` | tokens, recursive-descent parser with precedence climbing, AST |
| `Langvm.Items` | namespaces, `use`, visibility, type resolution, impl registry (pass 3) |
| `Langvm.Check`, `Langvm.Exhaust` | bidirectional type checking with union-find style unification, trait resolution, usefulness-based exhaustiveness (pass 4); produces `Langvm.Core` |
| `Langvm.Compile`, `Langvm.Bytecode` | closure conversion, slot allocation, match compilation, stack-depth tracking |
| `Langvm.VM` | the fetch-decode-execute loop with its own frame stack (no host recursion for Vellum calls) |
| `Langvm.Stdlib`, `Langvm.Collections`, `Langvm.Value` | the built-in functions, mutable lists, insertion-ordered hash maps, values and strings (arrays of scalar values) |
| `Langvm.Number` | exact decimal-to-binary64 and binary64-to-fixed-point conversion |
| `Langvm.Builtin` | the built-in table, including their signatures written in Vellum |

Everything after name resolution refers to items by integer id; nothing looks
up a string at run time. Method calls dispatch through a table keyed by trait
and the receiver's head constructor.

## Tests

`cabal test` runs the hspec suite in `test/Spec.hs`: lexer and splitter unit
tests, a table of diagnostics, runtime checks, golden programs in
`test/golden/` (the worked examples of the specification) and QuickCheck
properties that compare the VM against Haskell models (integer expressions,
stable `sortBy`, insertion-ordered maps, `showFloatAt` rounding, decimal
parsing).
