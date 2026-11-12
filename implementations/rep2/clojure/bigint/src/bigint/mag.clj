(ns bigint.mag
  "Unsigned magnitude arithmetic: the engine room of the library.

  A magnitude is a `long[]` holding the value in base 10^9, least significant
  limb first. Every limb is in [0, 10^9). Magnitudes are *normalised*: there
  are no high zero limbs, so zero is the empty array. All functions here
  accept and return normalised magnitudes and never mutate their arguments.

  A decimal base makes parsing and printing linear in the number of digits.
  Limb products (< 10^18) and the sums formed from them fit a signed 64-bit
  long, which is the only integer type used below.

  This is an implementation namespace; most callers want `bigint.core`."
  (:import (java.util Arrays)))

(set! *warn-on-reflection* true)

(def ^:const base
  "The limb radix, 10^9."
  1000000000)

(def ^:const base-digits
  "Decimal digits per limb."
  9)

(def ^longs zero
  "The magnitude of zero: an empty limb array."
  (long-array 0))

(defn trim
  "Return `a` without high zero limbs (`a` itself when already normalised)."
  ^"[J" [^longs a]
  (let [n (alength a)]
    (loop [k n]
      (cond
        (and (pos? k) (zero? (aget a (dec k)))) (recur (dec k))
        (== k n) a
        :else (Arrays/copyOf a (int k))))))

(defn zero-mag?
  "True when magnitude `a` is zero."
  [^longs a]
  (zero? (alength a)))

(defn from-long
  "Magnitude of the absolute value of long `x`. Safe for Long/MIN_VALUE."
  ^"[J" [^long x]
  (let [out (long-array 3)]
    (loop [v x, i 0]
      (if (zero? v)
        (trim out)
        (do (aset out i (Math/abs (rem v base)))
            (recur (quot v base) (inc i)))))))

(defn parse
  "Parse the ASCII digits in `s` between `start` (inclusive) and `end`
  (exclusive) into a magnitude. Leading zeros are allowed. Linear time.
  Throws ex-info if a character is not a digit."
  ^"[J" [^CharSequence s ^long start ^long end]
  (let [len (- end start)
        n   (quot (+ len (dec base-digits)) base-digits)
        out (long-array n)]
    (dotimes [i n]
      (let [hi (- end (* i base-digits))
            lo (max start (- hi base-digits))]
        (aset out i
              (long
               (loop [p lo, acc 0]
                (if (< p hi)
                  (let [d (- (int (.charAt s p)) 48)]
                    (when (or (< d 0) (> d 9))
                      (throw (ex-info "Not a decimal digit"
                                      {:type ::bad-digit :index p})))
                    (recur (inc p) (+ (* acc 10) d)))
                  acc))))))
    (trim out)))

(defn ->digits
  "Decimal digits of magnitude `a`, without sign or leading zeros (\"0\" for
  zero). Linear time."
  ^String [^longs a]
  (let [n (alength a)]
    (if (zero? n)
      "0"
      (let [sb (StringBuilder. (int (* n base-digits)))]
        (.append sb (aget a (dec n)))
        (loop [i (- n 2)]
          (when (>= i 0)
            (let [s (Long/toString (aget a i))]
              (dotimes [_ (- base-digits (.length s))] (.append sb \0))
              (.append sb s))
            (recur (dec i))))
        (.toString sb)))))

(defn cmp
  "Three-way comparison of magnitudes: -1, 0 or 1."
  ^long [^longs a ^longs b]
  (let [n (alength a), m (alength b)]
    (cond
      (< n m) -1
      (> n m) 1
      :else (loop [i (dec n)]
              (if (neg? i)
                0
                (let [x (aget a i), y (aget b i)]
                  (cond (< x y) -1
                        (> x y) 1
                        :else (recur (dec i)))))))))

(defn add
  "a + b."
  ^"[J" [^longs a ^longs b]
  (let [[^longs a ^longs b] (if (>= (alength a) (alength b)) [a b] [b a])
        n   (alength a)
        m   (alength b)
        out (long-array (inc n))]
    (loop [i 0, carry 0]
      (if (< i n)
        (let [t (+ (aget a i) (if (< i m) (aget b i) 0) carry)]
          (if (>= t base)
            (do (aset out i (- t base)) (recur (inc i) 1))
            (do (aset out i t) (recur (inc i) 0))))
        (aset out n carry)))
    (trim out)))

(defn sub
  "a - b, where a >= b must hold."
  ^"[J" [^longs a ^longs b]
  (let [n   (alength a)
        m   (alength b)
        out (long-array n)]
    (loop [i 0, borrow 0]
      (when (< i n)
        (let [t (- (aget a i) (if (< i m) (aget b i) 0) borrow)]
          (if (neg? t)
            (do (aset out i (+ t base)) (recur (inc i) 1))
            (do (aset out i t) (recur (inc i) 0))))))
    (trim out)))

(defn mul-small
  "a * d for a limb-sized multiplier 0 <= d < base."
  ^"[J" [^longs a ^long d]
  (let [n   (alength a)
        out (long-array (inc n))]
    (loop [i 0, carry 0]
      (if (< i n)
        (let [t (+ (* (aget a i) d) carry)
              c (quot t base)]
          (aset out i (- t (* c base)))
          (recur (inc i) c))
        (aset out n carry)))
    (trim out)))

