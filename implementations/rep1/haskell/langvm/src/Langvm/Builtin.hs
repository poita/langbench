-- | The built-in functions of the standard library (SPEC.md section 15):
-- their identities and their signatures, written in Vellum syntax.
--
-- This module is generated from the table in the specification; the
-- implementations live in "Langvm.Stdlib".
module Langvm.Builtin
  ( Builtin (..)
  , builtinName
  , builtinFromName
  , preludeSource
  ) where

import qualified Data.Map.Strict as Map

-- | One constructor per built-in function.  The constructor name is the
-- function name with a leading @B@ and a capital letter.
data Builtin
  = BPrint
  | BEmit
  | BPanic
  | BIntMin
  | BIntMax
  | BAbsI
  | BMinI
  | BMaxI
  | BSignI
  | BCmpI
  | BDivFloor
  | BModFloor
  | BPowI
  | BGcdI
  | BPopCount
  | BClz
  | BCtz
  | BToFloat
  | BShowInt
  | BShowIntRadix
  | BParseInt
  | BParseIntRadix
  | BSqrtF
  | BAbsF
  | BFloorF
  | BCeilF
  | BTruncF
  | BRoundF
  | BMinF
  | BMaxF
  | BFmodF
  | BPowF
  | BIsNanF
  | BIsInfF
  | BCmpF
  | BTruncToInt
  | BShowFloat
  | BShowFloatAt
  | BFloatBits
  | BFloatFromBits
  | BParseFloat
  | BInfF
  | BNanF
  | BPiF
  | BShowBool
  | BOrd
  | BChr
  | BIsDigit
  | BIsAlpha
  | BIsAlnum
  | BIsSpace
  | BIsUpper
  | BIsLower
  | BToUpperC
  | BToLowerC
  | BCmpC
  | BShowChar
  | BQuoteChar
  | BStrLen
  | BCharAt
  | BSubstr
  | BStrCat
  | BStrRepeat
  | BStrIndexOf
  | BStrLastIndexOf
  | BStrContains
  | BStartsWith
  | BEndsWith
  | BStrSplit
  | BStrJoin
  | BStrReplace
  | BTrim
  | BTrimLeft
  | BTrimRight
  | BUpper
  | BLower
  | BStrCmp
  | BChars
  | BStrOfChars
  | BStrReverse
  | BQuoteStr
  | BPadLeft
  | BPadRight
  | BListNew
  | BListLen
  | BPush
  | BPop
  | BInsert
  | BRemoveAt
  | BClear
  | BListRepeat
  | BListConcat
  | BSlice
  | BListCopy
  | BReverseList
  | BListFirst
  | BListLast
  | BListMap
  | BListFilter
  | BListFold
  | BListAny
  | BListAll
  | BListFind
  | BListFindIndex
  | BListIndexOf
  | BListContains
  | BListZip
  | BListFlatten
  | BSortBy
  | BMapNew
  | BMapLen
  | BMapHas
  | BMapGet
  | BMapGetOr
  | BMapSet
  | BMapDel
  | BKeysOf
  | BValuesOf
  | BPairsOf
  | BMapClear
  | BMapCopy
  | BIsSome
  | BIsNone
  | BUnwrap
  | BUnwrapOr
  | BIsOk
  | BIsErr
  | BUnwrapOk
  | BUnwrapErr
  | BFst
  | BSnd
  | BFmt
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | The Vellum-level name of a built-in.
builtinName :: Builtin -> String
builtinName b = case show b of
  (_ : c : cs) -> toEnum (fromEnum c + 32) : cs
  _ -> ""

nameTable :: Map.Map String Builtin
nameTable = Map.fromList [(builtinName b, b) | b <- [minBound .. maxBound]]

-- | Look a built-in up by its Vellum name.
builtinFromName :: String -> Maybe Builtin
builtinFromName n = Map.lookup n nameTable

