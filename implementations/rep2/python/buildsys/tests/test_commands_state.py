"""The sixteen commands, canonical command strings and the state file."""

import pytest

from kiln import KilnError, VirtualFS
from kiln.commands import COMMANDS, join_lines, render_command, split_lines
from kiln.state import StateEntry, is_fresh, parse_state, render_state

H = b"089bdc07b544e7b2"


def run(name: str, args=(), contents=(b"",), paths=None):
    paths = paths or [b"in%d" % i for i in range(len(contents))]
    return COMMANDS[name.encode()].run(list(args), paths, list(contents), lambda p: None).content


def test_there_are_sixteen_commands():
    assert len(COMMANDS) == 16


@pytest.mark.parametrize(
    "content,lines",
    [(b"", []), (b"a\nb\n", [b"a", b"b"]), (b"a\nb", [b"a", b"b"]), (b"a\n\nb\n", [b"a", b"", b"b"]), (b"\n", [b""]),
     (b"a\r\n", [b"a\r"])],
)
def test_line_splitting(content, lines):
    assert split_lines(content) == lines


def test_join_lines():
    assert join_lines([]) == b""
    assert join_lines([b"a", b""]) == b"a\n\n"


@pytest.mark.parametrize(
    "name,args,contents,expected",
    [
        ("write", [b"x\x00"], [], b"x\x00"),
        ("copy", [], [b"abc"], b"abc"),
        ("concat", [], [b"a", b"b", b"a"], b"aba"),
        ("upper", [], ["aé".encode()], "Aé".encode()),
        ("lower", [], [b"ABC"], b"abc"),
        ("grep", [b"a"], [b"ab\nc\nba"], b"ab\nba\n"),
        ("grep", [b""], [b"a\nb"], b"a\nb\n"),
        ("replace", [b"a", b"bb"], [b"aXa"], b"bbXbb"),
        ("sort_lines", [], [b"b\na\n\nB"], b"\nB\na\nb\n"),
        ("reverse_lines", [], [b"a\nb"], b"b\na\n"),
        ("dedup", [], [b"a\nb\na\nb\nc"], b"a\nb\nc\n"),
        ("number", [], [b"a\nb\nc"], b"1: a\n2: b\n3: c\n"),
        ("indent", [2], [b"a\n\nb"], b"  a\n  \n  b\n"),
        ("wrap", [b"<<", b">>"], [b"x\n"], b"<<x\n>>"),
        ("count_lines", [], [b"a\nb\n", b""], b"2 in0\n0 in1\n2 total\n"),
        ("hash", [], [b"hello\n", b"hello\n"], b"a9bc80cca21f28b3 in0\na9bc80cca21f28b3 in1\n"),
    ],
)
def test_command_output(name, args, contents, expected):
    assert run(name, args, contents) == expected


def test_preprocess_expansion_and_discovered_set():
    files = {b"b": b"B1\n@need c\nB2\n", b"c": b"C\n"}
    result = COMMANDS[b"preprocess"].run([], [b"a"], [b"x\n@need b\n@need c\ny\n"], files.get)
    assert result.content == b"x\nB1\nC\nB2\nC\ny\n"
    assert result.discovered == (b"b", b"c")
    assert result.depfile == b"kiln-deps 1\nneed b\nneed c\n"


def test_preprocess_only_exact_directives_expand():
    files = {b"b": b"B\n"}
    result = COMMANDS[b"preprocess"].run([], [b"a"], [b"@need\n@needb\n @need b\n@need b\n"], files.get)
    assert result.content == b"@need\n@needb\n @need b\nB\n"


@pytest.mark.parametrize(
    "content,kind,detail",
    [
        (b"@need /bad\n", "E_NEED_PATH", b"/bad"),
        (b"@need gone\n", "E_NEED_MISSING", b"gone needed by a"),
        (b"@need a\n", "E_NEED_CYCLE", b"a"),
    ],
)
def test_preprocess_errors(content, kind, detail):
    with pytest.raises(KilnError) as info:
        COMMANDS[b"preprocess"].run([], [b"a"], [content], {b"a": content}.get)
    assert (info.value.kind, info.value.detail) == (kind, detail)


