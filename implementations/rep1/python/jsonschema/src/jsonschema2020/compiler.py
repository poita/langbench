"""Compilation of raw schema documents into :class:`~jsonschema2020.nodes.Node`
trees, plus indexing of ``$id`` / ``$anchor`` / ``$dynamicAnchor``."""

from __future__ import annotations

from typing import Any, Dict, Optional

from . import uri
from .errors import SchemaError
from .keywords import KEYWORDS
from .nodes import FALSE_NODE, TRUE_NODE, Node, Registry
from .regex import Pattern, RegexError, compile_pattern

__all__ = ["Compiler"]


class Compiler:
    """Walks schema documents once, building the registry and the node tree."""

    def __init__(self, registry: Optional[Registry] = None) -> None:
        self.registry = registry if registry is not None else Registry()
        self.registry.compile_late = self.subschema

    def pattern(self, source: str) -> Pattern:
        try:
            return compile_pattern(source)
        except RegexError as exc:
            raise SchemaError(f"invalid regular expression: {exc}") from None

    def add_document(self, document: Any, retrieval_uri: str) -> Node:
        """Compile *document* whose retrieval URI is *retrieval_uri* and
        register it under that URI unless the URI is already taken."""
        root = self.subschema(document, retrieval_uri)
        self.registry.resources.setdefault(retrieval_uri, root)
        return root

    def subschema(self, raw: Any, base: str, lenient: bool = False) -> Node:
        """Compile the schema *raw* found where the base URI is *base*."""
        if raw is True:
            return TRUE_NODE
        if raw is False:
            return FALSE_NODE
        if type(raw) is not dict:
            if lenient:
                return TRUE_NODE
            raise SchemaError(f"a schema must be an object or a boolean, got {raw!r}")
        registry = self.registry
        existing = registry.nodes.get(id(raw))
        if existing is not None:
            return existing
        schema_id = raw.get("$id")
        if type(schema_id) is str:
            base = uri.resolve(base, uri.split_fragment(schema_id)[0])
        node = Node(base, raw)
        registry.nodes[id(raw)] = node
        if type(schema_id) is str:
            registry.resources.setdefault(base, node)
        anchor = raw.get("$anchor")
        if type(anchor) is str:
            registry.anchors.setdefault((base, anchor), node)
        dynamic = raw.get("$dynamicAnchor")
        if type(dynamic) is str:
            registry.dynamic_anchors.setdefault((base, dynamic), node)
        for keyword, value in raw.items():
            handler = KEYWORDS.get(keyword)
            if handler is not None:
                handler(self, node, raw, value)
        node.freeze()
        return node
