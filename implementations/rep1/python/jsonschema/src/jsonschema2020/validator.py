"""The public validator API."""

from __future__ import annotations

from typing import Any, Dict, Iterable, List, Mapping, Optional

from .compiler import Compiler
from .errors import SchemaError
from .jsonvalue import normalize
from .nodes import Node, Registry

__all__ = ["Validator", "validate", "check_document"]


class Validator:
    """A compiled JSON Schema (draft 2020-12) ready to check instances.

    Parameters
    ----------
    schema:
        The root schema: a ``dict`` or a ``bool``.
    remotes:
        Optional mapping of absolute URI -> schema document.  References to
        those URIs (and to anything inside them) resolve to these documents;
        nothing is ever fetched from the network.
    normalized:
        Set to ``True`` when *schema* and *remotes* already use the library's
        data model (see :mod:`jsonschema2020.jsonvalue`), e.g. because they
        came from :func:`jsonschema2020.loads`.  Otherwise they are converted
        first (floats become exact decimals, tuples become lists, ...).

    The schema is compiled once, here; :meth:`is_valid` can then be called any
    number of times.
    """

    def __init__(
        self,
        schema: Any,
        remotes: Optional[Mapping[str, Any]] = None,
        *,
        normalized: bool = False,
    ) -> None:
        if not normalized:
            schema = normalize(schema)
            remotes = {k: normalize(v) for k, v in remotes.items()} if remotes else None
        self._registry = Registry()
        compiler = Compiler(self._registry)
        self._root: Node = compiler.add_document(schema, "")
        for retrieval_uri, document in (remotes or {}).items():
            compiler.add_document(document, retrieval_uri)

    def is_valid(self, instance: Any, *, normalized: bool = False) -> bool:
        """True when *instance* satisfies the schema.

        *instance* may be any Python structure made of ``None``, ``bool``,
        ``int``, ``float``, ``Fraction``, ``str``, ``list``/``tuple`` and
        ``dict`` with string keys.  Pass ``normalized=True`` to skip the
        conversion when it comes from :func:`jsonschema2020.loads`.

        Raises :class:`~jsonschema2020.RefResolutionError` if evaluation needs
        a reference that cannot be resolved.
        """
        if not normalized:
            instance = normalize(instance)
        return self._root.evaluate(instance, (), None)


def validate(
    schema: Any,
    instance: Any,
    remotes: Optional[Mapping[str, Any]] = None,
) -> bool:
    """One-shot convenience: ``Validator(schema, remotes).is_valid(instance)``."""
    return Validator(schema, remotes).is_valid(instance)


def check_document(document: Any) -> List[bool]:
    """Evaluate a problem-format document (``schema``, ``tests``, optional
    ``remotes``; see the README) and return one boolean per test.

    The document must already use the library's data model, i.e. come from
    :func:`jsonschema2020.loads`.
    """
    if type(document) is not dict or "schema" not in document or "tests" not in document:
        raise SchemaError("input must be an object with 'schema' and 'tests' members")
    remotes = document.get("remotes")
    if remotes is not None and type(remotes) is not dict:
        raise SchemaError("'remotes' must be an object")
    validator = Validator(document["schema"], remotes, normalized=True)
    results = []
    for test in document["tests"]:
        if type(test) is not dict or "data" not in test:
            raise SchemaError("each test must be an object with a 'data' member")
        results.append(validator.is_valid(test["data"], normalized=True))
    return results
