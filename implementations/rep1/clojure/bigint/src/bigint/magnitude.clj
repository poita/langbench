(ns bigint.magnitude
  "Low-level arithmetic on unsigned magnitudes.

  A magnitude is a `long[]` of limbs in base 10^9, least-significant limb
  first. A *normalised* magnitude has no most-significant zero limbs; zero is
  the empty array. Every function here takes and returns normalised
  magnitudes. Base 10^9 keeps decimal parsing and printing linear while every
  intermediate product (< 10^18 + carries) still fits in a signed 64-bit long.

  This is an implementation namespace; most callers want `bigint.core`."
  (:refer-clojure :exclude [compare zero?]))

(set! *warn-on-reflection* true)
(set! *unchecked-math* :warn-on-boxed)

(def ^:const base
  "The limb base, 10^9."
  1000000000)

(def ^:const base-digits
  "Number of decimal digits per limb."
  9)

(def ^longs zero
  "The magnitude of zero: an empty limb array."
  (long-array 0))

(defn zero?
  "True if magnitude `a` is zero."
  [^longs a]
  (== 0 (alength a)))

(defn trim
  "Returns `a` without most-significant zero limbs (`a` itself if already
  normalised)."
  ^longs [^longs a]
  (let [n (alength a)]
    (loop [k n]
      (cond
        (== k 0) zero
        (== 0 (aget a (dec k))) (recur (dec k))
        (== k n) a
        :else (java.util.Arrays/copyOf a (int k))))))

(defn ^longs from-long
  "Magnitude of a non-negative long."
  [^long n]
  (cond
    (== n 0) zero
    (< n base) (doto (long-array 1) (aset 0 n))
    (< n (* base base)) (doto (long-array 2)
                          (aset 0 (rem n base))
                          (aset 1 (quot n base)))
    :else (doto (long-array 3)
            (aset 0 (rem n base))
            (aset 1 (rem (quot n base) base))
            (aset 2 (quot n (* base base))))))

(defn to-long
  "The value of magnitude `a` as a long, or nil if it does not fit in 18
  decimal digits (two limbs)."
  [^longs a]
  (case (alength a)
    0 0
    1 (aget a 0)
    2 (+ (aget a 0) (* base (aget a 1)))
    nil))

(defn compare
  "Three-way comparison of two magnitudes: -1, 0 or 1."
  ^long [^longs a ^longs b]
  (let [na (alength a) nb (alength b)]
    (cond
      (< na nb) -1
      (> na nb) 1
      :else (loop [i (dec na)]
              (if (< i 0)
                0
                (let [x (aget a i) y (aget b i)]
                  (cond (< x y) -1
                        (> x y) 1
                        :else (recur (dec i)))))))))

(defn add
  "a + b."
  ^longs [^longs a ^longs b]
  (let [[^longs a ^longs b] (if (>= (alength a) (alength b)) [a b] [b a])
        na (alength a) nb (alength b)
        r (long-array (inc na))]
    (loop [i 0 carry 0]
      (if (< i na)
        (let [s (+ (aget a i) (if (< i nb) (aget b i) 0) carry)]
          (if (>= s base)
            (do (aset r i (- s base)) (recur (inc i) 1))
            (do (aset r i s) (recur (inc i) 0))))
        (aset r na carry)))
    (trim r)))

(defn sub
  "a - b, for a >= b."
  ^longs [^longs a ^longs b]
  (let [na (alength a) nb (alength b)
        r (long-array na)]
    (loop [i 0 borrow 0]
      (when (< i na)
        (let [d (- (aget a i) (if (< i nb) (aget b i) 0) borrow)]
          (if (< d 0)
            (do (aset r i (+ d base)) (recur (inc i) 1))
            (do (aset r i d) (recur (inc i) 0))))))
    (trim r)))

(defn mul
  "a * b by schoolbook long multiplication, O(n*m)."
  ^longs [^longs a ^longs b]
  (let [na (alength a) nb (alength b)]
    (if (or (== na 0) (== nb 0))
      zero
      (let [r (long-array (+ na nb))]
        (loop [i 0]
          (when (< i na)
            (let [ai (aget a i)]
              (loop [j 0 carry 0]
                (if (< j nb)
                  (let [cur (+ (aget r (+ i j)) (* ai (aget b j)) carry)]
                    (aset r (+ i j) (rem cur base))
                    (recur (inc j) (quot cur base)))
                  ;; r[i+nb] has not been written by earlier rows.
                  (aset r (+ i nb) carry))))
            (recur (inc i))))
        (trim r)))))

