(ns softfloat.oracle
  "Test-only reference implementation using the JVM's IEEE-754 hardware
  arithmetic.  The library itself never uses it.

  `Float/sum` is a true binary32 addition.  Products and quotients of two
  floats computed in double and narrowed once are correctly rounded (the
  product is exact in 53 bits; for quotients and square roots 53 >= 2*24+2
  makes the double rounding innocuous).")

(set! *warn-on-reflection* true)

(defn- bits->float ^double [^long bits]
  (double (Float/intBitsToFloat (unchecked-int bits))))

(defn- ->f ^double [^long bits] (bits->float bits))

(defn- canon
  "Bits of double `x` narrowed once to float, with every NaN mapped to the
  canonical quiet NaN."
  ^long [^double x]
  (let [fl (unchecked-float x)]
    (if (Float/isNaN fl)
      0x7fc00000
      (bit-and (long (Float/floatToRawIntBits fl)) 0xffffffff))))

(defn- fsum ^double [^long a ^long b]
  (double (Float/sum (unchecked-float (->f a)) (unchecked-float (->f b)))))

(defn add [^long a ^long b] (canon (fsum a b)))
(defn sub [^long a ^long b] (canon (fsum a (bit-xor b 0x80000000))))
(defn mul [^long a ^long b] (canon (* (->f a) (->f b))))
(defn div [^long a ^long b] (canon (/ (->f a) (->f b))))
(defn sqrt [^long a] (canon (Math/sqrt (->f a))))
