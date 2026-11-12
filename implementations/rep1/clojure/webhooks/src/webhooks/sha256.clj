(ns webhooks.sha256
  "SHA-256 (FIPS 180-4), implemented from scratch.

  All 32-bit words are held in `long`s in the range [0, 2^32)."
  )

(set! *warn-on-reflection* true)
(set! *unchecked-math* :warn-on-boxed)

(def ^:private ^"[J" initial-state
  (long-array [0x6a09e667 0xbb67ae85 0x3c6ef372 0xa54ff53a
               0x510e527f 0x9b05688c 0x1f83d9ab 0x5be0cd19]))

(def ^:private ^"[J" k
  (long-array
   [0x428a2f98 0x71374491 0xb5c0fbcf 0xe9b5dba5 0x3956c25b 0x59f111f1 0x923f82a4 0xab1c5ed5
    0xd807aa98 0x12835b01 0x243185be 0x550c7dc3 0x72be5d74 0x80deb1fe 0x9bdc06a7 0xc19bf174
    0xe49b69c1 0xefbe4786 0x0fc19dc6 0x240ca1cc 0x2de92c6f 0x4a7484aa 0x5cb0a9dc 0x76f988da
    0x983e5152 0xa831c66d 0xb00327c8 0xbf597fc7 0xc6e00bf3 0xd5a79147 0x06ca6351 0x14292967
    0x27b70a85 0x2e1b2138 0x4d2c6dfc 0x53380d13 0x650a7354 0x766a0abb 0x81c2c92e 0x92722c85
    0xa2bfe8a1 0xa81a664b 0xc24b8b70 0xc76c51a3 0xd192e819 0xd6990624 0xf40e3585 0x106aa070
    0x19a4c116 0x1e376c08 0x2748774c 0x34b0bcb5 0x391c0cb3 0x4ed8aa4a 0x5b9cca4f 0x682e6ff3
    0x748f82ee 0x78a5636f 0x84c87814 0x8cc70208 0x90befffa 0xa4506ceb 0xbef9a3f7 0xc67178f2]))

(defmacro ^:private ror
  "32-bit rotate right of `x` (already in [0, 2^32)) by constant `n`."
  [x n]
  `(let [x# ~x]
     (bit-and 0xffffffff
              (bit-or (unsigned-bit-shift-right x# ~n)
                      (bit-shift-left x# ~(- 32 (long n)))))))

(defn- compress!
  "Processes the 64-byte block of `buf` at `off`, updating state `h` in place.
  `w` is a 64-long scratch array."
  [^longs h ^longs w ^bytes buf ^long off]
  (dotimes [t 16]
    (let [i (+ off (* 4 t))]
      (aset w t (bit-or (bit-shift-left (bit-and (aget buf i) 0xff) 24)
                        (bit-shift-left (bit-and (aget buf (+ i 1)) 0xff) 16)
                        (bit-shift-left (bit-and (aget buf (+ i 2)) 0xff) 8)
                        (bit-and (aget buf (+ i 3)) 0xff)))))
  (loop [t 16]
    (when (< t 64)
      (let [w15 (aget w (- t 15))
            w2 (aget w (- t 2))
            s0 (bit-xor (ror w15 7) (ror w15 18) (unsigned-bit-shift-right w15 3))
            s1 (bit-xor (ror w2 17) (ror w2 19) (unsigned-bit-shift-right w2 10))]
        (aset w t (bit-and 0xffffffff (+ (aget w (- t 16)) s0 (aget w (- t 7)) s1)))
        (recur (inc t)))))
  (loop [t 0
         a (aget h 0) b (aget h 1) c (aget h 2) d (aget h 3)
         e (aget h 4) f (aget h 5) g (aget h 6) hh (aget h 7)]
    (if (< t 64)
      (let [s1 (bit-xor (ror e 6) (ror e 11) (ror e 25))
            ch (bit-xor (bit-and e f) (bit-and (bit-xor e 0xffffffff) g))
            temp1 (+ hh s1 ch (aget k t) (aget w t))
            s0 (bit-xor (ror a 2) (ror a 13) (ror a 22))
            maj (bit-xor (bit-and a b) (bit-and a c) (bit-and b c))
            temp2 (+ s0 maj)]
        (recur (inc t)
               (bit-and 0xffffffff (+ temp1 temp2)) a b c
               (bit-and 0xffffffff (+ d temp1)) e f g))
      (do
        (aset h 0 (bit-and 0xffffffff (+ (aget h 0) a)))
        (aset h 1 (bit-and 0xffffffff (+ (aget h 1) b)))
        (aset h 2 (bit-and 0xffffffff (+ (aget h 2) c)))
        (aset h 3 (bit-and 0xffffffff (+ (aget h 3) d)))
        (aset h 4 (bit-and 0xffffffff (+ (aget h 4) e)))
        (aset h 5 (bit-and 0xffffffff (+ (aget h 5) f)))
        (aset h 6 (bit-and 0xffffffff (+ (aget h 6) g)))
        (aset h 7 (bit-and 0xffffffff (+ (aget h 7) hh)))))))

(defn digest
  "Returns the 32-byte SHA-256 digest of byte array `msg`."
  ^bytes [^bytes msg]
  (let [len (alength msg)
        full (quot len 64)
        h (aclone initial-state)
        w (long-array 64)]
    (dotimes [i full]
      (compress! h w msg (* i 64)))
    ;; Final one or two blocks: remaining bytes, 0x80, zeros, 64-bit bit length.
    (let [rem (- len (* full 64))
          tail-len (if (< rem 56) 64 128)
          tail (byte-array tail-len)
          bits (* 8 (long len))]
      (System/arraycopy msg (* full 64) tail 0 rem)
      (aset tail rem (unchecked-byte 0x80))
      (dotimes [i 8]
        (aset tail (- tail-len 1 i)
              (unchecked-byte (unsigned-bit-shift-right bits (* 8 i)))))
      (compress! h w tail 0)
      (when (= tail-len 128)
        (compress! h w tail 64)))
    (let [out (byte-array 32)]
      (dotimes [i 8]
        (let [v (aget h i)]
          (dotimes [j 4]
            (aset out (+ (* 4 i) j)
                  (unchecked-byte (unsigned-bit-shift-right v (- 24 (* 8 j))))))))
      out)))
