"""Keyword compilers.

Each handler turns one keyword of a schema object into zero or more *checks*
(``check(instance, scope, ann) -> bool``) registered on the :class:`Node`
being built.  Handlers run once per schema object, so everything that can be
decided up front (decoded values, compiled patterns, sibling keywords such as
``prefixItems`` for ``items``) is decided here, never per instance.

``ann`` is ``None`` when nobody needs annotations; otherwise it is an
:class:`~jsonschema2020.nodes.Ann` to which applicator keywords add the items
and properties they evaluated.
"""

from __future__ import annotations

from fractions import Fraction
from typing import Any, Callable, Dict, List, Optional, Tuple

from . import uri
from .errors import RefResolutionError, SchemaError
from .jsonvalue import freeze, is_number
from .nodes import FALSE_NODE, Ann, Node, TRUE_NODE
from .regex import RegexError, compile_pattern

NUMBER = (int, Fraction)
STRING = (str,)
ARRAY = (list,)
OBJECT = (dict,)

Handler = Callable[["Any", Node, dict, Any], None]


def _is_list_of_schemas(value: Any) -> bool:
    return type(value) is list


# ---------------------------------------------------------------------------
# Any type
# ---------------------------------------------------------------------------

_SIMPLE_TYPES = {
    "null": (type(None),),
    "boolean": (bool,),
    "object": (dict,),
    "array": (list,),
    "string": (str,),
    "number": (int, Fraction),
    "integer": (int,),
}


def kw_type(ctx, node, schema, value) -> None:
    names = [value] if type(value) is str else value
    if type(names) is not list:
        return
    types = set()
    for name in names:
        if type(name) is str and name in _SIMPLE_TYPES:
            types.update(_SIMPLE_TYPES[name])
    wants_integer = "integer" in names
    wants_number = "number" in names

    if wants_integer and not wants_number:
        types.discard(Fraction)

        def check(inst, scope, ann):
            t = type(inst)
            return t in types or (t is Fraction and inst.denominator == 1)

    else:

        def check(inst, scope, ann):
            return type(inst) in types

    node.add(None, check)


def kw_enum(ctx, node, schema, value) -> None:
    if type(value) is not list:
        return
    keys = {freeze(item) for item in value}

    def check(inst, scope, ann):
        return freeze(inst) in keys

    node.add(None, check)


def kw_const(ctx, node, schema, value) -> None:
    key = freeze(value)

    def check(inst, scope, ann):
        return freeze(inst) == key

    node.add(None, check)


# ---------------------------------------------------------------------------
# Numbers
# ---------------------------------------------------------------------------


def kw_multiple_of(ctx, node, schema, value) -> None:
    if not is_number(value) or value <= 0:
        return
    if type(value) is int:

        def check(inst, scope, ann):
            if type(inst) is int:
                return inst % value == 0
            return (inst / value).denominator == 1

    else:

        def check(inst, scope, ann):
            return (inst / value).denominator == 1

    node.add(NUMBER, check)


def _bound(op):
    def handler(ctx, node, schema, value) -> None:
        if not is_number(value):
            return

        def check(inst, scope, ann):
            return op(inst, value)

        node.add(NUMBER, check)

    return handler


kw_maximum = _bound(lambda a, b: a <= b)
kw_minimum = _bound(lambda a, b: a >= b)
kw_exclusive_maximum = _bound(lambda a, b: a < b)
kw_exclusive_minimum = _bound(lambda a, b: a > b)


# ---------------------------------------------------------------------------
# Size keywords (strings, arrays, objects)
# ---------------------------------------------------------------------------


def _size(types, maximum: bool):
    def handler(ctx, node, schema, value) -> None:
        if not is_number(value):
            return
        if maximum:

            def check(inst, scope, ann):
                return len(inst) <= value

        else:

            def check(inst, scope, ann):
                return len(inst) >= value

        node.add(types, check)

    return handler


kw_max_length = _size(STRING, True)
kw_min_length = _size(STRING, False)
kw_max_items = _size(ARRAY, True)
kw_min_items = _size(ARRAY, False)
kw_max_properties = _size(OBJECT, True)
kw_min_properties = _size(OBJECT, False)


