"""End-to-end builds: the specification's worked examples and engine behaviour."""

import pytest

from conftest import dedent

HELLO = 'step {\n    out "out/hello.txt"\n    cmd write("hello\\n")\n}\ndefault "out/hello.txt"\n'


def check(res, expected_log: str):
    assert res.log == dedent(expected_log)


def test_example_1_one_step(session):
    res = session({"main.kiln": HELLO}, "build")
    check(res, """
        step 1: build (default) -j 1
          run 0 1 w0 out/hello.txt write("hello\\n")
          ok ran=1 hit=0 time=1
    """)
    assert res.file("out/hello.txt") == "hello\n"
    assert res.file(".kiln-state") == dedent("""
        kiln-state 1
        step out/hello.txt
        cmd write("hello\\n")
        out out/hello.txt a9bc80cca21f28b3
        end
    """)


def test_example_2_touch_is_not_a_change(session):
    res = session({"main.kiln": HELLO}, "build\nbuild\ntouch main.kiln\nbuild")
    assert res.lines()[4:6] == ["  hit 0 out/hello.txt", "  ok ran=0 hit=1 time=0"]
    assert res.lines()[-2:] == ["  hit 0 out/hello.txt", "  ok ran=0 hit=1 time=0"]


def test_example_3_parallel_tie_break(session):
    main = ""
    for name, cost in (("a", 3), ("b", 1), ("c", 4), ("d", 2)):
        main += f'step {{\n out "out/{name}.txt"\n cmd write("{name.upper()}\\n")\n cost {cost}\n}}\n'
    main += 'step {\n out "out/all.txt"\n in ["out/a.txt", "out/b.txt", "out/c.txt", "out/d.txt"]\n cmd concat()\n cost 2\n}\n'
    main += 'default "out/all.txt"\n'
    res = session({"main.kiln": main}, "build -j 2")
    check(res, """
        step 1: build (default) -j 2
          run 0 3 w0 out/a.txt write("A\\n")
          run 0 1 w1 out/b.txt write("B\\n")
          run 1 5 w1 out/c.txt write("C\\n")
          run 3 5 w0 out/d.txt write("D\\n")
          run 5 7 w0 out/all.txt concat()
          ok ran=5 hit=0 time=7
    """)
    assert res.file("out/all.txt") == "A\nB\nC\nD\n"


def test_example_4_each_map_phony(session):
    main = """
let names = ["alpha", "beta", "gamma"]
let outs = map(names, "out/%.txt")
each i, n in names {
    step {
        out "out/{n}.txt"
        cmd write("{i}:{n}\\n")
        cost 1
    }
}
step {
    out "out/index.txt"
    in outs
    cmd concat()
}
phony all = ["out/index.txt"]
default "@all"
"""
    res = session({"main.kiln": main}, "build @all -j 3")
    check(res, """
        step 1: build @all -j 3
          run 0 1 w0 out/alpha.txt write("0:alpha\\n")
          run 0 1 w1 out/beta.txt write("1:beta\\n")
          run 0 1 w2 out/gamma.txt write("2:gamma\\n")
          run 1 3 w0 out/index.txt concat()
          ok ran=4 hit=0 time=3
    """)


def test_example_5_rules_and_state(session):
    main = """
rule bundle(name, parts, weight = 2) {
    step {
        out "out/{name}.txt"
        in parts
        cmd concat()
        cost weight
    }
}

let base = ["src/a.txt", "src/b.txt"]
use bundle("one", base)
use bundle(name = "two", parts = base ++ ["out/one.txt"], weight = 5)
phony all = ["out/one.txt", "out/two.txt"]
default "@all"
"""
    res = session({"main.kiln": main, "src/a.txt": "AAA\n", "src/b.txt": "BBB\n"}, "build -j 2")
    check(res, """
        step 1: build (default) -j 2
          run 0 2 w0 out/one.txt concat()
          run 2 7 w0 out/two.txt concat()
          ok ran=2 hit=0 time=7
    """)
    assert res.file(".kiln-state") == dedent("""
        kiln-state 1
        step out/one.txt
        cmd concat()
        in src/a.txt 8943a78b9f342c58
        in src/b.txt c857dca71c36fafd
        out out/one.txt 5e52e06e8b405ae8
        end
        step out/two.txt
        cmd concat()
        in src/a.txt 8943a78b9f342c58
        in src/b.txt c857dca71c36fafd
        in out/one.txt 5e52e06e8b405ae8
        out out/two.txt f98ee131e7582add
        end
    """)


