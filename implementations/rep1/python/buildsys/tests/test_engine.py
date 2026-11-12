"""Graph, scheduler, change detection and state file behaviour."""

import pytest

from kiln.commands import render_command, split_lines
from kiln.state import parse_state, render_state

CHAIN = """
step {
    out "out/a.txt"
    cmd write("A\\n")
}
step {
    out "out/b.txt"
    cmd write("B\\n")
}
step {
    out "out/all.txt"
    in ["out/a.txt", "out/b.txt"]
    cmd concat()
}
phony all = "out/all.txt"
default "@all"
"""


def test_parallel_build_then_hits(session):
    log, fs = session({"main.kiln": CHAIN}, "build -j 2\ntouch main.kiln\nbuild -j 2\n")
    assert log == (
        "step 1: build (default) -j 2\n"
        '  run 0 1 w0 out/a.txt write("A\\n")\n'
        '  run 0 1 w1 out/b.txt write("B\\n")\n'
        "  run 1 3 w0 out/all.txt concat()\n"
        "  ok ran=3 hit=0 time=3\n"
        "step 2: touch main.kiln\n"
        "  ok\n"
        "step 3: build (default) -j 2\n"
        "  hit 0 out/a.txt\n"
        "  hit 0 out/b.txt\n"
        "  hit 0 out/all.txt\n"
        "  ok ran=0 hit=3 time=0\n"
    )
    assert fs.read(b"out/all.txt") == b"A\nB\n"
    assert fs.read(b".kiln-state").startswith(b"kiln-state 1\nstep out/a.txt\n")


def test_serial_one_worker(session):
    log, _ = session({"main.kiln": CHAIN}, "build\n")
    assert "run 0 1 w0 out/a.txt" in log and "run 1 2 w0 out/b.txt" in log
    assert log.endswith("  ok ran=3 hit=0 time=4\n")


def test_clean_removes_outputs_and_state(session):
    log, fs = session({"main.kiln": CHAIN}, "build\nclean\nbuild\n")
    assert "  remove .kiln-state\n  remove out/a.txt\n" in log
    assert "ok removed=4" in log
    assert log.count("  run ") == 6
    assert fs.read(b"out/a.txt") == b"A\n"


def test_early_cutoff_and_tamper(session):
    main = """
step {
    out "out/n.txt"
    in "src.txt"
    cmd upper()
}
step {
    out "out/m.txt"
    in "out/n.txt"
    cmd copy()
}
default "out/m.txt"
"""
    log, _ = session(
        {"main.kiln": main, "src.txt": "abc\n"},
        "build\nedit src.txt\nABC\n---\nbuild\nedit out/m.txt\nx\n---\nbuild\n",
    )
    parts = log.split("step ")  # parts[n] is session step n
    assert "run 0 2 w0 out/n.txt upper()" in parts[3]
    assert "hit 2 out/m.txt" in parts[3]  # early cutoff: identical output
    assert "run 0 1 w0 out/m.txt copy()" in parts[5]
    assert "hit 0 out/n.txt" in parts[5]


def test_cost_change_is_not_a_change_but_inputs_are(session):
    one = 'step {\n out "out/x"\n in "a"\n cost 9\n cmd copy()\n}\ndefault "out/x"\n'
    two = 'step {\n out "out/x"\n in ["a", "a"]\n cmd concat()\n}\ndefault "out/x"\n'
    log, _ = session(
        {"main.kiln": one, "a": "1\n"},
        "build\nedit main.kiln\n" + one.replace("cost 9", "cost 1") + "---\nbuild\n"
        "edit main.kiln\n" + two + "---\nbuild\n",
    )
    assert "hit 0 out/x" in log
    assert log.count("  run ") == 2


def test_failure_cancels_running_steps(session):
    main = """
step {
    out "out/p"
    in "a"
    depfile "out/p.d"
    cmd preprocess()
}
step {
    out "out/slow"
    cost 10
    cmd write("s")
}
default ["out/p", "out/slow"]
"""
    log, fs = session(
        {"main.kiln": main, "a": "@need missing\n"}, "build -j 2\n"
    )
    assert log == (
        "step 1: build (default) -j 2\n"
        "  fail 0 6 w0 out/p preprocess()\n"
        '  cancel 0 10 w1 out/slow write("s")\n'
        "  error E_NEED_MISSING missing needed by a\n"
    )
    assert b"out/p" not in fs.read(b".kiln-state")
    assert b"out/slow" not in fs.read(b".kiln-state")


def test_cycle_and_missing_input(session):
    log, fs = session(
        {"main.kiln": 'step {\n out "out/a"\n in "out/a"\n cmd copy()\n}\ndefault "out/a"\n'},
        "build\n",
    )
    assert log.endswith("  error E_CYCLE out/a -> out/a\n")
    assert b".kiln-state" not in set(fs.paths())
    log, _ = session(
        {"main.kiln": 'step {\n out "out/a"\n in "nope"\n cmd copy()\n}\n'}, "build out/a\n"
    )
    assert log.endswith("  error E_MISSING_INPUT nope required by out/a\n")