def kw_pattern(ctx, node, schema, value) -> None:
    if type(value) is not str:
        return
    pattern = ctx.pattern(value)

    def check(inst, scope, ann):
        return pattern.search(inst)

    node.add(STRING, check)


# ---------------------------------------------------------------------------
# Arrays
# ---------------------------------------------------------------------------


def kw_unique_items(ctx, node, schema, value) -> None:
    if value is not True:
        return

    def check(inst, scope, ann):
        if len(inst) < 2:
            return True
        return len({freeze(item) for item in inst}) == len(inst)

    node.add(ARRAY, check)


def kw_prefix_items(ctx, node, schema, value) -> None:
    if type(value) is not list:
        return
    subs = [ctx.subschema(v, node.base) for v in value]

    def check(inst, scope, ann):
        count = min(len(subs), len(inst))
        for i in range(count):
            if not subs[i].evaluate(inst[i], scope, None):
                return False
        if ann is not None and count:
            ann.items.update(range(count))
        return True

    node.add(ARRAY, check)


def kw_items(ctx, node, schema, value) -> None:
    sub = ctx.subschema(value, node.base)
    prefix = schema.get("prefixItems")
    start = len(prefix) if type(prefix) is list else 0
    trivially_true = sub.const is True

    def check(inst, scope, ann):
        n = len(inst)
        if start >= n:
            return True
        if not trivially_true:
            evaluate = sub.evaluate
            for i in range(start, n):
                if not evaluate(inst[i], scope, None):
                    return False
        if ann is not None:
            ann.items.update(range(start, n))
        return True

    node.add(ARRAY, check)


def kw_contains(ctx, node, schema, value) -> None:
    sub = ctx.subschema(value, node.base)
    minimum = schema.get("minContains", 1)
    if not is_number(minimum):
        minimum = 1
    maximum = schema.get("maxContains")
    if not is_number(maximum):
        maximum = None

    def check(inst, scope, ann):
        count = 0
        matched = [] if ann is not None else None
        evaluate = sub.evaluate
        for i, item in enumerate(inst):
            if evaluate(item, scope, None):
                count += 1
                if matched is not None:
                    matched.append(i)
                elif maximum is None and count >= minimum:
                    return True
                elif maximum is not None and count > maximum:
                    return False
        if ann is not None and matched:
            ann.items.update(matched)
        if count < minimum:
            return False
        return maximum is None or count <= maximum

    node.add(ARRAY, check)


def kw_unevaluated_items(ctx, node, schema, value) -> None:
    sub = ctx.subschema(value, node.base)

    def check(inst, scope, ann):
        done = ann.items
        evaluate = sub.evaluate
        for i in range(len(inst)):
            if i not in done:
                if not evaluate(inst[i], scope, None):
                    return False
                done.add(i)
        return True

    node.add_unevaluated(list, check)


# ---------------------------------------------------------------------------
# Objects
# ---------------------------------------------------------------------------


def kw_required(ctx, node, schema, value) -> None:
    if type(value) is not list:
        return
    names = [n for n in value if type(n) is str]

    def check(inst, scope, ann):
        for name in names:
            if name not in inst:
                return False
        return True

    node.add(OBJECT, check)


def kw_dependent_required(ctx, node, schema, value) -> None:
    if type(value) is not dict:
        return
    deps = [(k, [n for n in v if type(n) is str]) for k, v in value.items() if type(v) is list]

    def check(inst, scope, ann):
        for name, required in deps:
            if name in inst:
                for other in required:
                    if other not in inst:
                        return False
        return True

    node.add(OBJECT, check)


def kw_properties(ctx, node, schema, value) -> None:
    if type(value) is not dict:
        return
    subs = {name: ctx.subschema(v, node.base) for name, v in value.items()}

    def check(inst, scope, ann):
        if len(subs) <= len(inst):
            for name, sub in subs.items():
                if name in inst:
                    if not sub.evaluate(inst[name], scope, None):
                        return False
                    if ann is not None:
                        ann.props.add(name)
        else:
            for name, member in inst.items():
                sub = subs.get(name)
                if sub is not None:
                    if not sub.evaluate(member, scope, None):
                        return False
                    if ann is not None:
                        ann.props.add(name)
        return True

    node.add(OBJECT, check)