def test_example_6_glob_include_set_when(session):
    files = {
        "src/a.txt": "a1\n", "src/b.txt": "b1\n", "src/sub/c.txt": "c1\n", "src/notes.md": "note\n",
        "tune.kiln": 'set mode = "slow"\nlet extra = 1\n',
        "main.kiln": """
let mode = "fast"
let flags = []
include "tune.kiln"
when mode == "fast" {
    set flags = flags ++ ["F"]
} otherwise {
    set flags = flags ++ ["S"]
}
let srcs = glob("src/**/*.txt")
step {
    out "out/list.txt"
    in srcs
    cmd count_lines()
}
step {
    out "out/flags.txt"
    cmd write("{join(flags, ",")}\\n")
}
default ["out/list.txt", "out/flags.txt"]
""",
    }
    res = session(files, "build -j 2")
    check(res, """
        step 1: build (default) -j 2
          run 0 2 w0 out/list.txt count_lines()
          run 0 1 w1 out/flags.txt write("S\\n")
          ok ran=2 hit=0 time=2
    """)
    assert res.file("out/list.txt") == "1 src/a.txt\n1 src/b.txt\n1 src/sub/c.txt\n3 total\n"


def test_example_7_preprocess_depfile(session):
    files = {
        "src/main.txt": "title\n@need src/part.txt\nend\n",
        "src/part.txt": "PART-A\n@need src/deep.txt\n",
        "src/deep.txt": "DEEP\n",
        "main.kiln": 'step {\n out "out/doc.txt"\n depfile "out/doc.d"\n in "src/main.txt"\n cmd preprocess()\n}\ndefault "out/doc.txt"\n',
    }
    res = session(files, "build\nbuild\nedit src/deep.txt\nDEEP2\n---\nbuild")
    check(res, """
        step 1: build (default) -j 1
          run 0 6 w0 out/doc.txt preprocess()
          ok ran=1 hit=0 time=6
        step 2: build (default) -j 1
          hit 0 out/doc.txt
          ok ran=0 hit=1 time=0
        step 3: edit src/deep.txt
          ok size=6
        step 4: build (default) -j 1
          run 0 6 w0 out/doc.txt preprocess()
          ok ran=1 hit=0 time=6
    """)
    assert res.file("out/doc.txt") == "title\nPART-A\nDEEP2\nend\n"
    assert res.file("out/doc.d") == "kiln-deps 1\nneed src/deep.txt\nneed src/part.txt\n"
    assert "dep src/deep.txt 06ae7bdd484568d7" in res.file(".kiln-state")


def test_example_8_early_cutoff(session):
    main = (
        'step {\n out "out/mid.txt"\n in "src/a.txt"\n cmd upper()\n}\n'
        'step {\n out "out/final.txt"\n in "out/mid.txt"\n cmd number()\n}\n'
        'default "out/final.txt"\n'
    )
    res = session({"main.kiln": main, "src/a.txt": "abc\n"}, "build\nedit src/a.txt\nABC\n---\nbuild")
    check(res, """
        step 1: build (default) -j 1
          run 0 2 w0 out/mid.txt upper()
          run 2 4 w0 out/final.txt number()
          ok ran=2 hit=0 time=4
        step 2: edit src/a.txt
          ok size=4
        step 3: build (default) -j 1
          run 0 2 w0 out/mid.txt upper()
          hit 2 out/final.txt
          ok ran=1 hit=1 time=2
    """)
    assert res.file("out/final.txt") == "1: ABC\n"


def test_example_9_cycle_writes_nothing(session):
    main = (
        'step {\n out "out/x.txt"\n in "out/y.txt"\n cmd copy()\n}\n'
        'step {\n out "out/y.txt"\n in "out/x.txt"\n cmd copy()\n}\n'
        'default "out/x.txt"\n'
    )
    res = session({"main.kiln": main}, "build")
    check(res, """
        step 1: build (default) -j 1
          error E_CYCLE out/x.txt -> out/y.txt -> out/x.txt
    """)
    assert res.fs.paths() == [b"main.kiln"]


@pytest.mark.parametrize(
    "main,files,error",
    [
        ('step {\n out "out/z.txt"\n cmd write("1\\n")\n}\nstep {\n out "out/z.txt"\n cmd write("2\\n")\n}\ndefault "out/z.txt"\n',
         {}, "E_DUP_OUTPUT out/z.txt"),
        ('step {\n out "out/z.txt"\n in ["src/a.txt", "src/missing.txt"]\n cmd concat()\n}\ndefault "out/z.txt"\n',
         {"src/a.txt": "a\n"}, "E_MISSING_INPUT src/missing.txt required by out/z.txt"),
        ('step {\n out "out/z.txt"\n cmd write(greeting)\n}\ndefault "out/z.txt"\n', {}, "E_UNKNOWN_VAR greeting"),
        ('let n = 3\nwhen n > 2 {\n    abort "n too large: {n}"\n}\n', {}, "E_ABORT n too large: 3"),
        ('step {\n out "out/z.txt"\n cmd write("ok\\n")\n}\n', {}, "E_NO_DEFAULT"),
    ],
)
def test_example_10_configuration_errors(build_error, main, files, error):
    assert build_error(main, files) == error