(defn mul
  "a * b by schoolbook long multiplication, O(n*m)."
  ^"[J" [^longs a ^longs b]
  (let [n (alength a)
        m (alength b)]
    (if (or (zero? n) (zero? m))
      zero
      (let [out (long-array (+ n m))]
        (dotimes [i n]
          (let [ai (aget a i)]
            (when-not (zero? ai)
              ;; out[i+m] is untouched by earlier rows, so the final carry
              ;; is stored rather than added.
              (loop [j 0, carry 0]
                (if (< j m)
                  (let [k (+ i j)
                        t (+ (aget out k) (* ai (aget b j)) carry)
                        c (quot t base)]
                    (aset out k (- t (* c base)))
                    (recur (inc j) c))
                  (aset out (+ i m) carry))))))
        (trim out)))))

(defn divmod-small
  "Divide `a` by a limb-sized divisor 0 < d < base. Returns [quotient
  remainder], the remainder being a long."
  [^longs a ^long d]
  (let [n (alength a)
        q (long-array n)]
    (loop [i (dec n), r 0]
      (if (>= i 0)
        (let [cur (+ (* r base) (aget a i))
              qi  (quot cur d)]
          (aset q i qi)
          (recur (dec i) (- cur (* qi d))))
        [(trim q) r]))))

(defn- divmod-knuth
  "Knuth's Algorithm D for a divisor of at least two limbs, a >= b."
  [^longs u ^longs v]
  (let [n    (alength v)
        ulen (alength u)
        m    (- ulen n)
        ;; D1: normalise so the top divisor limb is >= base/2.
        d    (quot base (inc (aget v (dec n))))
        ^longs vn (mul-small v d)
        ^longs un (Arrays/copyOf ^longs (mul-small u d) (int (inc ulen)))
        vtop (aget vn (dec n))
        vsec (aget vn (- n 2))
        q    (long-array (inc m))]
    ;; D2-D7: one quotient limb per iteration, from the top.
    (loop [j m]
      (when (>= j 0)
        (let [num   (+ (* (aget un (+ j n)) base) (aget un (+ j n -1)))
              qh0   (quot num vtop)
              rh0   (- num (* qh0 vtop))
              ;; D3: estimate, then correct using the second limb.
              qhat  (long
                     (loop [qh qh0, rh rh0]
                      (if (or (>= qh base)
                              (> (* qh vsec)
                                 (+ (* rh base) (aget un (+ j n -2)))))
                        (let [rh' (+ rh vtop)]
                          (if (>= rh' base)
                            (dec qh)
                            (recur (dec qh) rh')))
                        qh)))
              ;; D4: multiply and subtract.
              top   (long
                     (loop [i 0, borrow 0, carry 0]
                      (if (< i n)
                        (let [p  (+ (* qhat (aget vn i)) carry)
                              c  (quot p base)
                              t  (- (aget un (+ i j)) (- p (* c base)) borrow)]
                          (if (neg? t)
                            (do (aset un (+ i j) (+ t base)) (recur (inc i) 1 c))
                            (do (aset un (+ i j) t) (recur (inc i) 0 c))))
                        (- (aget un (+ j n)) carry borrow))))]
          (if (neg? top)
            ;; D6: the estimate was one too large; add the divisor back.
            (let [carry (long
                         (loop [i 0, carry 0]
                          (if (< i n)
                            (let [t (+ (aget un (+ i j)) (aget vn i) carry)]
                              (if (>= t base)
                                (do (aset un (+ i j) (- t base)) (recur (inc i) 1))
                                (do (aset un (+ i j) t) (recur (inc i) 0))))
                            carry)))]
              (aset un (+ j n) (+ top carry))
              (aset q j (dec qhat)))
            (do (aset un (+ j n) top)
                (aset q j qhat)))
          (recur (dec j)))))
    ;; D8: un-normalise the remainder.
    (let [r (trim (Arrays/copyOf un (int n)))]
      [(trim q) (if (zero? (alength r)) r (first (divmod-small r d)))])))

(defn divmod
  "Divide magnitude `a` by `b`, returning [quotient remainder] with
  a = q*b + r and 0 <= r < b. Knuth's Algorithm D, O((n-m+1)*m).
  Throws ArithmeticException when `b` is zero."
  [^longs a ^longs b]
  (let [n (alength b)]
    (cond
      (zero? n)           (throw (ArithmeticException. "Divide by zero"))
      (neg? (cmp a b))    [zero a]
      (== n 1)            (let [[q r] (divmod-small a (aget b 0))]
                            [q (from-long r)])
      :else               (divmod-knuth a b))))

(defn pow
  "a^e for a long exponent e >= 0, by binary exponentiation (left to right),
  using schoolbook multiplication."
  ^"[J" [^longs a ^long e]
  (if (zero? e)
    (from-long 1)
    (loop [bit (- 63 (Long/numberOfLeadingZeros e)), acc (from-long 1)]
      (if (neg? bit)
        acc
        (let [sq (mul acc acc)
              nx (if (bit-test e bit) (mul sq a) sq)]
          (recur (dec bit) nx))))))

(defn even-mag?
  "True when magnitude `a` is even (zero is even). The radix is even, so the
  lowest limb decides."
  [^longs a]
  (or (zero? (alength a)) (even? (aget a 0))))