def kw_pattern_properties(ctx, node, schema, value) -> None:
    if type(value) is not dict:
        return
    entries = [(ctx.pattern(k), ctx.subschema(v, node.base)) for k, v in value.items()]

    def check(inst, scope, ann):
        for name, member in inst.items():
            for pattern, sub in entries:
                if pattern.search_cached(name):
                    if not sub.evaluate(member, scope, None):
                        return False
                    if ann is not None:
                        ann.props.add(name)
        return True

    node.add(OBJECT, check)


def kw_additional_properties(ctx, node, schema, value) -> None:
    sub = ctx.subschema(value, node.base)
    props = schema.get("properties")
    known = props if type(props) is dict else {}
    pprops = schema.get("patternProperties")
    patterns = [ctx.pattern(k) for k in pprops] if type(pprops) is dict else []

    def check(inst, scope, ann):
        evaluate = sub.evaluate
        for name, member in inst.items():
            if name in known:
                continue
            for pattern in patterns:
                if pattern.search_cached(name):
                    break
            else:
                if not evaluate(member, scope, None):
                    return False
                if ann is not None:
                    ann.props.add(name)
        return True

    node.add(OBJECT, check)


def kw_property_names(ctx, node, schema, value) -> None:
    sub = ctx.subschema(value, node.base)
    if sub.const is True:
        return

    def check(inst, scope, ann):
        for name in inst:
            if not sub.evaluate(name, scope, None):
                return False
        return True

    node.add(OBJECT, check)


def kw_dependent_schemas(ctx, node, schema, value) -> None:
    if type(value) is not dict:
        return
    deps = [(name, ctx.subschema(v, node.base)) for name, v in value.items()]

    def check(inst, scope, ann):
        for name, sub in deps:
            if name in inst and not sub.evaluate(inst, scope, ann):
                return False
        return True

    node.add(OBJECT, check)


def kw_unevaluated_properties(ctx, node, schema, value) -> None:
    sub = ctx.subschema(value, node.base)

    def check(inst, scope, ann):
        done = ann.props
        evaluate = sub.evaluate
        for name, member in inst.items():
            if name not in done:
                if not evaluate(member, scope, None):
                    return False
                done.add(name)
        return True

    node.add_unevaluated(dict, check)


# ---------------------------------------------------------------------------
# In-place applicators
# ---------------------------------------------------------------------------


def kw_all_of(ctx, node, schema, value) -> None:
    if type(value) is not list:
        return
    subs = [ctx.subschema(v, node.base) for v in value]

    def check(inst, scope, ann):
        for sub in subs:
            if not sub.evaluate(inst, scope, ann):
                return False
        return True

    node.add(None, check)


def kw_any_of(ctx, node, schema, value) -> None:
    if type(value) is not list:
        return
    subs = [ctx.subschema(v, node.base) for v in value]

    def check(inst, scope, ann):
        if ann is None:
            for sub in subs:
                if sub.evaluate(inst, scope, None):
                    return True
            return False
        accepted = False
        for sub in subs:
            branch = Ann()
            if sub.evaluate(inst, scope, branch):
                accepted = True
                ann.merge(branch)
        return accepted

    node.add(None, check)


def kw_one_of(ctx, node, schema, value) -> None:
    if type(value) is not list:
        return
    subs = [ctx.subschema(v, node.base) for v in value]

    def check(inst, scope, ann):
        found = 0
        winner: Optional[Ann] = None
        for sub in subs:
            branch = Ann() if ann is not None else None
            if sub.evaluate(inst, scope, branch):
                found += 1
                if found > 1:
                    return False
                winner = branch
        if found != 1:
            return False
        if ann is not None:
            ann.merge(winner)  # type: ignore[arg-type]
        return True

    node.add(None, check)


def kw_not(ctx, node, schema, value) -> None:
    sub = ctx.subschema(value, node.base)

    def check(inst, scope, ann):
        return not sub.evaluate(inst, scope, None)

    node.add(None, check)


def kw_if(ctx, node, schema, value) -> None:
    if_node = ctx.subschema(value, node.base)
    then_raw = schema.get("then")
    else_raw = schema.get("else")
    then_node = ctx.subschema(then_raw, node.base) if then_raw is not None else None
    else_node = ctx.subschema(else_raw, node.base) if else_raw is not None else None

    def check(inst, scope, ann):
        if ann is None:
            matched = if_node.evaluate(inst, scope, None)
        else:
            branch = Ann()
            matched = if_node.evaluate(inst, scope, branch)
            if matched:
                ann.merge(branch)
        chosen = then_node if matched else else_node
        return chosen is None or chosen.evaluate(inst, scope, ann)

    node.add(None, check)


