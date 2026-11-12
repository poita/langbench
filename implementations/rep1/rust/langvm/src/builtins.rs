//! The table of the 132 built-in functions: their names and signatures.
//!
//! Signatures are written in Vellum syntax and parsed with the ordinary
//! parser when the prelude is built; the implementations live in
//! [`crate::stdlib`].

macro_rules! builtins {
    ($($v:ident $name:literal $sig:literal;)*) => {
        /// A built-in function (one variant per entry of the standard library).
        #[allow(missing_docs)]
        #[derive(Copy, Clone, PartialEq, Eq, Debug)]
        #[repr(u8)]
        pub enum Builtin { $($v,)* }

        impl Builtin {
            /// All built-ins, in table order (index = discriminant).
            pub const ALL: &'static [Builtin] = &[$(Builtin::$v,)*];
            /// The name the language uses for this built-in.
            pub fn name(self) -> &'static str {
                match self { $(Builtin::$v => $name,)* }
            }
            /// The signature in Vellum syntax, without `fn` or a body.
            pub fn signature(self) -> &'static str {
                match self { $(Builtin::$v => $sig,)* }
            }
        }
    };
}

builtins! {
    Print "print" "print(s: Str)";
    Emit "emit" "emit(s: Str)";
    Panic "panic" "panic(msg: Str)";

    IntMin "intMin" "intMin() -> Int";
    IntMax "intMax" "intMax() -> Int";
    AbsI "absI" "absI(x: Int) -> Int";
    MinI "minI" "minI(a: Int, b: Int) -> Int";
    MaxI "maxI" "maxI(a: Int, b: Int) -> Int";
    SignI "signI" "signI(x: Int) -> Int";
    CmpI "cmpI" "cmpI(a: Int, b: Int) -> Int";
    DivFloor "divFloor" "divFloor(a: Int, b: Int) -> Int";
    ModFloor "modFloor" "modFloor(a: Int, b: Int) -> Int";
    PowI "powI" "powI(base: Int, exp: Int) -> Int";
    GcdI "gcdI" "gcdI(a: Int, b: Int) -> Int";
    PopCount "popCount" "popCount(x: Int) -> Int";
    Clz "clz" "clz(x: Int) -> Int";
    Ctz "ctz" "ctz(x: Int) -> Int";
    ToFloat "toFloat" "toFloat(x: Int) -> Float";
    ShowInt "showInt" "showInt(x: Int) -> Str";
    ShowIntRadix "showIntRadix" "showIntRadix(x: Int, radix: Int) -> Str";
    ParseInt "parseInt" "parseInt(s: Str) -> Option<Int>";
    ParseIntRadix "parseIntRadix" "parseIntRadix(s: Str, radix: Int) -> Option<Int>";

    SqrtF "sqrtF" "sqrtF(x: Float) -> Float";
    AbsF "absF" "absF(x: Float) -> Float";
    FloorF "floorF" "floorF(x: Float) -> Float";
    CeilF "ceilF" "ceilF(x: Float) -> Float";
    TruncF "truncF" "truncF(x: Float) -> Float";
    RoundF "roundF" "roundF(x: Float) -> Float";
    MinF "minF" "minF(a: Float, b: Float) -> Float";
    MaxF "maxF" "maxF(a: Float, b: Float) -> Float";
    FmodF "fmodF" "fmodF(a: Float, b: Float) -> Float";
    PowF "powF" "powF(x: Float, n: Int) -> Float";
    IsNanF "isNanF" "isNanF(x: Float) -> Bool";
    IsInfF "isInfF" "isInfF(x: Float) -> Bool";
    CmpF "cmpF" "cmpF(a: Float, b: Float) -> Int";
    TruncToInt "truncToInt" "truncToInt(x: Float) -> Int";
    ShowFloat "showFloat" "showFloat(x: Float) -> Str";
    ShowFloatAt "showFloatAt" "showFloatAt(x: Float, digits: Int) -> Str";
    FloatBits "floatBits" "floatBits(x: Float) -> Int";
    FloatFromBits "floatFromBits" "floatFromBits(bits: Int) -> Float";
    ParseFloat "parseFloat" "parseFloat(s: Str) -> Option<Float>";
    InfF "infF" "infF() -> Float";
    NanF "nanF" "nanF() -> Float";
    PiF "piF" "piF() -> Float";

    ShowBool "showBool" "showBool(b: Bool) -> Str";
    Ord "ord" "ord(c: Char) -> Int";
    Chr "chr" "chr(n: Int) -> Char";
    IsDigit "isDigit" "isDigit(c: Char) -> Bool";
    IsAlpha "isAlpha" "isAlpha(c: Char) -> Bool";
    IsAlnum "isAlnum" "isAlnum(c: Char) -> Bool";
    IsSpace "isSpace" "isSpace(c: Char) -> Bool";
    IsUpper "isUpper" "isUpper(c: Char) -> Bool";
    IsLower "isLower" "isLower(c: Char) -> Bool";
    ToUpperC "toUpperC" "toUpperC(c: Char) -> Char";
    ToLowerC "toLowerC" "toLowerC(c: Char) -> Char";
    CmpC "cmpC" "cmpC(a: Char, b: Char) -> Int";
    ShowChar "showChar" "showChar(c: Char) -> Str";
    QuoteChar "quoteChar" "quoteChar(c: Char) -> Str";

    StrLen "strLen" "strLen(s: Str) -> Int";
    CharAt "charAt" "charAt(s: Str, i: Int) -> Char";
    Substr "substr" "substr(s: Str, from: Int, to: Int) -> Str";
    StrCat "strCat" "strCat(a: Str, b: Str) -> Str";
    StrRepeat "strRepeat" "strRepeat(s: Str, n: Int) -> Str";
    StrIndexOf "strIndexOf" "strIndexOf(s: Str, sub: Str) -> Int";
    StrLastIndexOf "strLastIndexOf" "strLastIndexOf(s: Str, sub: Str) -> Int";
    StrContains "strContains" "strContains(s: Str, sub: Str) -> Bool";
    StartsWith "startsWith" "startsWith(s: Str, p: Str) -> Bool";
    EndsWith "endsWith" "endsWith(s: Str, p: Str) -> Bool";
    StrSplit "strSplit" "strSplit(s: Str, sep: Str) -> [Str]";
    StrJoin "strJoin" "strJoin(parts: [Str], sep: Str) -> Str";
    StrReplace "strReplace" "strReplace(s: Str, from: Str, to: Str) -> Str";
    Trim "trim" "trim(s: Str) -> Str";
    TrimLeft "trimLeft" "trimLeft(s: Str) -> Str";
    TrimRight "trimRight" "trimRight(s: Str) -> Str";
    Upper "upper" "upper(s: Str) -> Str";
    Lower "lower" "lower(s: Str) -> Str";
    StrCmp "strCmp" "strCmp(a: Str, b: Str) -> Int";
    Chars "chars" "chars(s: Str) -> [Char]";
    StrOfChars "strOfChars" "strOfChars(cs: [Char]) -> Str";
    StrReverse "strReverse" "strReverse(s: Str) -> Str";
    QuoteStr "quoteStr" "quoteStr(s: Str) -> Str";
    PadLeft "padLeft" "padLeft(s: Str, width: Int, c: Char) -> Str";
    PadRight "padRight" "padRight(s: Str, width: Int, c: Char) -> Str";

    ListNew "listNew" "listNew<T>() -> [T]";
    ListLen "listLen" "listLen<T>(xs: [T]) -> Int";
    Push "push" "push<T>(xs: [T], x: T)";
    Pop "pop" "pop<T>(xs: [T]) -> T";
    Insert "insert" "insert<T>(xs: [T], i: Int, x: T)";
    RemoveAt "removeAt" "removeAt<T>(xs: [T], i: Int) -> T";
    Clear "clear" "clear<T>(xs: [T])";
    ListRepeat "listRepeat" "listRepeat<T>(x: T, n: Int) -> [T]";
    ListConcat "listConcat" "listConcat<T>(a: [T], b: [T]) -> [T]";
    Slice "slice" "slice<T>(xs: [T], from: Int, to: Int) -> [T]";
    ListCopy "listCopy" "listCopy<T>(xs: [T]) -> [T]";
    ReverseList "reverseList" "reverseList<T>(xs: [T]) -> [T]";
    ListFirst "listFirst" "listFirst<T>(xs: [T]) -> T";
    ListLast "listLast" "listLast<T>(xs: [T]) -> T";
    ListMap "listMap" "listMap<T, U>(xs: [T], f: fn(T) -> U) -> [U]";
    ListFilter "listFilter" "listFilter<T>(xs: [T], f: fn(T) -> Bool) -> [T]";
    ListFold "listFold" "listFold<T, A>(xs: [T], init: A, f: fn(A, T) -> A) -> A";
    ListAny "listAny" "listAny<T>(xs: [T], f: fn(T) -> Bool) -> Bool";
    ListAll "listAll" "listAll<T>(xs: [T], f: fn(T) -> Bool) -> Bool";
    ListFind "listFind" "listFind<T>(xs: [T], f: fn(T) -> Bool) -> Option<T>";
    ListFindIndex "listFindIndex" "listFindIndex<T>(xs: [T], f: fn(T) -> Bool) -> Int";
    ListIndexOf "listIndexOf" "listIndexOf<T: Eq>(xs: [T], x: T) -> Int";
    ListContains "listContains" "listContains<T: Eq>(xs: [T], x: T) -> Bool";
    ListZip "listZip" "listZip<A, B>(a: [A], b: [B]) -> [(A, B)]";
    ListFlatten "listFlatten" "listFlatten<T>(xss: [[T]]) -> [T]";
    SortBy "sortBy" "sortBy<T>(xs: [T], cmp: fn(T, T) -> Int) -> [T]";

    MapNew "mapNew" "mapNew<K: Key, V>() -> #[K: V]";
    MapLen "mapLen" "mapLen<K: Key, V>(m: #[K: V]) -> Int";
    MapHas "mapHas" "mapHas<K: Key, V>(m: #[K: V], k: K) -> Bool";
    MapGet "mapGet" "mapGet<K: Key, V>(m: #[K: V], k: K) -> Option<V>";
    MapGetOr "mapGetOr" "mapGetOr<K: Key, V>(m: #[K: V], k: K, dflt: V) -> V";
    MapSet "mapSet" "mapSet<K: Key, V>(m: #[K: V], k: K, v: V)";
    MapDel "mapDel" "mapDel<K: Key, V>(m: #[K: V], k: K) -> Bool";
    KeysOf "keysOf" "keysOf<K: Key, V>(m: #[K: V]) -> [K]";
    ValuesOf "valuesOf" "valuesOf<K: Key, V>(m: #[K: V]) -> [V]";
    PairsOf "pairsOf" "pairsOf<K: Key, V>(m: #[K: V]) -> [(K, V)]";
    MapClear "mapClear" "mapClear<K: Key, V>(m: #[K: V])";
    MapCopy "mapCopy" "mapCopy<K: Key, V>(m: #[K: V]) -> #[K: V]";

    IsSome "isSome" "isSome<T>(o: Option<T>) -> Bool";
    IsNone "isNone" "isNone<T>(o: Option<T>) -> Bool";
    Unwrap "unwrap" "unwrap<T>(o: Option<T>) -> T";
    UnwrapOr "unwrapOr" "unwrapOr<T>(o: Option<T>, dflt: T) -> T";
    IsOk "isOk" "isOk<T, E>(r: Result<T, E>) -> Bool";
    IsErr "isErr" "isErr<T, E>(r: Result<T, E>) -> Bool";
    UnwrapOk "unwrapOk" "unwrapOk<T, E>(r: Result<T, E>) -> T";
    UnwrapErr "unwrapErr" "unwrapErr<T, E>(r: Result<T, E>) -> E";
    Fst "fst" "fst<A, B>(t: (A, B)) -> A";
    Snd "snd" "snd<A, B>(t: (A, B)) -> B";

    Fmt "fmt" "fmt(template: Str, args: [Str]) -> Str";
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn there_are_132_builtins() {
        assert_eq!(Builtin::ALL.len(), 132);
        let mut names: Vec<_> = Builtin::ALL.iter().map(|b| b.name()).collect();
        names.sort();
        names.dedup();
        assert_eq!(names.len(), 132);
    }
}
