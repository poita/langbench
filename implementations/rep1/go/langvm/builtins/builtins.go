// Package builtins lists the 132 built-in functions of the Vellum standard
// library (SPEC.md section 15) with their signatures. The signatures are
// written in Vellum syntax and are parsed and resolved by the checker; the vm
// package supplies the implementations, matched by name.
package builtins

// Spec describes one built-in function.
type Spec struct {
	Name string
	// Sig is the function header in Vellum syntax, e.g.
	// "fn listLen<T>(xs: [T]) -> Int".
	Sig string
}

// All is the table of built-ins; a built-in's id is its index.
var All = []Spec{
	{"print", "fn print(s: Str)"},
	{"emit", "fn emit(s: Str)"},
	{"panic", "fn panic(msg: Str)"},

	{"intMin", "fn intMin() -> Int"},
	{"intMax", "fn intMax() -> Int"},
	{"absI", "fn absI(x: Int) -> Int"},
	{"minI", "fn minI(a: Int, b: Int) -> Int"},
	{"maxI", "fn maxI(a: Int, b: Int) -> Int"},
	{"signI", "fn signI(x: Int) -> Int"},
	{"cmpI", "fn cmpI(a: Int, b: Int) -> Int"},
	{"divFloor", "fn divFloor(a: Int, b: Int) -> Int"},
	{"modFloor", "fn modFloor(a: Int, b: Int) -> Int"},
	{"powI", "fn powI(base: Int, exp: Int) -> Int"},
	{"gcdI", "fn gcdI(a: Int, b: Int) -> Int"},
	{"popCount", "fn popCount(x: Int) -> Int"},
	{"clz", "fn clz(x: Int) -> Int"},
	{"ctz", "fn ctz(x: Int) -> Int"},
	{"toFloat", "fn toFloat(x: Int) -> Float"},
	{"showInt", "fn showInt(x: Int) -> Str"},
	{"showIntRadix", "fn showIntRadix(x: Int, radix: Int) -> Str"},
	{"parseInt", "fn parseInt(s: Str) -> Option<Int>"},
	{"parseIntRadix", "fn parseIntRadix(s: Str, radix: Int) -> Option<Int>"},

	{"sqrtF", "fn sqrtF(x: Float) -> Float"},
	{"absF", "fn absF(x: Float) -> Float"},
	{"floorF", "fn floorF(x: Float) -> Float"},
	{"ceilF", "fn ceilF(x: Float) -> Float"},
	{"truncF", "fn truncF(x: Float) -> Float"},
	{"roundF", "fn roundF(x: Float) -> Float"},
	{"minF", "fn minF(a: Float, b: Float) -> Float"},
	{"maxF", "fn maxF(a: Float, b: Float) -> Float"},
	{"fmodF", "fn fmodF(a: Float, b: Float) -> Float"},
	{"powF", "fn powF(x: Float, n: Int) -> Float"},
	{"isNanF", "fn isNanF(x: Float) -> Bool"},
	{"isInfF", "fn isInfF(x: Float) -> Bool"},
	{"cmpF", "fn cmpF(a: Float, b: Float) -> Int"},
	{"truncToInt", "fn truncToInt(x: Float) -> Int"},
	{"showFloat", "fn showFloat(x: Float) -> Str"},
	{"showFloatAt", "fn showFloatAt(x: Float, digits: Int) -> Str"},
	{"floatBits", "fn floatBits(x: Float) -> Int"},
	{"floatFromBits", "fn floatFromBits(bits: Int) -> Float"},
	{"parseFloat", "fn parseFloat(s: Str) -> Option<Float>"},
	{"infF", "fn infF() -> Float"},
	{"nanF", "fn nanF() -> Float"},
	{"piF", "fn piF() -> Float"},

	{"showBool", "fn showBool(b: Bool) -> Str"},
	{"ord", "fn ord(c: Char) -> Int"},
	{"chr", "fn chr(n: Int) -> Char"},
	{"isDigit", "fn isDigit(c: Char) -> Bool"},
	{"isAlpha", "fn isAlpha(c: Char) -> Bool"},
	{"isAlnum", "fn isAlnum(c: Char) -> Bool"},
	{"isSpace", "fn isSpace(c: Char) -> Bool"},
	{"isUpper", "fn isUpper(c: Char) -> Bool"},
	{"isLower", "fn isLower(c: Char) -> Bool"},
	{"toUpperC", "fn toUpperC(c: Char) -> Char"},
	{"toLowerC", "fn toLowerC(c: Char) -> Char"},
	{"cmpC", "fn cmpC(a: Char, b: Char) -> Int"},
	{"showChar", "fn showChar(c: Char) -> Str"},
	{"quoteChar", "fn quoteChar(c: Char) -> Str"},

	{"strLen", "fn strLen(s: Str) -> Int"},
	{"charAt", "fn charAt(s: Str, i: Int) -> Char"},
	{"substr", "fn substr(s: Str, from: Int, to: Int) -> Str"},
	{"strCat", "fn strCat(a: Str, b: Str) -> Str"},
	{"strRepeat", "fn strRepeat(s: Str, n: Int) -> Str"},
	{"strIndexOf", "fn strIndexOf(s: Str, sub: Str) -> Int"},
	{"strLastIndexOf", "fn strLastIndexOf(s: Str, sub: Str) -> Int"},
	{"strContains", "fn strContains(s: Str, sub: Str) -> Bool"},
	{"startsWith", "fn startsWith(s: Str, p: Str) -> Bool"},
	{"endsWith", "fn endsWith(s: Str, p: Str) -> Bool"},
	{"strSplit", "fn strSplit(s: Str, sep: Str) -> [Str]"},
	{"strJoin", "fn strJoin(parts: [Str], sep: Str) -> Str"},
	{"strReplace", "fn strReplace(s: Str, from: Str, to: Str) -> Str"},
	{"trim", "fn trim(s: Str) -> Str"},
	{"trimLeft", "fn trimLeft(s: Str) -> Str"},
	{"trimRight", "fn trimRight(s: Str) -> Str"},
	{"upper", "fn upper(s: Str) -> Str"},
	{"lower", "fn lower(s: Str) -> Str"},
	{"strCmp", "fn strCmp(a: Str, b: Str) -> Int"},
	{"chars", "fn chars(s: Str) -> [Char]"},
	{"strOfChars", "fn strOfChars(cs: [Char]) -> Str"},
	{"strReverse", "fn strReverse(s: Str) -> Str"},
	{"quoteStr", "fn quoteStr(s: Str) -> Str"},
	{"padLeft", "fn padLeft(s: Str, width: Int, c: Char) -> Str"},
	{"padRight", "fn padRight(s: Str, width: Int, c: Char) -> Str"},

	{"listNew", "fn listNew<T>() -> [T]"},
	{"listLen", "fn listLen<T>(xs: [T]) -> Int"},
	{"push", "fn push<T>(xs: [T], x: T)"},
	{"pop", "fn pop<T>(xs: [T]) -> T"},
	{"insert", "fn insert<T>(xs: [T], i: Int, x: T)"},
	{"removeAt", "fn removeAt<T>(xs: [T], i: Int) -> T"},
	{"clear", "fn clear<T>(xs: [T])"},
	{"listRepeat", "fn listRepeat<T>(x: T, n: Int) -> [T]"},
	{"listConcat", "fn listConcat<T>(a: [T], b: [T]) -> [T]"},
	{"slice", "fn slice<T>(xs: [T], from: Int, to: Int) -> [T]"},
	{"listCopy", "fn listCopy<T>(xs: [T]) -> [T]"},
	{"reverseList", "fn reverseList<T>(xs: [T]) -> [T]"},
	{"listFirst", "fn listFirst<T>(xs: [T]) -> T"},
	{"listLast", "fn listLast<T>(xs: [T]) -> T"},
	{"listMap", "fn listMap<T, U>(xs: [T], f: fn(T) -> U) -> [U]"},
	{"listFilter", "fn listFilter<T>(xs: [T], f: fn(T) -> Bool) -> [T]"},
	{"listFold", "fn listFold<T, A>(xs: [T], init: A, f: fn(A, T) -> A) -> A"},
	{"listAny", "fn listAny<T>(xs: [T], f: fn(T) -> Bool) -> Bool"},
	{"listAll", "fn listAll<T>(xs: [T], f: fn(T) -> Bool) -> Bool"},
	{"listFind", "fn listFind<T>(xs: [T], f: fn(T) -> Bool) -> Option<T>"},
	{"listFindIndex", "fn listFindIndex<T>(xs: [T], f: fn(T) -> Bool) -> Int"},
	{"listIndexOf", "fn listIndexOf<T: Eq>(xs: [T], x: T) -> Int"},
	{"listContains", "fn listContains<T: Eq>(xs: [T], x: T) -> Bool"},
	{"listZip", "fn listZip<A, B>(a: [A], b: [B]) -> [(A, B)]"},
	{"listFlatten", "fn listFlatten<T>(xss: [[T]]) -> [T]"},
	{"sortBy", "fn sortBy<T>(xs: [T], cmp: fn(T, T) -> Int) -> [T]"},

	{"mapNew", "fn mapNew<K: Key, V>() -> #[K: V]"},
	{"mapLen", "fn mapLen<K: Key, V>(m: #[K: V]) -> Int"},
	{"mapHas", "fn mapHas<K: Key, V>(m: #[K: V], k: K) -> Bool"},
	{"mapGet", "fn mapGet<K: Key, V>(m: #[K: V], k: K) -> Option<V>"},
	{"mapGetOr", "fn mapGetOr<K: Key, V>(m: #[K: V], k: K, dflt: V) -> V"},
	{"mapSet", "fn mapSet<K: Key, V>(m: #[K: V], k: K, v: V)"},
	{"mapDel", "fn mapDel<K: Key, V>(m: #[K: V], k: K) -> Bool"},
	{"keysOf", "fn keysOf<K: Key, V>(m: #[K: V]) -> [K]"},
	{"valuesOf", "fn valuesOf<K: Key, V>(m: #[K: V]) -> [V]"},
	{"pairsOf", "fn pairsOf<K: Key, V>(m: #[K: V]) -> [(K, V)]"},
	{"mapClear", "fn mapClear<K: Key, V>(m: #[K: V])"},
	{"mapCopy", "fn mapCopy<K: Key, V>(m: #[K: V]) -> #[K: V]"},

	{"isSome", "fn isSome<T>(o: Option<T>) -> Bool"},
	{"isNone", "fn isNone<T>(o: Option<T>) -> Bool"},
	{"unwrap", "fn unwrap<T>(o: Option<T>) -> T"},
	{"unwrapOr", "fn unwrapOr<T>(o: Option<T>, dflt: T) -> T"},
	{"isOk", "fn isOk<T, E>(r: Result<T, E>) -> Bool"},
	{"isErr", "fn isErr<T, E>(r: Result<T, E>) -> Bool"},
	{"unwrapOk", "fn unwrapOk<T, E>(r: Result<T, E>) -> T"},
	{"unwrapErr", "fn unwrapErr<T, E>(r: Result<T, E>) -> E"},
	{"fst", "fn fst<A, B>(t: (A, B)) -> A"},
	{"snd", "fn snd<A, B>(t: (A, B)) -> B"},

	{"fmt", "fn fmt(template: Str, args: [Str]) -> Str"},
}

// ID returns the id of the named built-in, or -1.
func ID(name string) int {
	for i, s := range All {
		if s.Name == name {
			return i
		}
	}
	return -1
}
