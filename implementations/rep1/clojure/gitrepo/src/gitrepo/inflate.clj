(ns gitrepo.inflate
  "A zlib (RFC 1950) / DEFLATE (RFC 1951) decoder written from scratch.

  `inflate` decodes one zlib stream that starts at a given offset of a byte
  array and reports where the DEFLATE data ended, so streams stored back to
  back can be walked without knowing their compressed length."
  (:require [gitrepo.error :as err]))

(set! *warn-on-reflection* true)

(defn- damaged [msg]
  (err/fail :damaged (str "inflate: " msg)))

;; Decoder state lives in a long array: [pos bitbuf bitcnt outlen]; the output
;; buffer lives in a one-element object array so it can grow.
(defn- take-bits
  "Reads `need` (0-16) bits, least significant first."
  ^long [^longs st ^bytes in ^long need]
  (let [len (alength in)]
    (loop [buf (aget st 1) cnt (aget st 2) pos (aget st 0)]
      (if (< cnt need)
        (do (when (>= pos len) (damaged "unexpected end of input"))
            (recur (bit-or buf (bit-shift-left (bit-and 0xff (aget in pos)) cnt))
                   (+ cnt 8) (inc pos)))
        (do (aset st 0 pos)
            (aset st 1 (unsigned-bit-shift-right buf need))
            (aset st 2 (- cnt need))
            (bit-and buf (dec (bit-shift-left 1 need))))))))

(defrecord ^:private Huffman [^longs cnt ^longs sym])

(defn- construct
  "Builds a canonical Huffman decoding table from the code lengths
  `lengths[off .. off+n)`. Returns [table left] where `left` is negative for
  an over-subscribed code and positive for an incomplete one."
  [^longs lengths ^long off ^long n]
  (let [cnt (long-array 16)
        sym (long-array (max n 1))]
    (dotimes [i n]
      (let [l (aget lengths (+ off i))]
        (aset cnt l (inc (aget cnt l)))))
    (if (= (aget cnt 0) n)
      [(->Huffman cnt sym) 0]
      (let [left (loop [len 1 left 1]
                   (if (> len 15)
                     left
                     (let [left (- (* 2 left) (aget cnt len))]
                       (if (< left 0) left (recur (inc len) left)))))]
        (if (< left 0)
          [nil left]
          (let [offs (long-array 16)]
            (loop [len 1]
              (when (< len 15)
                (aset offs (inc len) (+ (aget offs len) (aget cnt len)))
                (recur (inc len))))
            (dotimes [s n]
              (let [l (aget lengths (+ off s))]
                (when-not (zero? l)
                  (aset sym (aget offs l) s)
                  (aset offs l (inc (aget offs l))))))
            [(->Huffman cnt sym) left]))))))

(defn- decode
  "Decodes one symbol using canonical code `h`, a bit at a time."
  ^long [^longs st ^bytes in ^Huffman h]
  (let [cnt ^longs (.cnt h)
        sym ^longs (.sym h)]
    (loop [len 1 code 0 first 0 index 0]
      (let [code (bit-or code (take-bits st in 1))
            c (aget cnt len)]
        (if (< (- code c) first)
          (aget sym (+ index (- code first)))
          (if (= len 15)
            (damaged "invalid Huffman code")
            (recur (inc len)
                   (bit-shift-left code 1)
                   (bit-shift-left (+ first c) 1)
                   (+ index c))))))))

(defn- ensure-capacity
  ^bytes [^longs st ^objects ob ^long extra]
  (let [^bytes out (aget ob 0)
        need (+ (aget st 3) extra)]
    (if (> need (alength out))
      (do (when (> need (- Integer/MAX_VALUE 16)) (damaged "output too large"))
          (let [n (byte-array (min (- Integer/MAX_VALUE 16) (max need (* 2 (alength out)))))]
            (System/arraycopy out 0 n 0 (int (aget st 3)))
            (aset ob 0 n)
            n))
      out)))

(def ^:private ^"[J" length-base
  (long-array [3 4 5 6 7 8 9 10 11 13 15 17 19 23 27 31 35 43 51 59 67 83 99 115 131 163 195 227 258]))