(defn ^longs mul-small
  "a * k for 0 <= k < base."
  [^longs a ^long k]
  (let [na (alength a)]
    (if (or (== na 0) (== k 0))
      zero
      (let [r (long-array (inc na))]
        (loop [i 0 carry 0]
          (if (< i na)
            (let [cur (+ (* (aget a i) k) carry)]
              (aset r i (rem cur base))
              (recur (inc i) (quot cur base)))
            (aset r na carry)))
        (trim r)))))

(defn quot-rem-small
  "Divides `a` by a single-limb divisor 0 < d < base. Returns [quotient
  remainder] where the remainder is a long."
  [^longs a ^long d]
  (let [n (alength a)
        q (long-array n)]
    (loop [i (dec n) rem-acc 0]
      (if (< i 0)
        [(trim q) rem-acc]
        (let [cur (+ (* rem-acc base) (aget a i))]
          (aset q i (quot cur d))
          (recur (dec i) (rem cur d)))))))

(defn- knuth-d
  "Knuth's Algorithm D for a divisor of at least two limbs and a dividend at
  least as long as the divisor."
  [^longs u ^longs v]
  (let [n (alength v)
        m (- (alength u) n)
        ;; D1: normalise so the divisor's top limb is >= base/2.
        d (quot base (inc (aget v (dec n))))
        ^longs vn (mul-small v d)
        ^longs un (let [r (long-array (inc (alength u)))
                        ^longs t (mul-small u d)]
             (System/arraycopy t 0 r 0 (alength t))
             r)
        q (long-array (inc m))
        v1 (aget vn (dec n))
        v2 (aget vn (- n 2))]
    ;; D2-D7: one quotient limb per iteration.
    (loop [j m]
      (when (>= j 0)
        (let [num (+ (* (aget un (+ j n)) base) (aget un (+ j n -1)))
              ;; D3: estimate qhat from the top two limbs, then correct it
              ;; using the third (at most two decrements).
              qhat (long (loop [qhat (quot num v1)
                          rhat (rem num v1)]
                     (if (and (or (>= qhat base)
                                  (> (* qhat v2)
                                     (+ (* rhat base) (aget un (+ j n -2))))))
                       (let [rhat' (+ rhat v1)]
                         (if (>= rhat' base)
                           (dec qhat)
                           (recur (dec qhat) rhat')))
                       qhat)))
              ;; D4: multiply and subtract qhat * vn from un[j .. j+n].
              top (long (loop [i 0 carry 0 borrow 0]
                    (if (< i n)
                      (let [p (+ (* qhat (aget vn i)) carry)
                            s (- (aget un (+ i j)) (rem p base) borrow)]
                        (if (< s 0)
                          (do (aset un (+ i j) (+ s base))
                              (recur (inc i) (quot p base) 1))
                          (do (aset un (+ i j) s)
                              (recur (inc i) (quot p base) 0))))
                      (- (aget un (+ j n)) carry borrow))))
              ;; D5/D6: if the result went negative, qhat was one too big;
              ;; add the divisor back.
              qhat (if (< top 0)
                     (do
                       (aset un (+ j n)
                             (+ top
                                (long (loop [i 0 carry 0]
                                  (if (< i n)
                                    (let [s (+ (aget un (+ i j)) (aget vn i) carry)]
                                      (if (>= s base)
                                        (do (aset un (+ i j) (- s base)) (recur (inc i) 1))
                                        (do (aset un (+ i j) s) (recur (inc i) 0))))
                                    carry)))))
                       (dec qhat))
                     (do (aset un (+ j n) top) qhat))]
          (aset q j qhat)
          (recur (dec j)))))
    ;; D8: un-normalise the remainder.
    (let [r (trim (java.util.Arrays/copyOf un (int n)))
          [r _] (quot-rem-small r d)]
      [(trim q) r])))

(defn quot-rem
  "Truncating division of magnitudes. Returns [quotient remainder]. The
  divisor must be non-zero; throws `ArithmeticException` otherwise."
  [^longs u ^longs v]
  (let [nv (alength v)]
    (cond
      (== nv 0) (throw (ArithmeticException. "Divide by zero"))
      (< (compare u v) 0) [zero u]
      (== nv 1) (let [[q r] (quot-rem-small u (aget v 0))]
                  [q (from-long r)])
      :else (knuth-d u v))))

(defn ^longs pow
  "a raised to the non-negative long power `e`, by left-to-right binary
  exponentiation (squarings and multiplications are schoolbook)."
  [^longs a ^long e]
  (if (== e 0)
    (from-long 1)
    (loop [bit (dec (- 63 (Long/numberOfLeadingZeros e)))
           acc a]
      (if (< bit 0)
        acc
        (let [sq (mul acc acc)]
          (recur (dec bit)
                 (if (bit-test e bit) (mul sq a) sq)))))))
