(ns langvm.stdlib
  "The 132 built-in functions of the prelude (SPEC section 15).

  [[table]] is a vector of `[name signature implementation]` in a fixed order;
  a built-in's id is its index.  The signature is the text that follows the
  name in a `fn` declaration and is parsed by the same front end as user code,
  so the checker treats built-ins exactly like user functions.  An
  implementation takes the calling machine (an `ICaller`, used by the
  higher-order built-ins) followed by the arguments."
  (:require [langvm.numfmt :as numfmt]
            [langvm.runtime :as rt :refer [panic vstr str-of UNIT]])
  (:import (java.nio.charset StandardCharsets)
           (java.util ArrayList LinkedHashMap Map$Entry)
           (langvm.runtime VStr Rec Closure ICaller)))

(set! *warn-on-reflection* true)

(def ^:dynamic *vm-out* nil)

(defn- write-str [^VStr s]
  (.write ^java.io.OutputStream *vm-out* (.getBytes (str-of s) StandardCharsets/UTF_8)))

;; ---------------------------------------------------------------------------
;; helpers

(defmacro ^:private bi [name sig args & body]
  `[~name ~sig (fn [~(with-meta 'm {:tag 'langvm.runtime.ICaller}) ~@args] ~@body)])

(defn- call1 [^ICaller m f a] (.call m f (object-array [a])))
(defn- call2 [^ICaller m f a b] (.call m f (object-array [a b])))

(defn- bool-of [x] (boolean x))


(defn- sref ^String [v] (.s ^VStr v))
(defn- slen ^long [v] (.len ^VStr v))
(defn- bmp? [v] (.bmp ^VStr v))

(defn- scalar-at ^long [^VStr s ^long i]
  (if (.bmp s)
    (long (int (.charAt (sref s) (int i))))
    (let [str (sref s)] (long (.codePointAt str (.offsetByCodePoints str 0 (int i)))))))

(defn- sub-str [^VStr s ^long from ^long to]
  (if (.bmp s)
    (vstr (.substring (sref s) (int from) (int to)))
    (let [str (sref s)]
      (vstr (.substring str (.offsetByCodePoints str 0 (int from))
                        (.offsetByCodePoints str 0 (int to)))))))

(defn- cp->str ^String [^long c] (String. (Character/toChars (int c))))

(defn- ascii-space? [^long c] (or (== c 32) (<= 9 c 13)))

(defn- char-index->count
  "Scalar index corresponding to UTF-16 index `j` of `s`."
  ^long [^VStr s ^long j]
  (if (.bmp s) j (long (.codePointCount (sref s) 0 (int j)))))

(defn- escape-scalar [^StringBuilder sb ^long c ^long quote]
  (cond
    (== c 92) (.append sb "\\\\")
    (== c quote) (do (.append sb "\\") (.append sb (char c)))
    (== c 10) (.append sb "\\n")
    (== c 13) (.append sb "\\r")
    (== c 9) (.append sb "\\t")
    (or (< c 32) (== c 127)) (.append sb (str "\\u{" (Long/toHexString c) "}"))
    :else (.appendCodePoint sb (int c))))

(defn- floor-trunc ^double [^double x]
  (if (neg? x) (Math/ceil x) (Math/floor x)))

(defn- index-check [^long i ^long n]
  (when (or (< i 0) (>= i n)) (panic "index out of bounds")))

(defn- cmp-float ^long [^double a ^double b]
  (cond
    (Double/isNaN a) (if (Double/isNaN b) 0 1)
    (Double/isNaN b) -1
    (< a b) -1
    (> a b) 1
    :else 0))

(defn- fmod ^double [^double a ^double b]
  (cond
    (or (Double/isNaN a) (Double/isNaN b) (zero? b) (Double/isInfinite a)) Double/NaN
    (Double/isInfinite b) a
    (zero? a) a
    :else
    (let [r (.doubleValue (.remainder (java.math.BigDecimal. a) (java.math.BigDecimal. b)))]
      (if (zero? r) (Math/copySign 0.0 a) r))))

(defn- pow-float ^double [^double x ^long n]
  (loop [r 1.0, b x, k n]
    (if (> k 0)
      (let [r (if (== 1 (bit-and k 1)) (* r b) r)
            k (bit-shift-right k 1)
            b (if (> k 0) (* b b) b)]
        (recur r b k))
      r)))

(defn- merge-sort [^ICaller m ^ArrayList xs f]
  (let [n (.size xs)
        src (.toArray xs)]
    (if (<= n 1)
      (ArrayList. ^java.util.Collection (java.util.Arrays/asList src))
      (loop [^objects src src, ^objects dst (object-array n), width 1]
        (if (< width n)
          (do
            (loop [i 0]
              (when (< i n)
                (let [mid (min (+ i width) n)
                      hi (min (+ i (* 2 width)) n)]
                  (loop [a i, b mid, k i]
                    (cond
                      (and (< a mid) (< b hi))
                      (if (<= (long (call2 m f (aget src a) (aget src b))) 0)
                        (do (aset dst k (aget src a)) (recur (inc a) b (inc k)))
                        (do (aset dst k (aget src b)) (recur a (inc b) (inc k))))
                      (< a mid) (do (aset dst k (aget src a)) (recur (inc a) b (inc k)))
                      (< b hi) (do (aset dst k (aget src b)) (recur a (inc b) (inc k)))))
                  (recur (+ i (* 2 width))))))
            (recur dst src (* 2 width)))
          (ArrayList. ^java.util.Collection (java.util.Arrays/asList src)))))))

(defn- fmt-impl [^VStr template ^ArrayList args]
  (let [t (sref template) n (.length t) sb (StringBuilder.)]
    (loop [i 0, used 0]
      (if (< i n)
        (let [c (.charAt t i)]
          (cond
            (= c \{)
            (let [d (if (< (inc i) n) (.charAt t (inc i)) \space)]
              (cond
                (= d \{) (do (.append sb \{) (recur (+ i 2) used))
                (= d \}) (do (when (< used (.size args)) (.append sb (sref (.get args used))))
                             (recur (+ i 2) (inc used)))
                :else (panic "bad format")))
            (= c \})
            (if (and (< (inc i) n) (= \} (.charAt t (inc i))))
              (do (.append sb \}) (recur (+ i 2) used))
              (panic "bad format"))
            :else (do (.append sb c) (recur (inc i) used))))
        (do (when-not (== used (.size args)) (panic "bad format"))
            (vstr (str sb)))))))

(defn- opt [x] (if (nil? x) rt/none (rt/some-of x)))

;; ---------------------------------------------------------------------------

(def table
  [;; ---- output --------------------------------------------------------
   (bi "print" "(s: Str)" [s] (write-str s) (.write ^java.io.OutputStream *vm-out* 10) UNIT)
   (bi "emit" "(s: Str)" [s] (write-str s) UNIT)
   (bi "panic" "(msg: Str)" [s] (panic (sref s)))

   ;; ---- integers ------------------------------------------------------
   (bi "intMin" "() -> Int" [] Long/MIN_VALUE)
   (bi "intMax" "() -> Int" [] Long/MAX_VALUE)
   (bi "absI" "(x: Int) -> Int" [x] (let [x (long x)] (if (neg? x) (unchecked-negate x) x)))
   (bi "minI" "(a: Int, b: Int) -> Int" [a b] (min (long a) (long b)))
   (bi "maxI" "(a: Int, b: Int) -> Int" [a b] (max (long a) (long b)))
   (bi "signI" "(x: Int) -> Int" [x] (Long/signum (long x)))
   (bi "cmpI" "(a: Int, b: Int) -> Int" [a b] (Long/compare (long a) (long b)))
   (bi "divFloor" "(a: Int, b: Int) -> Int" [a b]
       (if (zero? (long b)) (panic "divide by zero") (Math/floorDiv (long a) (long b))))
   (bi "modFloor" "(a: Int, b: Int) -> Int" [a b]
       (if (zero? (long b)) (panic "modulo by zero") (Math/floorMod (long a) (long b))))
   (bi "powI" "(base: Int, exp: Int) -> Int" [b e]
       (let [e (long e)]
         (when (neg? e) (panic "negative exponent"))
         (loop [r 1, b (long b), k e]
           (if (> k 0)
             (recur (if (== 1 (bit-and k 1)) (unchecked-multiply r b) r)
                    (unchecked-multiply b b)
                    (bit-shift-right k 1))
             r))))
   (bi "gcdI" "(a: Int, b: Int) -> Int" [a b]
       (.longValue (.gcd (java.math.BigInteger/valueOf (long a)) (java.math.BigInteger/valueOf (long b)))))
   (bi "popCount" "(x: Int) -> Int" [x] (long (Long/bitCount (long x))))
   (bi "clz" "(x: Int) -> Int" [x] (long (Long/numberOfLeadingZeros (long x))))
   (bi "ctz" "(x: Int) -> Int" [x] (long (Long/numberOfTrailingZeros (long x))))
   (bi "toFloat" "(x: Int) -> Float" [x] (double (long x)))
   (bi "showInt" "(x: Int) -> Str" [x] (vstr (Long/toString (long x))))
   (bi "showIntRadix" "(x: Int, radix: Int) -> Str" [x r]
       (let [r (long r)]
         (when-not (<= 2 r 36) (panic "radix out of range"))
         (vstr (numfmt/show-int-radix (long x) r))))
   (bi "parseInt" "(s: Str) -> Option<Int>" [s] (opt (numfmt/parse-int-radix (sref s) 10)))
   (bi "parseIntRadix" "(s: Str, radix: Int) -> Option<Int>" [s r]
       (let [r (long r)]
         (when-not (<= 2 r 36) (panic "radix out of range"))
         (opt (numfmt/parse-int-radix (sref s) r))))

   ;; ---- floats --------------------------------------------------------
   (bi "sqrtF" "(x: Float) -> Float" [x] (Math/sqrt (double x)))
   (bi "absF" "(x: Float) -> Float" [x] (Math/abs (double x)))
   (bi "floorF" "(x: Float) -> Float" [x] (Math/floor (double x)))
   (bi "ceilF" "(x: Float) -> Float" [x] (Math/ceil (double x)))
   (bi "truncF" "(x: Float) -> Float" [x] (floor-trunc (double x)))
   (bi "roundF" "(x: Float) -> Float" [x]
       (let [x (double x)]
         (if (or (Double/isNaN x) (Double/isInfinite x) (zero? x))
           x
           (let [a (Math/abs x)
                 t (Math/floor a)
                 r (if (>= (- a t) 0.5) (+ t 1.0) t)]
             (Math/copySign r x)))))
   (bi "minF" "(a: Float, b: Float) -> Float" [a b] (if (<= (cmp-float (double a) (double b)) 0) a b))
   (bi "maxF" "(a: Float, b: Float) -> Float" [a b] (if (>= (cmp-float (double a) (double b)) 0) a b))
   (bi "fmodF" "(a: Float, b: Float) -> Float" [a b] (fmod (double a) (double b)))
   (bi "powF" "(x: Float, n: Int) -> Float" [x n]
       (let [n (long n)]
         (cond
           (>= n 0) (pow-float (double x) n)
           (== n Long/MIN_VALUE) (panic "negative exponent")
           :else (/ 1.0 (pow-float (double x) (- n))))))
   (bi "isNanF" "(x: Float) -> Bool" [x] (Double/isNaN (double x)))
   (bi "isInfF" "(x: Float) -> Bool" [x] (Double/isInfinite (double x)))
   (bi "cmpF" "(a: Float, b: Float) -> Int" [a b] (cmp-float (double a) (double b)))
   (bi "truncToInt" "(x: Float) -> Int" [x]
       (let [x (double x)]
         (when (or (Double/isNaN x) (Double/isInfinite x)) (panic "float out of integer range"))
         (let [t (floor-trunc x)]
           (if (and (>= t -9.223372036854775808E18) (< t 9.223372036854775808E18))
             (long t)
             (panic "float out of integer range")))))
   (bi "showFloat" "(x: Float) -> Str" [x] (vstr (numfmt/show-float-at (double x) 6)))
   (bi "showFloatAt" "(x: Float, digits: Int) -> Str" [x d]
       (let [d (long d)]
         (when-not (<= 0 d 17) (panic "digits out of range"))
         (vstr (numfmt/show-float-at (double x) d))))
   (bi "floatBits" "(x: Float) -> Int" [x] (Double/doubleToRawLongBits (double x)))
   (bi "floatFromBits" "(bits: Int) -> Float" [b] (Double/longBitsToDouble (long b)))
   (bi "parseFloat" "(s: Str) -> Option<Float>" [s] (opt (numfmt/parse-float (sref s))))
   (bi "infF" "() -> Float" [] Double/POSITIVE_INFINITY)
   (bi "nanF" "() -> Float" [] (Double/longBitsToDouble 0x7ff8000000000000))
   (bi "piF" "() -> Float" [] (Double/longBitsToDouble 4614256656552045848))

   ;; ---- bools and chars -------------------------------------------------
   (bi "showBool" "(b: Bool) -> Str" [b] (vstr (if b "true" "false")))
   (bi "ord" "(c: Char) -> Int" [c] (long (int c)))
   (bi "chr" "(n: Int) -> Char" [n]
       (let [n (long n)]
         (when (or (< n 0) (> n 0x10FFFF) (<= 0xD800 n 0xDFFF)) (panic "invalid char code"))
         (Integer/valueOf (int n))))
   (bi "isDigit" "(c: Char) -> Bool" [c] (<= 48 (int c) 57))
   (bi "isAlpha" "(c: Char) -> Bool" [c] (let [c (int c)] (or (<= 65 c 90) (<= 97 c 122))))
   (bi "isAlnum" "(c: Char) -> Bool" [c] (let [c (int c)] (or (<= 48 c 57) (<= 65 c 90) (<= 97 c 122))))
   (bi "isSpace" "(c: Char) -> Bool" [c] (ascii-space? (int c)))
   (bi "isUpper" "(c: Char) -> Bool" [c] (<= 65 (int c) 90))
   (bi "isLower" "(c: Char) -> Bool" [c] (<= 97 (int c) 122))
   (bi "toUpperC" "(c: Char) -> Char" [c] (let [x (int c)] (if (<= 97 x 122) (Integer/valueOf (int (- x 32))) c)))
   (bi "toLowerC" "(c: Char) -> Char" [c] (let [x (int c)] (if (<= 65 x 90) (Integer/valueOf (int (+ x 32))) c)))
   (bi "cmpC" "(a: Char, b: Char) -> Int" [a b] (long (Integer/compare (int a) (int b))))
   (bi "showChar" "(c: Char) -> Str" [c] (vstr (cp->str (int c))))
   (bi "quoteChar" "(c: Char) -> Str" [c]
       (let [sb (StringBuilder. "'")]
         (escape-scalar sb (int c) 39)
         (.append sb "'")
         (vstr (str sb))))

   ;; ---- strings ---------------------------------------------------------
   (bi "strLen" "(s: Str) -> Int" [s] (slen s))
   (bi "charAt" "(s: Str, i: Int) -> Char" [s i]
       (index-check (long i) (slen s))
       (Integer/valueOf (int (scalar-at s (long i)))))
   (bi "substr" "(s: Str, from: Int, to: Int) -> Str" [s a b]
       (let [a (long a) b (long b)]
         (when-not (and (<= 0 a) (<= a b) (<= b (slen s))) (panic "index out of bounds"))
         (sub-str s a b)))
   (bi "strCat" "(a: Str, b: Str) -> Str" [a b] (vstr (str (sref a) (sref b))))
   (bi "strRepeat" "(s: Str, n: Int) -> Str" [s n]
       (let [n (long n)]
         (when (neg? n) (panic "negative count"))
         (vstr (.repeat (sref s) (int n)))))
   (bi "strIndexOf" "(s: Str, sub: Str) -> Int" [s sub]
       (let [j (.indexOf (sref s) (sref sub))] (if (neg? j) -1 (char-index->count s j))))
   (bi "strLastIndexOf" "(s: Str, sub: Str) -> Int" [s sub]
       (let [j (.lastIndexOf (sref s) (sref sub))] (if (neg? j) -1 (char-index->count s j))))
   (bi "strContains" "(s: Str, sub: Str) -> Bool" [s sub] (.contains (sref s) (sref sub)))
   (bi "startsWith" "(s: Str, p: Str) -> Bool" [s p] (.startsWith (sref s) (sref p)))
   (bi "endsWith" "(s: Str, p: Str) -> Bool" [s p] (.endsWith (sref s) (sref p)))
   (bi "strSplit" "(s: Str, sep: Str) -> [Str]" [s sep]
       (let [t (sref s) p (sref sep) out (ArrayList.)]
         (when (.isEmpty p) (panic "empty separator"))
         (loop [start 0]
           (let [j (.indexOf t p (int start))]
             (if (neg? j)
               (.add out (vstr (.substring t start)))
               (do (.add out (vstr (.substring t start j)))
                   (recur (+ j (.length p)))))))
         out))
   (bi "strJoin" "(parts: [Str], sep: Str) -> Str" [parts sep]
       (let [^ArrayList parts parts sb (StringBuilder.) p (sref sep) n (.size parts)]
         (dotimes [i n]
           (when (pos? i) (.append sb p))
           (.append sb (sref (.get parts i))))
         (vstr (str sb))))
   (bi "strReplace" "(s: Str, from: Str, to: Str) -> Str" [s from to]
       (let [t (sref s) f (sref from) r (sref to)]
         (when (.isEmpty f) (panic "empty separator"))
         (let [sb (StringBuilder.)]
           (loop [start 0]
             (let [j (.indexOf t f (int start))]
               (if (neg? j)
                 (.append sb (.substring t start))
                 (do (.append sb (.substring t start j)) (.append sb r)
                     (recur (+ j (.length f)))))))
           (vstr (str sb)))))
   (bi "trim" "(s: Str) -> Str" [s]
       (let [t (sref s)
             n (.length t)
             a (loop [i 0] (if (and (< i n) (ascii-space? (int (.charAt t i)))) (recur (inc i)) i))
             b (loop [j n] (if (and (> j a) (ascii-space? (int (.charAt t (dec j))))) (recur (dec j)) j))]
         (vstr (.substring t a b))))
   (bi "trimLeft" "(s: Str) -> Str" [s]
       (let [t (sref s) n (.length t)
             a (loop [i 0] (if (and (< i n) (ascii-space? (int (.charAt t i)))) (recur (inc i)) i))]
         (vstr (.substring t a))))
   (bi "trimRight" "(s: Str) -> Str" [s]
       (let [t (sref s)
             b (loop [j (.length t)] (if (and (> j 0) (ascii-space? (int (.charAt t (dec j))))) (recur (dec j)) j))]
         (vstr (.substring t 0 b))))
   (bi "upper" "(s: Str) -> Str" [s]
       (let [t (sref s) sb (StringBuilder. (.length t))]
         (dotimes [i (.length t)]
           (let [c (.charAt t i)] (.append sb (if (<= 97 (int c) 122) (char (- (int c) 32)) c))))
         (vstr (str sb))))
   (bi "lower" "(s: Str) -> Str" [s]
       (let [t (sref s) sb (StringBuilder. (.length t))]
         (dotimes [i (.length t)]
           (let [c (.charAt t i)] (.append sb (if (<= 65 (int c) 90) (char (+ (int c) 32)) c))))
         (vstr (str sb))))
   (bi "strCmp" "(a: Str, b: Str) -> Int" [a b] (rt/str-compare a b))
   (bi "chars" "(s: Str) -> [Char]" [s]
       (let [out (ArrayList.)]
         (.forEach (.codePoints (sref s)) (reify java.util.function.IntConsumer
                                            (accept [_ c] (.add out (Integer/valueOf (int c))))))
         out))
   (bi "strOfChars" "(cs: [Char]) -> Str" [cs]
       (let [^ArrayList cs cs sb (StringBuilder.)]
         (dotimes [i (.size cs)] (.appendCodePoint sb (int (.get cs i))))
         (vstr (str sb))))
   (bi "strReverse" "(s: Str) -> Str" [s] (vstr (str (.reverse (StringBuilder. (sref s))))))
   (bi "quoteStr" "(s: Str) -> Str" [s]
       (let [sb (StringBuilder. "\"")]
         (.forEach (.codePoints (sref s)) (reify java.util.function.IntConsumer
                                            (accept [_ c] (escape-scalar sb c 34))))
         (.append sb "\"")
         (vstr (str sb))))
   (bi "padLeft" "(s: Str, width: Int, c: Char) -> Str" [s w c]
       (let [w (long w)]
         (when (neg? w) (panic "negative count"))
         (let [k (- w (slen s))]
           (if (<= k 0) s (vstr (str (.repeat ^String (cp->str (int c)) (int k)) (sref s)))))))
   (bi "padRight" "(s: Str, width: Int, c: Char) -> Str" [s w c]
       (let [w (long w)]
         (when (neg? w) (panic "negative count"))
         (let [k (- w (slen s))]
           (if (<= k 0) s (vstr (str (sref s) (.repeat ^String (cp->str (int c)) (int k))))))))

   ;; ---- lists -----------------------------------------------------------
   (bi "listNew" "<T>() -> [T]" [] (ArrayList.))
   (bi "listLen" "<T>(xs: [T]) -> Int" [xs] (long (.size ^ArrayList xs)))
   (bi "push" "<T>(xs: [T], x: T)" [xs x] (.add ^ArrayList xs x) UNIT)
   (bi "pop" "<T>(xs: [T]) -> T" [xs]
       (let [^ArrayList xs xs n (.size xs)]
         (when (zero? n) (panic "empty list"))
         (.remove xs (dec n))))
   (bi "insert" "<T>(xs: [T], i: Int, x: T)" [xs i x]
       (let [^ArrayList xs xs i (long i)]
         (when-not (<= 0 i (.size xs)) (panic "index out of bounds"))
         (.add xs (int i) x)
         UNIT))
   (bi "removeAt" "<T>(xs: [T], i: Int) -> T" [xs i]
       (let [^ArrayList xs xs i (long i)]
         (index-check i (.size xs))
         (.remove xs (int i))))
   (bi "clear" "<T>(xs: [T])" [xs] (.clear ^ArrayList xs) UNIT)
   (bi "listRepeat" "<T>(x: T, n: Int) -> [T]" [x n]
       (let [n (long n)]
         (when (neg? n) (panic "negative count"))
         (let [out (ArrayList. (int n))]
           (dotimes [_ n] (.add out x))
           out)))
   (bi "listConcat" "<T>(a: [T], b: [T]) -> [T]" [a b]
       (let [out (ArrayList. ^java.util.Collection a)] (.addAll out ^java.util.Collection b) out))
   (bi "slice" "<T>(xs: [T], from: Int, to: Int) -> [T]" [xs a b]
       (let [^ArrayList xs xs a (long a) b (long b)]
         (when-not (and (<= 0 a) (<= a b) (<= b (.size xs))) (panic "index out of bounds"))
         (ArrayList. (.subList xs (int a) (int b)))))
   (bi "listCopy" "<T>(xs: [T]) -> [T]" [xs] (ArrayList. ^java.util.Collection xs))
   (bi "reverseList" "<T>(xs: [T]) -> [T]" [xs]
       (let [out (ArrayList. ^java.util.Collection xs)] (java.util.Collections/reverse out) out))
   (bi "listFirst" "<T>(xs: [T]) -> T" [xs]
       (let [^ArrayList xs xs] (when (.isEmpty xs) (panic "empty list")) (.get xs 0)))
   (bi "listLast" "<T>(xs: [T]) -> T" [xs]
       (let [^ArrayList xs xs] (when (.isEmpty xs) (panic "empty list")) (.get xs (dec (.size xs)))))
   (bi "listMap" "<T, U>(xs: [T], f: fn(T) -> U) -> [U]" [xs f]
       (let [^ArrayList xs xs out (ArrayList.)]
         (loop [i 0]
           (when (< i (.size xs))
             (.add out (call1 m f (.get xs i)))
             (recur (inc i))))
         out))
   (bi "listFilter" "<T>(xs: [T], f: fn(T) -> Bool) -> [T]" [xs f]
       (let [^ArrayList xs xs out (ArrayList.)]
         (loop [i 0]
           (when (< i (.size xs))
             (let [x (.get xs i)]
               (when (call1 m f x) (.add out x)))
             (recur (inc i))))
         out))
   (bi "listFold" "<T, A>(xs: [T], init: A, f: fn(A, T) -> A) -> A" [xs init f]
       (let [^ArrayList xs xs]
         (loop [i 0, acc init]
           (if (< i (.size xs))
             (recur (inc i) (call2 m f acc (.get xs i)))
             acc))))
   (bi "listAny" "<T>(xs: [T], f: fn(T) -> Bool) -> Bool" [xs f]
       (let [^ArrayList xs xs]
         (loop [i 0]
           (cond (>= i (.size xs)) false
                 (call1 m f (.get xs i)) true
                 :else (recur (inc i))))))
   (bi "listAll" "<T>(xs: [T], f: fn(T) -> Bool) -> Bool" [xs f]
       (let [^ArrayList xs xs]
         (loop [i 0]
           (cond (>= i (.size xs)) true
                 (call1 m f (.get xs i)) (recur (inc i))
                 :else false))))
   (bi "listFind" "<T>(xs: [T], f: fn(T) -> Bool) -> Option<T>" [xs f]
       (let [^ArrayList xs xs]
         (loop [i 0]
           (if (>= i (.size xs))
             rt/none
             (let [x (.get xs i)]
               (if (call1 m f x) (rt/some-of x) (recur (inc i))))))))
   (bi "listFindIndex" "<T>(xs: [T], f: fn(T) -> Bool) -> Int" [xs f]
       (let [^ArrayList xs xs]
         (loop [i 0]
           (cond (>= i (.size xs)) -1
                 (call1 m f (.get xs i)) (long i)
                 :else (recur (inc i))))))
   (bi "listIndexOf" "<T: Eq>(xs: [T], x: T) -> Int" [xs x]
       (let [^ArrayList xs xs n (.size xs)]
         (loop [i 0]
           (cond (>= i n) -1
                 (rt/veq (.get xs i) x) (long i)
                 :else (recur (inc i))))))
   (bi "listContains" "<T: Eq>(xs: [T], x: T) -> Bool" [xs x]
       (let [^ArrayList xs xs n (.size xs)]
         (loop [i 0]
           (cond (>= i n) false
                 (rt/veq (.get xs i) x) true
                 :else (recur (inc i))))))
   (bi "listZip" "<A, B>(a: [A], b: [B]) -> [(A, B)]" [a b]
       (let [^ArrayList a a ^ArrayList b b n (min (.size a) (.size b)) out (ArrayList. n)]
         (dotimes [i n] (.add out (object-array [(.get a i) (.get b i)])))
         out))
   (bi "listFlatten" "<T>(xss: [[T]]) -> [T]" [xss]
       (let [^ArrayList xss xss out (ArrayList.)]
         (loop [i 0]
           (when (< i (.size xss))
             (.addAll out ^java.util.Collection (.get xss i))
             (recur (inc i))))
         out))
   (bi "sortBy" "<T>(xs: [T], cmp: fn(T, T) -> Int) -> [T]" [xs f] (merge-sort m xs f))

   ;; ---- maps ------------------------------------------------------------
   (bi "mapNew" "<K: Key, V>() -> #[K: V]" [] (LinkedHashMap.))
   (bi "mapLen" "<K: Key, V>(m: #[K: V]) -> Int" [mp] (long (.size ^LinkedHashMap mp)))
   (bi "mapHas" "<K: Key, V>(m: #[K: V], k: K) -> Bool" [mp k] (.containsKey ^LinkedHashMap mp k))
   (bi "mapGet" "<K: Key, V>(m: #[K: V], k: K) -> Option<V>" [mp k]
       (let [^LinkedHashMap mp mp v (.get mp k)] (if (nil? v) rt/none (rt/some-of v))))
   (bi "mapGetOr" "<K: Key, V>(m: #[K: V], k: K, dflt: V) -> V" [mp k d]
       (let [v (.get ^LinkedHashMap mp k)] (if (nil? v) d v)))
   (bi "mapSet" "<K: Key, V>(m: #[K: V], k: K, v: V)" [mp k v] (.put ^LinkedHashMap mp k v) UNIT)
   (bi "mapDel" "<K: Key, V>(m: #[K: V], k: K) -> Bool" [mp k]
       (let [^LinkedHashMap mp mp] (if (.containsKey mp k) (do (.remove mp k) true) false)))
   (bi "keysOf" "<K: Key, V>(m: #[K: V]) -> [K]" [mp] (ArrayList. (.keySet ^LinkedHashMap mp)))
   (bi "valuesOf" "<K: Key, V>(m: #[K: V]) -> [V]" [mp] (ArrayList. (.values ^LinkedHashMap mp)))
   (bi "pairsOf" "<K: Key, V>(m: #[K: V]) -> [(K, V)]" [mp]
       (let [out (ArrayList.)]
         (doseq [^Map$Entry e (.entrySet ^LinkedHashMap mp)]
           (.add out (object-array [(.getKey e) (.getValue e)])))
         out))
   (bi "mapClear" "<K: Key, V>(m: #[K: V])" [mp] (.clear ^LinkedHashMap mp) UNIT)
   (bi "mapCopy" "<K: Key, V>(m: #[K: V]) -> #[K: V]" [mp] (LinkedHashMap. ^java.util.Map mp))

   ;; ---- Option, Result, tuples -------------------------------------------
   (bi "isSome" "<T>(o: Option<T>) -> Bool" [o] (== 0 (.vi ^Rec o)))
   (bi "isNone" "<T>(o: Option<T>) -> Bool" [o] (== 1 (.vi ^Rec o)))
   (bi "unwrap" "<T>(o: Option<T>) -> T" [o]
       (let [^Rec o o] (if (== 0 (.vi o)) (aget ^objects (.f o) 0) (panic "unwrap of None"))))
   (bi "unwrapOr" "<T>(o: Option<T>, dflt: T) -> T" [o d]
       (let [^Rec o o] (if (== 0 (.vi o)) (aget ^objects (.f o) 0) d)))
   (bi "isOk" "<T, E>(r: Result<T, E>) -> Bool" [r] (== 0 (.vi ^Rec r)))
   (bi "isErr" "<T, E>(r: Result<T, E>) -> Bool" [r] (== 1 (.vi ^Rec r)))
   (bi "unwrapOk" "<T, E>(r: Result<T, E>) -> T" [r]
       (let [^Rec r r] (if (== 0 (.vi r)) (aget ^objects (.f r) 0) (panic "unwrap of Err"))))
   (bi "unwrapErr" "<T, E>(r: Result<T, E>) -> E" [r]
       (let [^Rec r r] (if (== 1 (.vi r)) (aget ^objects (.f r) 0) (panic "unwrap of Ok"))))
   (bi "fst" "<A, B>(t: (A, B)) -> A" [t] (aget ^objects t 0))
   (bi "snd" "<A, B>(t: (A, B)) -> B" [t] (aget ^objects t 1))

   ;; ---- formatting --------------------------------------------------------
   (bi "fmt" "(template: Str, args: [Str]) -> Str" [t args] (fmt-impl t args))])

(def names
  "Built-in names in table order."
  (mapv first table))

(def signatures
  "`[name signature-text]` for each built-in, in table order."
  (mapv (fn [[n sig _]] [n (str n sig)]) table))

(def impls
  "Implementation functions in table order, as an array for O(1) dispatch."
  (object-array (map #(nth % 2) table)))

(defn lookup
  "The implementation function of built-in `name` (taking the machine as its
  first argument), or nil."
  [name]
  (when-let [i (first (keep-indexed (fn [i n] (when (= n name) i)) names))]
    (aget ^objects impls i)))