(def ^:private ^"[J" length-extra
  (long-array [0 0 0 0 0 0 0 0 1 1 1 1 2 2 2 2 3 3 3 3 4 4 4 4 5 5 5 5 0]))
(def ^:private ^"[J" dist-base
  (long-array [1 2 3 4 5 7 9 13 17 25 33 49 65 97 129 193 257 385 513 769 1025 1537 2049 3073
               4097 6145 8193 12289 16385 24577]))
(def ^:private ^"[J" dist-extra
  (long-array [0 0 0 0 1 1 2 2 3 3 4 4 5 5 6 6 7 7 8 8 9 9 10 10 11 11 12 12 13 13]))

(defn- inflate-codes [^longs st ^bytes in ^objects ob ^Huffman lencode ^Huffman distcode]
  (loop []
    (let [sym (decode st in lencode)]
      (cond
        (< sym 256)
        (let [^bytes out (ensure-capacity st ob 1)
              o (aget st 3)]
          (aset out o (unchecked-byte sym))
          (aset st 3 (inc o))
          (recur))

        (= sym 256) nil

        :else
        (let [s (- sym 257)
              _ (when (>= s 29) (damaged "invalid length symbol"))
              len (+ (aget length-base s) (take-bits st in (aget length-extra s)))
              ds (decode st in distcode)
              _ (when (>= ds 30) (damaged "invalid distance symbol"))
              dist (+ (aget dist-base ds) (take-bits st in (aget dist-extra ds)))
              o (aget st 3)]
          (when (> dist o) (damaged "distance too far back"))
          (let [^bytes out (ensure-capacity st ob len)]
            (loop [i 0]
              (when (< i len)
                (aset out (+ o i) (aget out (- (+ o i) dist)))
                (recur (inc i))))
            (aset st 3 (+ o len)))
          (recur))))))

(defn- inflate-stored [^longs st ^bytes in ^objects ob]
  ;; drop the remaining bits of the current byte
  (aset st 1 0)
  (aset st 2 0)
  (let [pos (aget st 0)]
    (when (> (+ pos 4) (alength in)) (damaged "unexpected end of input"))
    (let [len (bit-or (bit-and 0xff (aget in pos)) (bit-shift-left (bit-and 0xff (aget in (+ pos 1))) 8))
          nlen (bit-or (bit-and 0xff (aget in (+ pos 2))) (bit-shift-left (bit-and 0xff (aget in (+ pos 3))) 8))]
      (when-not (= len (bit-xor nlen 0xffff)) (damaged "stored block length mismatch"))
      (when (> (+ pos 4 len) (alength in)) (damaged "unexpected end of input"))
      (let [^bytes out (ensure-capacity st ob len)]
        (System/arraycopy in (int (+ pos 4)) out (int (aget st 3)) (int len))
        (aset st 3 (+ (aget st 3) len))
        (aset st 0 (+ pos 4 len))))))

(def ^:private fixed-tables
  (delay
    (let [lengths (long-array 288)]
      (dotimes [i 288]
        (aset lengths i (long (cond (< i 144) 8 (< i 256) 9 (< i 280) 7 :else 8))))
      (let [[lit _] (construct lengths 0 288)
            dl (long-array 30 5)
            [dist _] (construct dl 0 30)]
        [lit dist]))))

(def ^:private ^"[J" clen-order
  (long-array [16 17 18 0 8 7 9 6 10 5 11 4 12 3 13 2 14 1 15]))

