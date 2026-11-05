"""The single-diagnostic and panic exceptions."""


class CompileError(Exception):
    """A rejected program: one kind plus a 1-based position."""

    def __init__(self, kind, line, col):
        Exception.__init__(self, kind)
        self.kind = kind
        self.line = line
        self.col = col

    def text(self):
        return "error: %s at %d:%d" % (self.kind, self.line, self.col)


class Panic(Exception):
    """A runtime error; the message is printed after `panic: `."""

    def __init__(self, msg):
        Exception.__init__(self, msg)
        self.msg = msg