-- | The prelude as Vellum source: the declarations of @Option@, @Result@ and
-- every built-in function (with empty bodies).  Parsed like any other module.
preludeSource :: [String]
preludeSource =
  [ "enum Option<T> { Some(T), None }"
  , "enum Result<T, E> { Ok(T), Err(E) }"
  , "fn print(s: Str) {}"
  , "fn emit(s: Str) {}"
  , "fn panic(msg: Str) {}"
  , "fn intMin() -> Int {}"
  , "fn intMax() -> Int {}"
  , "fn absI(x: Int) -> Int {}"
  , "fn minI(a: Int, b: Int) -> Int {}"
  , "fn maxI(a: Int, b: Int) -> Int {}"
  , "fn signI(x: Int) -> Int {}"
  , "fn cmpI(a: Int, b: Int) -> Int {}"
  , "fn divFloor(a: Int, b: Int) -> Int {}"
  , "fn modFloor(a: Int, b: Int) -> Int {}"
  , "fn powI(base: Int, exp: Int) -> Int {}"
  , "fn gcdI(a: Int, b: Int) -> Int {}"
  , "fn popCount(x: Int) -> Int {}"
  , "fn clz(x: Int) -> Int {}"
  , "fn ctz(x: Int) -> Int {}"
  , "fn toFloat(x: Int) -> Float {}"
  , "fn showInt(x: Int) -> Str {}"
  , "fn showIntRadix(x: Int, radix: Int) -> Str {}"
  , "fn parseInt(s: Str) -> Option<Int> {}"
  , "fn parseIntRadix(s: Str, radix: Int) -> Option<Int> {}"
  , "fn sqrtF(x: Float) -> Float {}"
  , "fn absF(x: Float) -> Float {}"
  , "fn floorF(x: Float) -> Float {}"
  , "fn ceilF(x: Float) -> Float {}"
  , "fn truncF(x: Float) -> Float {}"
  , "fn roundF(x: Float) -> Float {}"
  , "fn minF(a: Float, b: Float) -> Float {}"
  , "fn maxF(a: Float, b: Float) -> Float {}"
  , "fn fmodF(a: Float, b: Float) -> Float {}"
  , "fn powF(x: Float, n: Int) -> Float {}"
  , "fn isNanF(x: Float) -> Bool {}"
  , "fn isInfF(x: Float) -> Bool {}"
  , "fn cmpF(a: Float, b: Float) -> Int {}"
  , "fn truncToInt(x: Float) -> Int {}"
  , "fn showFloat(x: Float) -> Str {}"
  , "fn showFloatAt(x: Float, digits: Int) -> Str {}"
  , "fn floatBits(x: Float) -> Int {}"
  , "fn floatFromBits(bits: Int) -> Float {}"
  , "fn parseFloat(s: Str) -> Option<Float> {}"
  , "fn infF() -> Float {}"
  , "fn nanF() -> Float {}"
  , "fn piF() -> Float {}"
  , "fn showBool(b: Bool) -> Str {}"
  , "fn ord(c: Char) -> Int {}"
  , "fn chr(n: Int) -> Char {}"
  , "fn isDigit(c: Char) -> Bool {}"
  , "fn isAlpha(c: Char) -> Bool {}"
  , "fn isAlnum(c: Char) -> Bool {}"
  , "fn isSpace(c: Char) -> Bool {}"
  , "fn isUpper(c: Char) -> Bool {}"
  , "fn isLower(c: Char) -> Bool {}"
  , "fn toUpperC(c: Char) -> Char {}"
  , "fn toLowerC(c: Char) -> Char {}"
  , "fn cmpC(a: Char, b: Char) -> Int {}"
  , "fn showChar(c: Char) -> Str {}"
  , "fn quoteChar(c: Char) -> Str {}"
  , "fn strLen(s: Str) -> Int {}"
  , "fn charAt(s: Str, i: Int) -> Char {}"
  , "fn substr(s: Str, from: Int, to: Int) -> Str {}"
  , "fn strCat(a: Str, b: Str) -> Str {}"
  , "fn strRepeat(s: Str, n: Int) -> Str {}"
  , "fn strIndexOf(s: Str, sub: Str) -> Int {}"
  , "fn strLastIndexOf(s: Str, sub: Str) -> Int {}"
  , "fn strContains(s: Str, sub: Str) -> Bool {}"
  , "fn startsWith(s: Str, p: Str) -> Bool {}"
  , "fn endsWith(s: Str, p: Str) -> Bool {}"
  , "fn strSplit(s: Str, sep: Str) -> [Str] {}"
  , "fn strJoin(parts: [Str], sep: Str) -> Str {}"
  , "fn strReplace(s: Str, from: Str, to: Str) -> Str {}"
  , "fn trim(s: Str) -> Str {}"
  , "fn trimLeft(s: Str) -> Str {}"
  , "fn trimRight(s: Str) -> Str {}"
  , "fn upper(s: Str) -> Str {}"
  , "fn lower(s: Str) -> Str {}"
  , "fn strCmp(a: Str, b: Str) -> Int {}"
  , "fn chars(s: Str) -> [Char] {}"
  , "fn strOfChars(cs: [Char]) -> Str {}"
  , "fn strReverse(s: Str) -> Str {}"
  , "fn quoteStr(s: Str) -> Str {}"
  , "fn padLeft(s: Str, width: Int, c: Char) -> Str {}"
  , "fn padRight(s: Str, width: Int, c: Char) -> Str {}"
  , "fn listNew<T>() -> [T] {}"
  , "fn listLen<T>(xs: [T]) -> Int {}"
  , "fn push<T>(xs: [T], x: T) {}"
  , "fn pop<T>(xs: [T]) -> T {}"
  , "fn insert<T>(xs: [T], i: Int, x: T) {}"
  , "fn removeAt<T>(xs: [T], i: Int) -> T {}"
  , "fn clear<T>(xs: [T]) {}"
  , "fn listRepeat<T>(x: T, n: Int) -> [T] {}"
  , "fn listConcat<T>(a: [T], b: [T]) -> [T] {}"
  , "fn slice<T>(xs: [T], from: Int, to: Int) -> [T] {}"
  , "fn listCopy<T>(xs: [T]) -> [T] {}"
  , "fn reverseList<T>(xs: [T]) -> [T] {}"
  , "fn listFirst<T>(xs: [T]) -> T {}"
  , "fn listLast<T>(xs: [T]) -> T {}"
  , "fn listMap<T, U>(xs: [T], f: fn(T) -> U) -> [U] {}"
  , "fn listFilter<T>(xs: [T], f: fn(T) -> Bool) -> [T] {}"
  , "fn listFold<T, A>(xs: [T], init: A, f: fn(A, T) -> A) -> A {}"
  , "fn listAny<T>(xs: [T], f: fn(T) -> Bool) -> Bool {}"
  , "fn listAll<T>(xs: [T], f: fn(T) -> Bool) -> Bool {}"
  , "fn listFind<T>(xs: [T], f: fn(T) -> Bool) -> Option<T> {}"
  , "fn listFindIndex<T>(xs: [T], f: fn(T) -> Bool) -> Int {}"
  , "fn listIndexOf<T: Eq>(xs: [T], x: T) -> Int {}"
  , "fn listContains<T: Eq>(xs: [T], x: T) -> Bool {}"
  , "fn listZip<A, B>(a: [A], b: [B]) -> [(A, B)] {}"
  , "fn listFlatten<T>(xss: [[T]]) -> [T] {}"
  , "fn sortBy<T>(xs: [T], cmp: fn(T, T) -> Int) -> [T] {}"
  , "fn mapNew<K: Key, V>() -> #[K: V] {}"
  , "fn mapLen<K: Key, V>(m: #[K: V]) -> Int {}"
  , "fn mapHas<K: Key, V>(m: #[K: V], k: K) -> Bool {}"
  , "fn mapGet<K: Key, V>(m: #[K: V], k: K) -> Option<V> {}"
  , "fn mapGetOr<K: Key, V>(m: #[K: V], k: K, dflt: V) -> V {}"
  , "fn mapSet<K: Key, V>(m: #[K: V], k: K, v: V) {}"
  , "fn mapDel<K: Key, V>(m: #[K: V], k: K) -> Bool {}"
  , "fn keysOf<K: Key, V>(m: #[K: V]) -> [K] {}"
  , "fn valuesOf<K: Key, V>(m: #[K: V]) -> [V] {}"
  , "fn pairsOf<K: Key, V>(m: #[K: V]) -> [(K, V)] {}"
  , "fn mapClear<K: Key, V>(m: #[K: V]) {}"
  , "fn mapCopy<K: Key, V>(m: #[K: V]) -> #[K: V] {}"
  , "fn isSome<T>(o: Option<T>) -> Bool {}"
  , "fn isNone<T>(o: Option<T>) -> Bool {}"
  , "fn unwrap<T>(o: Option<T>) -> T {}"
  , "fn unwrapOr<T>(o: Option<T>, dflt: T) -> T {}"
  , "fn isOk<T, E>(r: Result<T, E>) -> Bool {}"
  , "fn isErr<T, E>(r: Result<T, E>) -> Bool {}"
  , "fn unwrapOk<T, E>(r: Result<T, E>) -> T {}"
  , "fn unwrapErr<T, E>(r: Result<T, E>) -> E {}"
  , "fn fst<A, B>(t: (A, B)) -> A {}"
  , "fn snd<A, B>(t: (A, B)) -> B {}"
  , "fn fmt(template: Str, args: [Str]) -> Str {}"
  ]