def test_configuration_errors_leave_workspace_untouched(session):
    _, fs = session({"main.kiln": "abort 'x'\n"}, "build\n")
    assert b".kiln-state" not in set(fs.paths())


def test_no_build_file_and_no_default(session):
    log, _ = session({}, "build\ncreate main.kiln\n---\nbuild\nbuild @x\n")
    assert "  error E_NO_BUILD_FILE main.kiln\n" in log
    assert "  error E_NO_DEFAULT\n" in log
    assert "  error E_UNKNOWN_TARGET @x\n" in log


def test_corrupt_state_means_rebuild(session):
    files = {"main.kiln": CHAIN, ".kiln-state": "kiln-state 1\nstep out/a.txt\n"}
    log, _ = session(files, "build\n")
    assert "ran=3 hit=0" in log


def test_includes_run_in_the_including_scope(session):
    files = {
        "main.kiln": 'let d = "out"\ninclude "lib.kiln"\ndefault f\n',
        "lib.kiln": 'let f = "{d}/x"\nstep {\n out f\n cmd write(d)\n}\n',
    }
    log, fs = session(files, "build\n")
    assert fs.read(b"out/x") == b"out"


def test_parse_error_in_include_names_the_included_file(session):
    files = {"main.kiln": 'include "lib.kiln"\n', "lib.kiln": "let a = 1\nlet\n"}
    log, _ = session(files, "build\n")
    assert log.endswith("  error E_PARSE lib.kiln:2\n")


@pytest.mark.parametrize(
    "cmd,content,expected",
    [
        ('grep("b")', "ab\nc\nbb", "ab\nbb\n"),
        ("sort_lines()", "b\na\nb\n", "a\nb\nb\n"),
        ("reverse_lines()", "a\nb", "b\na\n"),
        ("dedup()", "a\nb\na\n", "a\nb\n"),
        ("number()", "x\ny\n", "1: x\n2: y\n"),
        ("indent(2)", "x\n\n", "  x\n  \n"),
        ('wrap("<", ">")', "x", "<x>"),
        ('replace("aa", "b")', "aaaa a", "bb a"),
        ("count_lines()", "x\ny\n", "2 in.txt\n2 total\n"),
        ("hash()", "hello\n", "a9bc80cca21f28b3 in.txt\n"),
        ("upper()", "aé\n", "Aé\n"),
    ],
)
def test_commands(session, cmd, content, expected):
    main = f'step {{\n out "out/o"\n in "in.txt"\n cmd {cmd}\n}}\ndefault "out/o"\n'
    _, fs = session({"main.kiln": main, "in.txt": content}, "build\n")
    assert fs.read(b"out/o").decode() == expected


def test_command_shape_errors(session):
    log, _ = session(
        {"main.kiln": 'step {\n out "out/o"\n cmd copy()\n}\n'}, "build\n"
    )
    assert log.endswith("  error E_CMD_SHAPE copy: expected inputs 1-1, got 0\n")


def test_preprocess_depfile_cycle(session):
    main = (
        'step {\n out "out/o"\n in "a"\n depfile "out/o.d"\n cmd preprocess()\n}\n'
        'default "out/o"\n'
    )
    log, fs = session(
        {"main.kiln": main, "a": "1\n@need b\n", "b": "2\n"},
        "build\nedit b\n@need b\n---\nbuild\nedit b\nz\n---\nbuild\nbuild\n",
    )
    assert log.count("E_NEED_CYCLE b") == 1
    assert fs.read(b"out/o") == b"1\nz\n"
    assert fs.read(b"out/o.d") == b"kiln-deps 1\nneed b\n"
    assert log.endswith("  hit 0 out/o\n  ok ran=0 hit=1 time=0\n")


def test_render_command_escapes():
    assert render_command(b"write", ("a\\b\"\n\t\x01\x7fü".encode(),)) == (
        b'write("a\\\\b\\"\\n\\t\\x01\\x7f\xc3\xbc")'
    )
    assert render_command(b"indent", (-4,)) == b"indent(-4)"
    assert render_command(b"concat", ()) == b"concat()"


def test_split_lines():
    assert split_lines(b"") == []
    assert split_lines(b"\n") == [b""]
    assert split_lines(b"a\n\nb") == [b"a", b"", b"b"]


def test_state_round_trip_and_rejection():
    text = (
        b"kiln-state 1\nstep out/a\ncmd write(\"x\")\nin s 0123456789abcdef\n"
        b"dep d 0123456789abcdef\nout out/a 0123456789abcdef\nend\n"
    )
    state = parse_state(text)
    assert render_state(state) == text
    for bad in (
        text[:-1],  # unterminated last line
        text.replace(b"step out/a", b"step out/b"),
        text.replace(b"cmd write", b"cmd"),
        text.replace(b"0123456789abcdef", b"0123456789ABCDEF"),
        text + text[len(b"kiln-state 1\n"):],  # duplicate key
        b"kiln-state 2\n",
        text.replace(b"in s", b"in  s"),
    ):
        assert parse_state(bad) == {}
