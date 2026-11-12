(ns sqlitefile.bytes
  "Low-level readers for the big-endian integers and varints of the SQLite
  file format. All functions take a `byte[]` and an absolute offset and throw
  an `ArrayIndexOutOfBoundsException` when reading past the end."
  (:refer-clojure :exclude [bytes]))

(set! *warn-on-reflection* true)

(defn u8
  "Unsigned byte at offset `i`."
  ^long [^bytes b ^long i]
  (bit-and 0xff (long (aget b i))))

(defn u16
  "Big-endian unsigned 16-bit integer at offset `i`."
  ^long [^bytes b ^long i]
  (bit-or (bit-shift-left (u8 b i) 8) (u8 b (inc i))))

(defn u32
  "Big-endian unsigned 32-bit integer at offset `i`."
  ^long [^bytes b ^long i]
  (bit-or (bit-shift-left (u16 b i) 16) (u16 b (+ i 2))))

(defn signed
  "Big-endian two's-complement integer of `n` bytes (1..8) at offset `i`."
  ^long [^bytes b ^long i ^long n]
  (loop [k 0
         acc (if (neg? (aget b i)) -1 0)]
    (if (= k n)
      acc
      (recur (inc k)
             (bit-or (bit-shift-left acc 8) (u8 b (+ i k)))))))

(defn varint
  "Decode the SQLite varint at offset `i` as a signed 64-bit integer. The
  first eight bytes contribute seven bits each; a ninth byte contributes all
  eight."
  ^long [^bytes b ^long i]
  (loop [k 0
         acc 0]
    (let [x (u8 b (+ i k))]
      (cond
        (= k 8) (bit-or (bit-shift-left acc 8) x)
        (< x 0x80) (bit-or (bit-shift-left acc 7) x)
        :else (recur (inc k)
                     (bit-or (bit-shift-left acc 7) (bit-and x 0x7f)))))))

(defn varint-size
  "Number of bytes (1..9) occupied by the varint at offset `i`."
  ^long [^bytes b ^long i]
  (loop [k 0]
    (cond
      (= k 8) 9
      (< (u8 b (+ i k)) 0x80) (inc k)
      :else (recur (inc k)))))

(defn encode-varint
  "Encode the signed 64-bit integer `n` as a SQLite varint, returning a
  `byte[]`. Mainly useful for building test fixtures."
  ^bytes [^long n]
  (if (or (neg? n) (>= n 0x0100000000000000))
    ;; nine bytes: eight groups of seven bits, then a full low byte
    (let [out (byte-array 9)]
      (aset out 8 (unchecked-byte (bit-and n 0xff)))
      (loop [k 7 v (unsigned-bit-shift-right n 8)]
        (when (>= k 0)
          (aset out k (unchecked-byte (bit-or 0x80 (bit-and v 0x7f))))
          (recur (dec k) (unsigned-bit-shift-right v 7))))
      out)
    (let [groups (loop [v n acc ()]
                   (let [acc (cons (bit-and v 0x7f) acc)
                         v' (unsigned-bit-shift-right v 7)]
                     (if (zero? v') acc (recur v' acc))))
          cnt (count groups)]
      (byte-array (map-indexed (fn [i g]
                                 (unchecked-byte (if (< i (dec cnt)) (bit-or g 0x80) g)))
                               groups)))))
