"""The prelude: Option/Result, the built-in traits and the 132 built-in signatures."""

from __future__ import annotations

from .lexer import tokenize
from .parser import Parser
from .program import (
    EQ_TRAIT, ERR_UID, KEY_TRAIT, NONE_UID, OK_UID, OPTION_UID, ORD_TRAIT, RESULT_UID,
    SOME_UID, BuiltinInfo, EnumInfo, Module, Program, VariantInfo,
)
from .types import TParam, UNIT

#: Built-in signatures in Vellum syntax (SPEC section 15).  Types are resolved
#: in the prelude's own scope, so ``Option``/``Result`` always mean the prelude's.
SIGNATURES = """
fn print(s: Str);
fn emit(s: Str);
fn panic(msg: Str);

fn intMin() -> Int;
fn intMax() -> Int;
fn absI(x: Int) -> Int;
fn minI(a: Int, b: Int) -> Int;
fn maxI(a: Int, b: Int) -> Int;
fn signI(x: Int) -> Int;
fn cmpI(a: Int, b: Int) -> Int;
fn divFloor(a: Int, b: Int) -> Int;
fn modFloor(a: Int, b: Int) -> Int;
fn powI(base: Int, exp: Int) -> Int;
fn gcdI(a: Int, b: Int) -> Int;
fn popCount(x: Int) -> Int;
fn clz(x: Int) -> Int;
fn ctz(x: Int) -> Int;
fn toFloat(x: Int) -> Float;
fn showInt(x: Int) -> Str;
fn showIntRadix(x: Int, radix: Int) -> Str;
fn parseInt(s: Str) -> Option<Int>;
fn parseIntRadix(s: Str, radix: Int) -> Option<Int>;

fn sqrtF(x: Float) -> Float;
fn absF(x: Float) -> Float;
fn floorF(x: Float) -> Float;
fn ceilF(x: Float) -> Float;
fn truncF(x: Float) -> Float;
fn roundF(x: Float) -> Float;
fn minF(a: Float, b: Float) -> Float;
fn maxF(a: Float, b: Float) -> Float;
fn fmodF(a: Float, b: Float) -> Float;
fn powF(x: Float, n: Int) -> Float;
fn isNanF(x: Float) -> Bool;
fn isInfF(x: Float) -> Bool;
fn cmpF(a: Float, b: Float) -> Int;
fn truncToInt(x: Float) -> Int;
fn showFloat(x: Float) -> Str;
fn showFloatAt(x: Float, digits: Int) -> Str;
fn floatBits(x: Float) -> Int;
fn floatFromBits(bits: Int) -> Float;
fn parseFloat(s: Str) -> Option<Float>;
fn infF() -> Float;
fn nanF() -> Float;
fn piF() -> Float;

fn showBool(b: Bool) -> Str;
fn ord(c: Char) -> Int;
fn chr(n: Int) -> Char;
fn isDigit(c: Char) -> Bool;
fn isAlpha(c: Char) -> Bool;
fn isAlnum(c: Char) -> Bool;
fn isSpace(c: Char) -> Bool;
fn isUpper(c: Char) -> Bool;
fn isLower(c: Char) -> Bool;
fn toUpperC(c: Char) -> Char;
fn toLowerC(c: Char) -> Char;
fn cmpC(a: Char, b: Char) -> Int;
fn showChar(c: Char) -> Str;
fn quoteChar(c: Char) -> Str;

fn strLen(s: Str) -> Int;
fn charAt(s: Str, i: Int) -> Char;
fn substr(s: Str, from: Int, to: Int) -> Str;
fn strCat(a: Str, b: Str) -> Str;
fn strRepeat(s: Str, n: Int) -> Str;
fn strIndexOf(s: Str, sub: Str) -> Int;
fn strLastIndexOf(s: Str, sub: Str) -> Int;
fn strContains(s: Str, sub: Str) -> Bool;
fn startsWith(s: Str, p: Str) -> Bool;
fn endsWith(s: Str, p: Str) -> Bool;
fn strSplit(s: Str, sep: Str) -> [Str];
fn strJoin(parts: [Str], sep: Str) -> Str;
fn strReplace(s: Str, from: Str, to: Str) -> Str;
fn trim(s: Str) -> Str;
fn trimLeft(s: Str) -> Str;
fn trimRight(s: Str) -> Str;
fn upper(s: Str) -> Str;
fn lower(s: Str) -> Str;
fn strCmp(a: Str, b: Str) -> Int;
fn chars(s: Str) -> [Char];
fn strOfChars(cs: [Char]) -> Str;
fn strReverse(s: Str) -> Str;
fn quoteStr(s: Str) -> Str;
fn padLeft(s: Str, width: Int, c: Char) -> Str;
fn padRight(s: Str, width: Int, c: Char) -> Str;

fn listNew<T>() -> [T];
fn listLen<T>(xs: [T]) -> Int;
fn push<T>(xs: [T], x: T);
fn pop<T>(xs: [T]) -> T;
fn insert<T>(xs: [T], i: Int, x: T);
fn removeAt<T>(xs: [T], i: Int) -> T;
fn clear<T>(xs: [T]);
fn listRepeat<T>(x: T, n: Int) -> [T];
fn listConcat<T>(a: [T], b: [T]) -> [T];
fn slice<T>(xs: [T], from: Int, to: Int) -> [T];
fn listCopy<T>(xs: [T]) -> [T];
fn reverseList<T>(xs: [T]) -> [T];
fn listFirst<T>(xs: [T]) -> T;
fn listLast<T>(xs: [T]) -> T;
fn listMap<T, U>(xs: [T], f: fn(T) -> U) -> [U];
fn listFilter<T>(xs: [T], f: fn(T) -> Bool) -> [T];
fn listFold<T, A>(xs: [T], init: A, f: fn(A, T) -> A) -> A;
fn listAny<T>(xs: [T], f: fn(T) -> Bool) -> Bool;
fn listAll<T>(xs: [T], f: fn(T) -> Bool) -> Bool;
fn listFind<T>(xs: [T], f: fn(T) -> Bool) -> Option<T>;
fn listFindIndex<T>(xs: [T], f: fn(T) -> Bool) -> Int;
fn listIndexOf<T: Eq>(xs: [T], x: T) -> Int;
fn listContains<T: Eq>(xs: [T], x: T) -> Bool;
fn listZip<A, B>(a: [A], b: [B]) -> [(A, B)];
fn listFlatten<T>(xss: [[T]]) -> [T];
fn sortBy<T>(xs: [T], cmp: fn(T, T) -> Int) -> [T];

fn mapNew<K: Key, V>() -> #[K: V];
fn mapLen<K: Key, V>(m: #[K: V]) -> Int;
fn mapHas<K: Key, V>(m: #[K: V], k: K) -> Bool;
fn mapGet<K: Key, V>(m: #[K: V], k: K) -> Option<V>;
fn mapGetOr<K: Key, V>(m: #[K: V], k: K, dflt: V) -> V;
fn mapSet<K: Key, V>(m: #[K: V], k: K, v: V);
fn mapDel<K: Key, V>(m: #[K: V], k: K) -> Bool;
fn keysOf<K: Key, V>(m: #[K: V]) -> [K];
fn valuesOf<K: Key, V>(m: #[K: V]) -> [V];
fn pairsOf<K: Key, V>(m: #[K: V]) -> [(K, V)];
fn mapClear<K: Key, V>(m: #[K: V]);
fn mapCopy<K: Key, V>(m: #[K: V]) -> #[K: V];

fn isSome<T>(o: Option<T>) -> Bool;
fn isNone<T>(o: Option<T>) -> Bool;
fn unwrap<T>(o: Option<T>) -> T;
fn unwrapOr<T>(o: Option<T>, dflt: T) -> T;
fn isOk<T, E>(r: Result<T, E>) -> Bool;
fn isErr<T, E>(r: Result<T, E>) -> Bool;
fn unwrapOk<T, E>(r: Result<T, E>) -> T;
fn unwrapErr<T, E>(r: Result<T, E>) -> E;
fn fst<A, B>(t: (A, B)) -> A;
fn snd<A, B>(t: (A, B)) -> B;

fn fmt(template: Str, args: [Str]) -> Str;
"""