(defn- inflate-dynamic [^longs st ^bytes in ^objects ob]
  (let [nlen (+ 257 (take-bits st in 5))
        ndist (+ 1 (take-bits st in 5))
        ncode (+ 4 (take-bits st in 4))
        _ (when (or (> nlen 286) (> ndist 30)) (damaged "bad dynamic block counts"))
        lengths (long-array 320)]
    (dotimes [i ncode]
      (aset lengths (aget clen-order i) (take-bits st in 3)))
    (let [[clcode left] (construct lengths 0 19)]
      (when-not (zero? left) (damaged "bad code length code"))
      (let [lengths (long-array 320)
            total (+ nlen ndist)]
        (loop [idx 0]
          (when (< idx total)
            (let [sym (decode st in clcode)]
              (if (< sym 16)
                (do (aset lengths idx sym) (recur (inc idx)))
                (let [[prev rep]
                      (case (long sym)
                        16 (do (when (zero? idx) (damaged "repeat with no previous length"))
                               [(aget lengths (dec idx)) (+ 3 (take-bits st in 2))])
                        17 [0 (+ 3 (take-bits st in 3))]
                        18 [0 (+ 11 (take-bits st in 7))])
                      prev (long prev)
                      rep (long rep)]
                  (when (> (+ idx rep) total) (damaged "too many code lengths"))
                  (dotimes [i rep] (aset lengths (+ idx i) prev))
                  (recur (+ idx rep)))))))
        (when (zero? (aget lengths 256)) (damaged "no end-of-block code"))
        (let [[lit lleft] (construct lengths 0 nlen)
              _ (when (or (< lleft 0) (and (pos? lleft) (not= nlen (+ (aget ^longs (.cnt ^Huffman lit) 0)
                                                                       (aget ^longs (.cnt ^Huffman lit) 1)))))
                  (damaged "bad literal/length code"))
              [dist dleft] (construct lengths nlen ndist)
              _ (when (or (< dleft 0) (and (pos? dleft) (not= ndist (+ (aget ^longs (.cnt ^Huffman dist) 0)
                                                                        (aget ^longs (.cnt ^Huffman dist) 1)))))
                  (damaged "bad distance code"))]
          (inflate-codes st in ob lit dist))))))

(defn- adler32 ^long [^bytes data ^long n]
  (loop [i 0 a 1 b 0]
    (if (< i n)
      (let [end (min n (+ i 5552))
            [a b] (loop [j i a a b b]
                    (if (< j end)
                      (let [a (+ a (bit-and 0xff (aget data j)))]
                        (recur (inc j) a (+ b a)))
                      [a b]))]
        (recur end (rem (long a) 65521) (rem (long b) 65521)))
      (bit-or (bit-shift-left b 16) a))))

(defn inflate
  "Decodes the zlib stream that starts at offset `start` of byte array `in`
  (default 0). Returns `{:data <bytes> :end <offset just after the stream>}`.
  The two-byte header and the Adler-32 trailer are both validated. Throws a
  `:damaged` failure on any error."
  ([^bytes in] (inflate in 0))
  ([^bytes in ^long start]
   (when (> (+ start 2) (alength in)) (damaged "truncated zlib header"))
   (let [cmf (bit-and 0xff (aget in start))
         flg (bit-and 0xff (aget in (inc start)))]
     (when-not (= 8 (bit-and cmf 15)) (damaged "not a deflate stream"))
     (when-not (zero? (mod (+ (* cmf 256) flg) 31)) (damaged "bad zlib header check"))
     (when-not (zero? (bit-and flg 0x20)) (damaged "preset dictionary")))
   (let [st (long-array [(+ start 2) 0 0 0])
         ob (object-array [(byte-array 1024)])]
     (loop []
       (let [final (take-bits st in 1)
             type (take-bits st in 2)]
         (case type
           0 (inflate-stored st in ob)
           1 (let [[lit dist] @fixed-tables] (inflate-codes st in ob lit dist))
           2 (inflate-dynamic st in ob)
           (damaged "invalid block type"))
         (when (zero? final) (recur))))
     (let [pos (aget st 0)
           n (aget st 3)
           ^bytes out (aget ob 0)]
       (when (> (+ pos 4) (alength in)) (damaged "missing Adler-32"))
       (let [stored (bit-or (bit-shift-left (bit-and 0xff (aget in pos)) 24)
                            (bit-shift-left (bit-and 0xff (aget in (+ pos 1))) 16)
                            (bit-shift-left (bit-and 0xff (aget in (+ pos 2))) 8)
                            (bit-and 0xff (aget in (+ pos 3))))]
         (when-not (= stored (adler32 out n)) (damaged "Adler-32 mismatch")))
       {:data (if (= n (alength out)) out (java.util.Arrays/copyOf out (int n)))
        :end (+ pos 4)}))))
