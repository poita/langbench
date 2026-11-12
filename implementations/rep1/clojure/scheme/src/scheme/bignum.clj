(ns scheme.bignum
  "Classical arbitrary-precision magnitude arithmetic.

  A magnitude is a little-endian `long[]` of base-2^31 limbs (each in
  [0, 2^31)) with no most-significant zero limbs; zero is the empty array.
  Base 2^31 keeps every limb product, plus carries, inside a signed long.

  Algorithms: schoolbook multiplication, Knuth's Algorithm D (TAOCP 4.3.1)
  for division, and repeated division by 10^9 for decimal output. Signs and
  the Long/Bignum split live in `scheme.number`."
  (:import [java.util Arrays]))

(set! *warn-on-reflection* true)

(def ^:const ^long limb-bits 31)
(def ^:const ^long base 0x80000000)
(def ^:const ^long mask 0x7FFFFFFF)

(def ^longs zero-mag (long-array 0))

(defn trim
  "Drop most-significant zero limbs."
  ^longs [^longs a]
  (let [n (loop [n (alength a)]
            (if (and (pos? n) (zero? (aget a (dec n)))) (recur (dec n)) n))]
    (if (== n (alength a)) a (Arrays/copyOf a (int n)))))

(defn long->mag
  "Magnitude of |x|, for any long `x` (including Long/MIN_VALUE)."
  ^longs [^long x]
  (let [u (if (neg? x) (unchecked-negate x) x)] ; unsigned 64-bit value
    (trim (doto (long-array 3)
            (aset 0 (bit-and u mask))
            (aset 1 (bit-and (unsigned-bit-shift-right u 31) mask))
            (aset 2 (unsigned-bit-shift-right u 62))))))

(defn mag-cmp
  "-1, 0 or 1 as magnitude `a` is less than, equal to or greater than `b`."
  ^long [^longs a ^longs b]
  (let [la (alength a) lb (alength b)]
    (cond
      (< la lb) -1
      (> la lb) 1
      :else (loop [i (dec la)]
              (if (neg? i)
                0
                (let [x (aget a i) y (aget b i)]
                  (cond (== x y) (recur (dec i))
                        (< x y) -1
                        :else 1)))))))

(defn mag-add ^longs [^longs a ^longs b]
  (if (< (alength a) (alength b))
    (mag-add b a)
    (let [la (alength a) lb (alength b)
          r (long-array (inc la))]
      (loop [i 0 carry 0]
        (if (< i la)
          (let [s (+ (aget a i) (if (< i lb) (aget b i) 0) carry)]
            (aset r i (bit-and s mask))
            (recur (inc i) (unsigned-bit-shift-right s 31)))
          (aset r la carry)))
      (trim r))))

(defn mag-sub
  "a - b, requiring a >= b."
  ^longs [^longs a ^longs b]
  (let [la (alength a) lb (alength b)
        r (long-array la)]
    (loop [i 0 borrow 0]
      (when (< i la)
        (let [d (- (aget a i) (if (< i lb) (aget b i) 0) borrow)]
          (if (neg? d)
            (do (aset r i (+ d base)) (recur (inc i) 1))
            (do (aset r i d) (recur (inc i) 0))))))
    (trim r)))

(defn- mul-row!
  "Add ai * b into r starting at limb offset i."
  [^longs r ^longs b ^long ai ^long i]
  (let [lb (alength b)]
    (loop [j 0 carry 0]
      (if (< j lb)
        (let [t (+ (* ai (aget b j)) (aget r (+ i j)) carry)]
          (aset r (+ i j) (bit-and t mask))
          (recur (inc j) (unsigned-bit-shift-right t 31)))
        (aset r (+ i lb) carry)))))

(defn mag-mul
  "Schoolbook multiplication, O(n*m)."
  ^longs [^longs a ^longs b]
  (let [la (alength a) lb (alength b)]
    (if (or (zero? la) (zero? lb))
      zero-mag
      (let [r (long-array (+ la lb))]
        (loop [i 0]
          (when (< i la)
            (mul-row! r b (aget a i) i)
            (recur (inc i))))
        (trim r)))))

(defn mag-divmod-small
  "Divide magnitude `a` by the single limb `d` (0 < d < 2^31).
  Returns [quotient remainder-as-long]."
  [^longs a ^long d]
  (let [q (long-array (alength a))]
    (loop [i (dec (alength a)) r 0]
      (if (neg? i)
        [(trim q) r]
        (let [cur (+ (bit-shift-left r 31) (aget a i))]
          (aset q i (quot cur d))
          (recur (dec i) (rem cur d)))))))

(defn- shift-left-limbs
  "Copy of `a` shifted left by s (< 31) bits, as an array of `len` limbs."
  ^longs [^longs a ^long s ^long len]
  (let [r (long-array len) la (alength a)]
    (loop [i 0]
      (when (< i len)
        (let [hi (if (< i la) (aget a i) 0)
              lo (if (and (pos? i) (<= i la)) (aget a (dec i)) 0)]
          (aset r i (bit-and (bit-or (bit-shift-left hi s)
                                     (unsigned-bit-shift-right lo (- 31 s)))
                             mask))
          (recur (inc i)))))
    r))