def test_example_11_clean(session):
    res = session({"main.kiln": HELLO}, "build\nclean\nbuild")
    assert res.lines()[3:7] == [
        "step 2: clean", "  remove .kiln-state", "  remove out/hello.txt", "  ok removed=2",
    ]
    assert res.lines()[-1] == "  ok ran=1 hit=0 time=1"


def test_example_12_failure_cancels_running_work(session):
    main = """
step {
    out "out/doc.txt"
    depfile "out/doc.d"
    in "src/main.txt"
    cmd preprocess()
}
step {
    out "out/slow.txt"
    cmd write("slow\\n")
    cost 10
}
step {
    out "out/after.txt"
    in "out/doc.txt"
    cmd copy()
}
phony all = ["out/doc.txt", "out/slow.txt", "out/after.txt"]
default "@all"
"""
    res = session({"main.kiln": main, "src/main.txt": "@need src/gone.txt\n"}, "build -j 2")
    check(res, """
        step 1: build (default) -j 2
          fail 0 6 w0 out/doc.txt preprocess()
          cancel 0 10 w1 out/slow.txt write("slow\\n")
          error E_NEED_MISSING src/gone.txt needed by src/main.txt
    """)
    assert res.file(".kiln-state") == "kiln-state 1\n"
    assert res.fs.read(b"out/slow.txt") is None


def test_example_13_after_is_order_only(session):
    main = (
        'step {\n out "out/gen.txt"\n in "src/a.txt"\n cmd copy()\n}\n'
        'step {\n out "out/rep.txt"\n after "out/gen.txt"\n cmd write("report\\n")\n}\n'
        'phony all = ["out/rep.txt"]\ndefault "@all"\n'
    )
    res = session({"main.kiln": main, "src/a.txt": "a\n"}, "build\nedit src/a.txt\nb\n---\nbuild")
    check(res, """
        step 1: build (default) -j 1
          run 0 1 w0 out/gen.txt copy()
          run 1 2 w0 out/rep.txt write("report\\n")
          ok ran=2 hit=0 time=2
        step 2: edit src/a.txt
          ok size=2
        step 3: build (default) -j 1
          run 0 1 w0 out/gen.txt copy()
          hit 1 out/rep.txt
          ok ran=1 hit=1 time=1
    """)


def test_example_14_cost_is_not_a_change_but_input_order_is(session):
    def main(inputs, cost=""):
        return f'step {{\n out "out/j.txt"\n in {inputs}\n cmd concat()\n{cost}}}\ndefault "out/j.txt"\n'

    a, b = '["src/a.txt", "src/b.txt"]', '["src/b.txt", "src/a.txt"]'
    script = f"build\nedit main.kiln\n{main(a, ' cost 5\n')}---\nbuild\nedit main.kiln\n{main(b, ' cost 5\n')}---\nbuild"
    res = session({"main.kiln": main(a), "src/a.txt": "a\n", "src/b.txt": "a\n"}, script)
    assert res.lines()[5:8] == ["step 3: build (default) -j 1", "  hit 0 out/j.txt", "  ok ran=0 hit=1 time=0"]
    assert res.lines()[-2:] == ["  run 0 5 w0 out/j.txt concat()", "  ok ran=1 hit=0 time=5"]


def test_example_15_tampered_and_deleted_outputs(session):
    res = session({"main.kiln": HELLO}, "build\nedit out/hello.txt\ntampered\n---\nbuild\ndelete out/hello.txt\nbuild")
    assert res.log.count("run 0 1 w0 out/hello.txt") == 3
    assert res.file("out/hello.txt") == "hello\n"


