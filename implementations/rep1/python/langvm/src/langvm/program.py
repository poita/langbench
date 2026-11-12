"""Declaration records and the whole-program tables built by the item passes."""

from __future__ import annotations

from .types import TParam, TNamed, Type

# Fixed unique ids for the prelude's declarations (the VM and stdlib rely on them).
SOME_UID, NONE_UID, OK_UID, ERR_UID = 0, 1, 2, 3
OPTION_UID, RESULT_UID = 4, 5
FIRST_FREE_UID = 6


class UidCounter:
    def __init__(self, start: int = FIRST_FREE_UID):
        self.n = start

    def next(self) -> int:
        n = self.n
        self.n += 1
        return n


class StructInfo:
    is_enum = False

    def __init__(self, uid, module, name, pub, node):
        self.uid = uid
        self.module = module
        self.name = name
        self.pub = pub
        self.node = node
        self.tparams: list[TParam] = []
        self.fields: list[tuple[str, Type]] = []
        self.field_index: dict[str, int] = {}

    def type_with(self, args) -> TNamed:
        return TNamed(self, args)

    def own_type(self) -> TNamed:
        return TNamed(self, self.tparams)


class VariantInfo:
    def __init__(self, uid, name, enum, index, pos):
        self.uid = uid
        self.name = name
        self.enum = enum
        self.index = index
        self.pos = pos
        self.payload: list[Type] = []
        self.const = None  # preallocated value for payload-less variants (set by VM link)


class EnumInfo:
    is_enum = True

    def __init__(self, uid, module, name, pub, node):
        self.uid = uid
        self.module = module
        self.name = name
        self.pub = pub
        self.node = node
        self.tparams: list[TParam] = []
        self.variants: list[VariantInfo] = []

    def own_type(self) -> TNamed:
        return TNamed(self, self.tparams)


class MethodSig:
    def __init__(self, name, index, trait, node):
        self.name = name
        self.index = index
        self.trait = trait
        self.node = node
        self.params: list[Type] = []
        self.ret: Type | None = None
        self.default: FuncInfo | None = None


class TraitInfo:
    def __init__(self, uid, module, name, pub, node, builtin=False):
        self.uid = uid
        self.module = module
        self.name = name
        self.pub = pub
        self.node = node
        self.builtin = builtin
        self.methods: list[MethodSig] = []
        self.method_index: dict[str, MethodSig] = {}
        self.self_param = TParam("Self", [self])

    def __repr__(self):
        return f"trait {self.name}"


EQ_TRAIT = TraitInfo(-1, None, "Eq", True, None, builtin=True)
ORD_TRAIT = TraitInfo(-2, None, "Ord", True, None, builtin=True)
KEY_TRAIT = TraitInfo(-3, None, "Key", True, None, builtin=True)


class FuncInfo:
    """Anything that compiles to a code object: fn, impl method, default body, lambda."""

    def __init__(self, name, module, node, kind):
        self.name = name
        self.module = module
        self.node = node
        self.kind = kind  # fn | method | default | lambda
        self.pub = False
        self.tparams: list[TParam] = []
        self.params: list[tuple[str, Type]] = []
        self.ret: Type | None = None
        self.self_ty: Type | None = None
        self.code = None  # filled by the compiler
        self.ctx = None  # FnCtx from the checker (captures etc.)

    def __repr__(self):
        return f"<func {self.name}>"


class ImplInfo:
    def __init__(self, module, node):
        self.module = module
        self.node = node
        self.trait: TraitInfo | None = None
        self.tparams: list[TParam] = []
        self.head: Type | None = None
        self.head_key = None
        self.methods: dict[str, FuncInfo] = {}


class BuiltinInfo:
    def __init__(self, name, bid):
        self.name = name
        self.id = bid
        self.tparams: list[TParam] = []
        self.params: list[Type] = []
        self.ret: Type | None = None


class Module:
    def __init__(self, name: str, items=None, source=None):
        self.name = name
        self.items = items or []
        self.source = source
        self.types: dict[str, object] = {}
        self.traits: dict[str, TraitInfo] = {}
        self.values: dict[str, object] = {}
        self.imports: dict[str, Module] = {}
        # Per-item records, parallel to ``items`` where relevant.
        self.decls: dict[int, object] = {}  # id(node) -> info
        self.visible_traits_cache: list[TraitInfo] | None = None

    def visible_traits(self) -> list[TraitInfo]:
        """Own traits, then pub traits of imported modules (deduplicated)."""
        if self.visible_traits_cache is None:
            seen = []
            for t in self.traits.values():
                seen.append(t)
            for alias in sorted(self.imports):
                m = self.imports[alias]
                if m is self:
                    continue
                for t in m.traits.values():
                    if t.pub and t not in seen:
                        seen.append(t)
            self.visible_traits_cache = seen
        return self.visible_traits_cache


def head_key_of(ty):
    """The head constructor key of a type, or ``None`` for tuples/functions/params."""
    from .types import TPrim, TList, TMap, prune

    ty = prune(ty)
    c = type(ty)
    if c is TPrim:
        return ty.name
    if c is TList:
        return "List"
    if c is TMap:
        return "Map"
    if c is TNamed:
        return ty.decl.uid
    return None


class Program:
    def __init__(self):
        self.modules: list[Module] = []
        self.module_by_name: dict[str, Module] = {}
        self.prelude: Module | None = None
        self.uids = UidCounter()
        self.impls: dict[tuple[int, object], ImplInfo] = {}
        self.impl_list: list[ImplInfo] = []
        self.traits: list[TraitInfo] = []
        self.builtins: dict[str, BuiltinInfo] = {}
        self.main: FuncInfo | None = None
        self.structs: list[StructInfo] = []
        self.enums: list[EnumInfo] = []