(defn- estimate-qhat
  "Knuth's trial quotient digit for position j, corrected against the top two
  divisor limbs."
  [^longs u vn1 vn2 j n]
  (let [vn1 (long vn1) vn2 (long vn2) j (long j) n (long n)
        num (+ (bit-shift-left (aget u (+ j n)) 31) (aget u (+ j n -1)))
        u2 (aget u (+ j n -2))]
    (loop [qh (quot num vn1) rh (rem num vn1)]
      (if (or (>= qh base)
              (> (* qh vn2) (+ (bit-shift-left rh 31) u2)))
        (let [qh (dec qh) rh (+ rh vn1)]
          (if (< rh base) (recur qh rh) qh))
        qh))))

(defn- mul-sub!
  "u[j..j+n] -= qhat * v; returns the final (signed) top limb before masking."
  [^longs u ^longs v qhat j n]
  (let [qhat (long qhat) j (long j) n (long n)
        k (loop [i 0 k 0]
            (if (< i n)
              (let [p (* qhat (aget v i))
                    t (- (aget u (+ i j)) k (bit-and p mask))]
                (aset u (+ i j) (bit-and t mask))
                (recur (inc i) (- (unsigned-bit-shift-right p 31)
                                  (bit-shift-right t 31))))
              k))
        t (- (aget u (+ j n)) k)]
    (aset u (+ j n) (bit-and t mask))
    t))

(defn- add-back! [^longs u ^longs v ^long j ^long n]
  (let [c (loop [i 0 c 0]
            (if (< i n)
              (let [s (+ (aget u (+ i j)) (aget v i) c)]
                (aset u (+ i j) (bit-and s mask))
                (recur (inc i) (unsigned-bit-shift-right s 31)))
              c))]
    (aset u (+ j n) (bit-and (+ (aget u (+ j n)) c) mask))))

(defn mag-divmod
  "Knuth Algorithm D. Returns [quotient remainder] of magnitudes; `b` must be
  non-zero. O((n - m + 1) * m)."
  [^longs a ^longs b]
  (let [la (alength a) n (alength b)]
    (cond
      (neg? (mag-cmp a b)) [zero-mag a]
      (== n 1) (let [[q r] (mag-divmod-small a (aget b 0))]
                 [q (long->mag r)])
      :else
      (let [m (- la n)
            s (- (Long/numberOfLeadingZeros (aget b (dec n))) 33)
            ^longs v (shift-left-limbs b s n)
            ^longs u (shift-left-limbs a s (inc la))
            q (long-array (inc m))
            vn1 (aget v (dec n))
            vn2 (aget v (- n 2))]
        (loop [j m]
          (when (>= j 0)
            (let [qhat (long (estimate-qhat u vn1 vn2 j n))
                  t (long (mul-sub! u v qhat j n))]
              (if (neg? t)
                (do (add-back! u v j n)
                    (aset q j (dec qhat)))
                (aset q j qhat))
              (recur (dec j)))))
        ;; remainder: the low n limbs of u, shifted back right by s
        (let [r (long-array n)]
          (dotimes [i n]
            (aset r i (bit-and (bit-or (unsigned-bit-shift-right (aget u i) s)
                                       (bit-shift-left (aget u (inc i)) (- 31 s)))
                               mask)))
          [(trim q) (trim r)])))))

;; ---------------------------------------------------------------------------
;; Decimal conversion

(def ^:private ^:const ^long chunk-digits 9)
(def ^:private ^:const ^long chunk-base 1000000000)

(defn mag->string
  "Decimal digits of a magnitude (\"0\" for zero), by repeated division by
  10^9: O(n^2)."
  ^String [^longs a]
  (if (zero? (alength a))
    "0"
    (let [w (aclone a)
          sb (StringBuilder.)
          chunks (java.util.ArrayList.)]
      (loop [len (alength w)]
        (when (pos? len)
          (let [r (loop [i (dec len) r 0]
                    (if (neg? i)
                      r
                      (let [cur (+ (bit-shift-left r 31) (aget w i))]
                        (aset w i (quot cur chunk-base))
                        (recur (dec i) (rem cur chunk-base)))))
                len (long (loop [l len] (if (and (pos? l) (zero? (aget w (dec l)))) (recur (dec l)) l)))]
            (.add chunks r)
            (recur len))))
      (let [k (.size chunks)]
        (.append sb (long (.get chunks (dec k))))
        (loop [i (- k 2)]
          (when (>= i 0)
            (let [s (str (long (.get chunks i)))]
              (dotimes [_ (- chunk-digits (count s))] (.append sb \0))
              (.append sb s))
            (recur (dec i)))))
      (.toString sb))))

(defn digits->mag
  "Magnitude of a string of ASCII decimal digits, in O(n^2)."
  ^longs [^String digits]
  (let [nd (.length digits)
        w (long-array (+ 2 (quot (* nd 4) 31)))]
    (loop [pos 0 len 0]
      (if (< pos nd)
        (let [end (min nd (+ pos chunk-digits))
              mult (loop [k (- end pos) m 1] (if (zero? k) m (recur (dec k) (* m 10))))
              c (loop [i pos acc 0]
                  (if (< i end)
                    (recur (inc i) (+ (* acc 10) (- (int (.charAt digits i)) 48)))
                    acc))
              ;; w = w * mult + c
              len (long (loop [i 0 carry c]
                    (if (< i len)
                      (let [t (+ (* (aget w i) mult) carry)]
                        (aset w i (bit-and t mask))
                        (recur (inc i) (unsigned-bit-shift-right t 31)))
                      (if (pos? carry)
                        (do (aset w len (long carry)) (inc len))
                        len))))]
          (recur end len))
        (trim w)))))