@pytest.mark.parametrize(
    "name,args,text",
    [
        ("write", [b"hello\n"], 'write("hello\\n")'),
        ("replace", [b"a\\b", b"c"], 'replace("a\\\\b", "c")'),
        ("indent", [4], "indent(4)"),
        ("wrap", [b"<<", b">>"], 'wrap("<<", ">>")'),
        ("grep", ["ü".encode()], 'grep("ü")'),
        ("write", [b'q"\t\r\x01\x7f'], 'write("q\\"\\t\\r\\x01\\x7f")'),
        ("preprocess", [], "preprocess()"),
    ],
)
def test_canonical_command_string(name, args, text):
    assert render_command(name.encode(), args) == text.encode()


GOOD = b"kiln-state 1\nstep out/a\ncmd copy()\nin src/a " + H + b"\ndep src/d " + H + b"\nout out/a " + H + b"\nend\n"


class TestStateFile:
    def test_roundtrip(self):
        entries = parse_state(GOOD)
        assert list(entries) == [b"out/a"]
        e = entries[b"out/a"]
        assert (e.cmd, e.ins, e.deps, e.outs) == (
            b"copy()", [(b"src/a", H)], [(b"src/d", H)], [(b"out/a", H)]
        )
        assert render_state(entries) == GOOD

    def test_empty_state_renders_header_only(self):
        assert render_state({}) == b"kiln-state 1\n"

    def test_entries_are_sorted_on_write(self):
        mk = lambda k: StateEntry(k, b"write(\"\")", [], [], [(k, H)])
        text = render_state({b"out/b": mk(b"out/b"), b"out/a": mk(b"out/a")})
        assert text.index(b"step out/a") < text.index(b"step out/b")

    @pytest.mark.parametrize(
        "bad",
        [
            b"",
            b"kiln-state 2\n",
            GOOD[:-1],                                         # last line unterminated
            GOOD.replace(b"end\n", b""),                        # unterminated entry
            GOOD + b"junk\n",
            GOOD.replace(b"cmd copy()\n", b"cmd copy()\ncmd copy()\n"),
            GOOD.replace(b"cmd copy()\n", b""),
            GOOD.replace(b"cmd copy()", b"cmd "),
            GOOD.replace(b"out out/a " + H + b"\n", b""),       # no out line
            GOOD.replace(H + b"\nend", b"089BDC07B544E7B2\nend"),
            GOOD.replace(H + b"\nend", b"089bdc07b544e7\nend"),
            GOOD.replace(b"in src/a", b"in bad path"),
            GOOD.replace(b"step out/a", b"step out/b"),
            GOOD.replace(b"in src/a " + H + b"\ndep src/d " + H + b"\n", b"dep src/d " + H + b"\nin src/a " + H + b"\n"),
            GOOD.replace(b"in src/a", b"in  src/a"),
            GOOD + GOOD[len(b"kiln-state 1\n"):],                # duplicate key
        ],
    )
    def test_rejects(self, bad):
        assert parse_state(bad) == {}

    def test_dep_lines_need_not_be_sorted(self):
        data = GOOD.replace(b"dep src/d " + H + b"\n", b"dep src/z " + H + b"\ndep src/d " + H + b"\n")
        assert [p for p, _ in parse_state(data)[b"out/a"].deps] == [b"src/z", b"src/d"]


class TestFreshness:
    @staticmethod
    def step_and_fs():
        from kiln.evaluator import evaluate

        fs = VirtualFS({
            b"main.kiln": b'step {\n out "out/a"\n in "src/a"\n cmd copy()\n}\n',
            b"src/a": b"x\n",
            b"out/a": b"x\n",
        })
        return evaluate(fs).steps[0], fs

    def entry(self, step, fs, **over):
        e = StateEntry(
            step.primary, step.command, [(b"src/a", fs.hash(b"src/a"))], [], [(b"out/a", fs.hash(b"out/a"))]
        )
        for k, v in over.items():
            setattr(e, k, v)
        return e

    def test_fresh_and_each_staleness_rule(self):
        step, fs = self.step_and_fs()
        assert is_fresh(self.entry(step, fs), step, fs)
        assert not is_fresh(None, step, fs)
        assert not is_fresh(self.entry(step, fs, cmd=b"copy(1)"), step, fs)
        assert not is_fresh(self.entry(step, fs, outs=[(b"out/b", H)]), step, fs)
        assert not is_fresh(self.entry(step, fs, ins=[]), step, fs)
        assert not is_fresh(self.entry(step, fs, deps=[(b"src/gone", H)]), step, fs)
        e = self.entry(step, fs)
        fs.write(b"out/a", b"edited\n")
        assert not is_fresh(e, step, fs)
        fs.delete(b"out/a")
        assert not is_fresh(e, step, fs)