class TestEngine:
    def test_hit_cascade_happens_at_one_instant(self, session):
        main = (
            'step {\n out "out/a"\n cmd write("a")\n cost 5\n}\n'
            'step {\n out "out/b"\n in "out/a"\n cmd copy()\n}\n'
            'step {\n out "out/c"\n in "out/b"\n cmd copy()\n}\ndefault "out/c"\n'
        )
        res = session({"main.kiln": main}, "build\nedit out/a\nzzz\n---\nbuild")
        assert res.lines()[-4:] == [
            '  run 0 5 w0 out/a write("a")',
            "  hit 5 out/b",
            "  hit 5 out/c",
            "  ok ran=1 hit=2 time=5",
        ]

    def test_cost_zero_is_dispatched_and_logged(self, session):
        main = 'step {\n out "out/a"\n cmd write("a")\n cost 0\n}\ndefault "out/a"\n'
        res = session({"main.kiln": main}, "build")
        assert res.lines()[1] == '  run 0 0 w0 out/a write("a")'
        assert res.lines()[2] == "  ok ran=1 hit=0 time=0"

    def test_unreachable_steps_are_not_run_or_recorded(self, session):
        main = 'step {\n out "out/a"\n cmd write("a")\n}\nstep {\n out "out/b"\n cmd write("b")\n}\ndefault "out/a"\n'
        res = session({"main.kiln": main}, "build")
        assert res.fs.read(b"out/b") is None
        assert "step out/b" not in res.file(".kiln-state")

    def test_state_entries_of_unknown_steps_are_carried_over(self, session):
        state = "kiln-state 1\nstep out/old\ncmd write(\"x\")\nout out/old a9bc80cca21f28b3\nend\n"
        res = session({"main.kiln": HELLO, ".kiln-state": state}, "build")
        assert "step out/old" in res.file(".kiln-state")

    def test_corrupt_state_is_ignored(self, session):
        res = session({"main.kiln": HELLO, ".kiln-state": "junk\n"}, "build")
        assert "ran=1" in res.log

    def test_command_change_makes_step_stale(self, session):
        a = 'step {\n out "out/a"\n cmd write("a")\n}\ndefault "out/a"\n'
        b = a.replace('"a")', '"b")')
        res = session({"main.kiln": a}, f"build\nedit main.kiln\n{b}---\nbuild")
        assert res.lines()[-2] == '  run 0 1 w0 out/a write("b")'

    def test_no_build_file_error(self, session):
        res = session({}, "build")
        assert res.lines() == ["step 1: build (default) -j 1", "  error E_NO_BUILD_FILE main.kiln"]

    def test_unknown_target_even_when_default_is_fine(self, session):
        res = session({"main.kiln": HELLO}, "build nope -j 3")
        assert res.lines() == ["step 1: build nope -j 3", "  error E_UNKNOWN_TARGET nope"]

    def test_dash_j_as_target(self, session):
        res = session({"main.kiln": HELLO}, "build out/hello.txt -j")
        assert res.lines()[0] == "step 1: build out/hello.txt -j -j 1"
        assert res.lines()[1] == "  error E_UNKNOWN_TARGET -j"

    def test_failure_picks_lowest_serial_and_failed_events(self, session):
        main = (
            'step {\n out "out/p1"\n in "s1"\n depfile "out/p1.d"\n cmd preprocess()\n}\n'
            'step {\n out "out/p2"\n in "s2"\n depfile "out/p2.d"\n cmd preprocess()\n}\n'
            'default ["out/p1", "out/p2"]\n'
        )
        res = session({"main.kiln": main, "s1": "@need a/b\n", "s2": "@need bad path\n"}, "build -j 2")
        assert res.lines()[1:3] == [
            "  fail 0 6 w0 out/p1 preprocess()", "  fail 0 6 w1 out/p2 preprocess()",
        ]
        assert res.lines()[3] == "  error E_NEED_MISSING a/b needed by s1"

    def test_preprocess_errors(self, session):
        base = 'step {\n out "out/p"\n in "s"\n depfile "out/p.d"\n cmd preprocess()\n}\ndefault "out/p"\n'
        res = session({"main.kiln": base, "s": "@need s\n"}, "build")
        assert res.lines()[-1] == "  error E_NEED_CYCLE s"
        res = session({"main.kiln": base, "s": "@need x\n", "x": "@need s\n"}, "build")
        assert res.lines()[-1] == "  error E_NEED_CYCLE s"
        res = session({"main.kiln": base, "s": "a\n@need  x\n@need \n"}, "build")
        assert res.lines()[-1] == "  error E_NEED_PATH  x"

    def test_whole_graph_validation_covers_unreachable_steps(self, build_error):
        main = (
            'step {\n out "out/a"\n cmd write("a")\n}\n'
            'step {\n out "out/b"\n in "nope"\n cmd copy()\n}\n'
            'default "out/a"\n'
        )
        assert build_error(main) == "E_MISSING_INPUT nope required by out/b"

    def test_default_target_validated_even_with_explicit_targets(self, session):
        main = 'step {\n out "out/a"\n cmd write("a")\n}\ndefault "out/missing"\n'
        res = session({"main.kiln": main}, "build out/a")
        assert res.lines()[-1] == "  error E_UNKNOWN_TARGET out/missing"