#: Built-ins that call back into the VM (they need a frame snapshot for depth accounting).
HIGHER_ORDER = frozenset(
    "listMap listFilter listFold listAny listAll listFind listFindIndex sortBy".split()
)


def builtin_names() -> list[str]:
    """All built-in names in the order of their ids (alphabetical)."""
    import re

    names = re.findall(r"^fn (\w+)", SIGNATURES, re.M)
    return sorted(names)


BUILTIN_NAMES = builtin_names()
assert len(BUILTIN_NAMES) == 132, len(BUILTIN_NAMES)
BUILTIN_ID = {n: i for i, n in enumerate(BUILTIN_NAMES)}


def make_prelude(program: Program) -> Module:
    """Create the prelude module and register it on the program."""
    pm = Module("<prelude>")
    program.prelude = pm
    # Option and Result, "as if declared" in Vellum source.
    opt = EnumInfo(OPTION_UID, pm, "Option", True, None)
    t = TParam("T")
    opt.tparams = [t]
    some = VariantInfo(SOME_UID, "Some", opt, 0, None)
    some.payload = [t]
    none = VariantInfo(NONE_UID, "None", opt, 1, None)
    opt.variants = [some, none]
    res = EnumInfo(RESULT_UID, pm, "Result", True, None)
    t2, e2 = TParam("T"), TParam("E")
    res.tparams = [t2, e2]
    ok = VariantInfo(OK_UID, "Ok", res, 0, None)
    ok.payload = [t2]
    err = VariantInfo(ERR_UID, "Err", res, 1, None)
    err.payload = [e2]
    res.variants = [ok, err]
    pm.types["Option"] = opt
    pm.types["Result"] = res
    for v in (some, none, ok, err):
        pm.values[v.name] = v
    pm.traits["Eq"] = EQ_TRAIT
    pm.traits["Ord"] = ORD_TRAIT
    pm.traits["Key"] = KEY_TRAIT
    program.enums.extend([opt, res])
    program.option = opt
    program.result = res
    return pm


def install_builtins(program: Program, resolver) -> None:
    """Parse and resolve every built-in signature into BuiltinInfo records."""
    from .resolve import Scope

    pm = program.prelude
    parser = Parser(tokenize(SIGNATURES), (1, 1))
    for name, gparams, params, ret in parser.parse_signatures():
        b = BuiltinInfo(name, BUILTIN_ID[name])
        b.tparams = [TParam(g.name) for g in gparams]
        scope = Scope(pm, {tp.name: tp for tp in b.tparams}, None)
        for tp, g in zip(b.tparams, gparams):
            tp.bounds = [resolver.resolve_trait_ref(r, pm) for r in g.bounds]
        b.params = [resolver.resolve_type(p.ty, scope) for p in params]

        b.ret = resolver.resolve_type(ret, scope) if ret is not None else UNIT
        program.builtins[name] = b
        pm.values[name] = b
