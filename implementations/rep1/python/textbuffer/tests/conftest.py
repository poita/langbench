import pytest

from textbuffer import Interpreter, TextBuffer, parse_input
import io


def run_program(text: str) -> str:
    """Run a full SPEC-style program (document + commands) and return stdout."""
    lines, commands = parse_input(text)
    out = io.StringIO()
    Interpreter(TextBuffer.from_lines(lines), out).run_all(commands)
    return out.getvalue()


@pytest.fixture
def run():
    return run_program
