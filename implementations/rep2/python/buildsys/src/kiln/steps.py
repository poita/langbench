"""Build steps: field accumulation and validation.

The evaluator evaluates a ``step`` block's expressions and feeds the values to
a :class:`StepBuilder`, which applies the specification's checks and, at the
closing brace, :meth:`StepBuilder.finish` validates the step and produces an
immutable :class:`Step`.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from .commands import COMMANDS, CommandSpec, render_command
from .errors import KilnError, type_error
from .paths import is_generated, is_phony_ref, is_workspace_path
from .values import type_name

__all__ = ["Step", "StepBuilder", "check_reference_shape"]


def check_reference_shape(ref: bytes) -> None:
    """Raise ``E_BAD_PATH`` unless ``ref`` is ``@name`` or a workspace path."""
    if ref.startswith(b"@"):
        if not is_phony_ref(ref):
            raise KilnError("E_BAD_PATH", ref)
    elif not is_workspace_path(ref):
        raise KilnError("E_BAD_PATH", ref)


@dataclass(frozen=True, slots=True)
class Step:
    """A validated build step."""

    serial: int
    outs: tuple[bytes, ...]             # declared outputs
    depfile: bytes | None
    ins: tuple[bytes, ...]              # declared inputs (files and ``@phony`` refs)
    afters: tuple[bytes, ...]
    spec: CommandSpec
    args: tuple                         # evaluated command arguments
    cost: int
    command: bytes                      # canonical command string
    file_inputs: tuple[bytes, ...] = field(default=())
    outputs: tuple[bytes, ...] = field(default=())  # declared outputs + depfile

    @property
    def primary(self) -> bytes:
        """The primary output path (also the step's name in messages)."""
        return self.outs[0]


class StepBuilder:
    """Accumulates the fields of one ``step`` block."""

    def __init__(self) -> None:
        self.outs: list[bytes] = []
        self.ins: list[bytes] = []
        self.afters: list[bytes] = []
        self.cost: int | None = None
        self.depfile: bytes | None = None
        self.cmd: tuple[CommandSpec, tuple] | None = None

    # -- fields --

    def add_list(self, kind: bytes, value: object) -> None:
        """Handle ``out`` / ``in`` / ``after``: ``value`` is a str or list of str."""
        site = b"field " + kind
        if type(value) is bytes:
            items = [value]
        elif type(value) is list:
            for e in value:
                if type(e) is not bytes:
                    raise type_error(site, "strlist", type_name(e))
            items = value
        else:
            raise type_error(site, "strlist", type_name(value))
        {b"out": self.outs, b"in": self.ins, b"after": self.afters}[kind].extend(items)

    def check_duplicate(self, kind: bytes) -> None:
        """Duplicate checks that precede evaluating the field's expression."""
        dup = {b"cost": self.cost is not None, b"depfile": self.depfile is not None,
               b"cmd": self.cmd is not None}
        if dup[kind]:
            raise KilnError("E_STEP_FIELD", b"duplicate " + kind)

    def set_cost(self, value: object) -> None:
        if type(value) is not int:
            raise type_error("field cost", "int", type_name(value))
        if value < 0:
            raise KilnError("E_ARG", "field cost: negative")
        self.cost = value

    def set_depfile(self, value: object) -> None:
        if type(value) is not bytes:
            raise type_error("field depfile", "str", type_name(value))
        self.depfile = value

    @staticmethod
    def lookup_command(name: bytes) -> CommandSpec:
        spec = COMMANDS.get(name)
        if spec is None:
            raise KilnError("E_UNKNOWN_CMD", name)
        return spec

    def set_command(self, spec: CommandSpec, args: list) -> None:
        """Check the arguments' count and types, then record the command."""
        if len(args) != len(spec.arg_types):
            raise KilnError(
                "E_ARITY", b"cmd %b: expected %d, got %d" % (spec.name, len(spec.arg_types), len(args))
            )
        for i, (want, value) in enumerate(zip(spec.arg_types, args), 1):
            if type_name(value) != want:
                raise type_error(b"cmd %b argument %d" % (spec.name, i), want, type_name(value))
        self.cmd = (spec, tuple(args))

    # -- closing brace --

    def finish(self, serial: int) -> Step:
        """Validate the step (specification order) and build it."""
        if self.cmd is None:
            raise KilnError("E_STEP_FIELD", "missing cmd")
        if not self.outs:
            raise KilnError("E_STEP_FIELD", "missing out")
        paths = self.outs + ([self.depfile] if self.depfile is not None else [])
        for p in paths:
            if not is_workspace_path(p):
                raise KilnError("E_BAD_PATH", p)
            if not is_generated(p):
                raise KilnError("E_OUTPUT_PATH", p)
        for ref in self.ins:
            check_reference_shape(ref)
        for ref in self.afters:
            check_reference_shape(ref)
        spec, args = self.cmd
        file_inputs = tuple(r for r in self.ins if not r.startswith(b"@"))
        n = len(file_inputs)
        if n < spec.min_inputs or (spec.max_inputs is not None and n > spec.max_inputs):
            raise KilnError("E_CMD_SHAPE", b"%b: expected inputs %b, got %d" % (spec.name, spec.input_range, n))
        if len(self.outs) != 1:
            raise KilnError("E_CMD_SHAPE", b"%b: expected outputs 1, got %d" % (spec.name, len(self.outs)))
        if spec.uses_depfile and self.depfile is None:
            raise KilnError("E_CMD_SHAPE", b"%b: depfile required" % spec.name)
        if not spec.uses_depfile and self.depfile is not None:
            raise KilnError("E_CMD_SHAPE", b"%b: depfile not allowed" % spec.name)
        if spec.name == b"replace" and args[0] == b"":
            raise KilnError("E_ARG", "cmd replace: empty pattern")
        if spec.name == b"indent" and args[0] < 0:
            raise KilnError("E_ARG", "cmd indent: negative")
        return Step(
            serial=serial,
            outs=tuple(self.outs),
            depfile=self.depfile,
            ins=tuple(self.ins),
            afters=tuple(self.afters),
            spec=spec,
            args=args,
            cost=spec.default_cost if self.cost is None else self.cost,
            command=render_command(spec.name, args),
            file_inputs=file_inputs,
            outputs=tuple(paths),
        )