def kw_then_else(ctx, node, schema, value) -> None:
    # Compiled (and indexed) by ``if``; without ``if`` they only need indexing.
    ctx.subschema(value, node.base)


# ---------------------------------------------------------------------------
# References
# ---------------------------------------------------------------------------


def _split_reference(base: str, reference: str) -> Tuple[str, str]:
    doc, fragment = uri.split_fragment(uri.resolve(base, reference))
    return doc, uri.percent_decode(fragment or "")


def kw_ref(ctx, node, schema, value) -> None:
    if type(value) is not str:
        return
    registry = ctx.registry
    doc, fragment = _split_reference(node.base, value)
    cache: List[Node] = []

    def check(inst, scope, ann):
        if not cache:
            try:
                cache.append(registry.resolve(doc, fragment))
            except RefResolutionError as exc:
                raise RefResolutionError(f"cannot resolve $ref {value!r}: {exc}") from None
        return cache[0].evaluate(inst, scope, ann)

    node.add(None, check)


def kw_dynamic_ref(ctx, node, schema, value) -> None:
    if type(value) is not str:
        return
    registry = ctx.registry
    doc, fragment = _split_reference(node.base, value)
    plain_name = fragment != "" and not fragment.startswith("/")
    cache: List[Node] = []

    def check(inst, scope, ann):
        if plain_name and (doc, fragment) in registry.dynamic_anchors:
            dynamic = registry.dynamic_anchors
            for base in scope:
                target = dynamic.get((base, fragment))
                if target is not None:
                    return target.evaluate(inst, scope, ann)
        if not cache:
            try:
                cache.append(registry.resolve(doc, fragment))
            except RefResolutionError as exc:
                raise RefResolutionError(
                    f"cannot resolve $dynamicRef {value!r}: {exc}"
                ) from None
        return cache[0].evaluate(inst, scope, ann)

    node.add(None, check)


def kw_index_only(ctx, node, schema, value) -> None:
    """``$defs``: subschemas are indexed (ids, anchors) but never applied."""
    if type(value) is dict:
        for sub in value.values():
            ctx.subschema(sub, node.base, lenient=True)


def kw_content_schema(ctx, node, schema, value) -> None:
    ctx.subschema(value, node.base, lenient=True)


#: keyword -> handler.  Anything not listed here is inert.
KEYWORDS: Dict[str, Handler] = {
    "type": kw_type,
    "enum": kw_enum,
    "const": kw_const,
    "multipleOf": kw_multiple_of,
    "maximum": kw_maximum,
    "minimum": kw_minimum,
    "exclusiveMaximum": kw_exclusive_maximum,
    "exclusiveMinimum": kw_exclusive_minimum,
    "maxLength": kw_max_length,
    "minLength": kw_min_length,
    "pattern": kw_pattern,
    "maxItems": kw_max_items,
    "minItems": kw_min_items,
    "uniqueItems": kw_unique_items,
    "prefixItems": kw_prefix_items,
    "items": kw_items,
    "contains": kw_contains,
    "unevaluatedItems": kw_unevaluated_items,
    "maxProperties": kw_max_properties,
    "minProperties": kw_min_properties,
    "required": kw_required,
    "dependentRequired": kw_dependent_required,
    "properties": kw_properties,
    "patternProperties": kw_pattern_properties,
    "additionalProperties": kw_additional_properties,
    "propertyNames": kw_property_names,
    "dependentSchemas": kw_dependent_schemas,
    "unevaluatedProperties": kw_unevaluated_properties,
    "allOf": kw_all_of,
    "anyOf": kw_any_of,
    "oneOf": kw_one_of,
    "not": kw_not,
    "if": kw_if,
    "then": kw_then_else,
    "else": kw_then_else,
    "$ref": kw_ref,
    "$dynamicRef": kw_dynamic_ref,
    "$defs": kw_index_only,
    "contentSchema": kw_content_schema,
}
