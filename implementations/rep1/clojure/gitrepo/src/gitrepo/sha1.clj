(ns gitrepo.sha1
  "SHA-1 (FIPS 180-4), implemented from scratch."
  (:require [gitrepo.hex :as hex]))

(set! *warn-on-reflection* true)

(def ^:private ^:const mask 0xFFFFFFFF)

(defn- rotl ^long [^long x ^long n]
  (bit-and mask (bit-or (bit-shift-left x n) (unsigned-bit-shift-right x (- 32 n)))))

(defn- pad
  "The message followed by 0x80, zeros and the 64-bit big-endian bit length."
  ^bytes [^bytes data]
  (let [len (alength data)
        total (* 64 (quot (+ len 9 63) 64))
        buf (byte-array total)
        bits (* 8 len)]
    (System/arraycopy data 0 buf 0 len)
    (aset buf len (unchecked-byte 0x80))
    (dotimes [i 8]
      (aset buf (- total 1 i) (unchecked-byte (unsigned-bit-shift-right bits (* 8 i)))))
    buf))

(defn digest
  "The 20-byte SHA-1 digest of byte array `data`."
  ^bytes [^bytes data]
  (let [buf (pad data)
        nblocks (quot (alength buf) 64)
        w (long-array 80)
        h (long-array [0x67452301 0xEFCDAB89 0x98BADCFE 0x10325476 0xC3D2E1F0])]
    (dotimes [blk nblocks]
      (let [base (* blk 64)]
        (dotimes [t 16]
          (let [o (+ base (* 4 t))]
            (aset w t (bit-or (bit-shift-left (bit-and 0xff (aget buf o)) 24)
                              (bit-shift-left (bit-and 0xff (aget buf (+ o 1))) 16)
                              (bit-shift-left (bit-and 0xff (aget buf (+ o 2))) 8)
                              (bit-and 0xff (aget buf (+ o 3)))))))
        (loop [t 16]
          (when (< t 80)
            (aset w t (rotl (bit-xor (aget w (- t 3)) (aget w (- t 8))
                                     (aget w (- t 14)) (aget w (- t 16)))
                            1))
            (recur (inc t))))
        (let [[a b c d e]
              (loop [t 0
                     a (aget h 0) b (aget h 1) c (aget h 2) d (aget h 3) e (aget h 4)]
                (if (= t 80)
                  [a b c d e]
                  (let [f (cond (< t 20) (bit-or (bit-and b c) (bit-and (bit-xor b mask) d))
                                (< t 40) (bit-xor b c d)
                                (< t 60) (bit-or (bit-and b c) (bit-and b d) (bit-and c d))
                                :else (bit-xor b c d))
                        k (cond (< t 20) 0x5A827999
                                (< t 40) 0x6ED9EBA1
                                (< t 60) 0x8F1BBCDC
                                :else 0xCA62C1D6)
                        tmp (bit-and mask (+ (rotl a 5) f e k (aget w t)))]
                    (recur (inc t) tmp a (rotl b 30) c d))))]
          (aset h 0 (bit-and mask (+ (aget h 0) (long a))))
          (aset h 1 (bit-and mask (+ (aget h 1) (long b))))
          (aset h 2 (bit-and mask (+ (aget h 2) (long c))))
          (aset h 3 (bit-and mask (+ (aget h 3) (long d))))
          (aset h 4 (bit-and mask (+ (aget h 4) (long e)))))))
    (let [out (byte-array 20)]
      (dotimes [i 5]
        (let [v (aget h i)]
          (dotimes [j 4]
            (aset out (+ (* 4 i) j)
                  (unchecked-byte (unsigned-bit-shift-right v (* 8 (- 3 j))))))))
      out)))

(defn hex-digest
  "The SHA-1 of byte array `data` as 40 lowercase hex digits."
  ^String [^bytes data]
  (hex/bytes->hex (digest data)))
