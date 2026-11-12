"""Build steps: construction and validation."""

from __future__ import annotations

from dataclasses import dataclass, field

from .commands import CommandSpec, render_command
from .errors import KilnError
from .paths import is_generated, is_reference, is_workspace_path


@dataclass(slots=True)
class Step:
    """One build step, as declared by a ``step`` block.

    ``serial`` is the creation order across the whole build and breaks every
    scheduling tie.
    """

    serial: int
    outputs: list[bytes]
    inputs: list[bytes]
    after: list[bytes]
    cost: int
    depfile: bytes | None
    spec: CommandSpec
    cmd_args: tuple
    #: Derived data filled in by :func:`finish_step`.
    primary: bytes = b""
    full_outputs: list[bytes] = field(default_factory=list)
    file_inputs: list[bytes] = field(default_factory=list)
    command: bytes = b""


def finish_step(
    serial: int,
    outputs: list[bytes],
    inputs: list[bytes],
    after: list[bytes],
    cost: int | None,
    depfile: bytes | None,
    spec: CommandSpec | None,
    cmd_args: tuple,
) -> Step:
    """Validate a completed ``step`` block and build the :class:`Step`.

    Raises ``E_STEP_FIELD``, ``E_BAD_PATH``, ``E_OUTPUT_PATH``, ``E_CMD_SHAPE``
    or ``E_ARG`` in the order the specification defines.
    """
    if spec is None:
        raise KilnError("E_STEP_FIELD", "missing cmd")
    if not outputs:
        raise KilnError("E_STEP_FIELD", "missing out")
    for path in outputs + ([depfile] if depfile is not None else []):
        if not is_workspace_path(path):
            raise KilnError("E_BAD_PATH", path)
        if not is_generated(path):
            raise KilnError("E_OUTPUT_PATH", path)
    for ref in inputs:
        if not is_reference(ref):
            raise KilnError("E_BAD_PATH", ref)
    for ref in after:
        if not is_reference(ref):
            raise KilnError("E_BAD_PATH", ref)
    file_inputs = [r for r in inputs if r[:1] != b"@"]
    m = len(file_inputs)
    if m < spec.min_inputs or (spec.max_inputs is not None and m > spec.max_inputs):
        raise KilnError(
            "E_CMD_SHAPE", f"{spec.name}: expected inputs {spec.input_range()}, got {m}"
        )
    if len(outputs) != 1:
        raise KilnError("E_CMD_SHAPE", f"{spec.name}: expected outputs 1, got {len(outputs)}")
    if spec.uses_depfile and depfile is None:
        raise KilnError("E_CMD_SHAPE", f"{spec.name}: depfile required")
    if not spec.uses_depfile and depfile is not None:
        raise KilnError("E_CMD_SHAPE", f"{spec.name}: depfile not allowed")
    spec.check_semantics(cmd_args)
    return Step(
        serial=serial,
        outputs=outputs,
        inputs=inputs,
        after=after,
        cost=spec.default_cost if cost is None else cost,
        depfile=depfile,
        spec=spec,
        cmd_args=cmd_args,
        primary=outputs[0],
        full_outputs=outputs + ([depfile] if depfile is not None else []),
        file_inputs=file_inputs,
        command=render_command(spec.name.encode(), cmd_args),
    )
