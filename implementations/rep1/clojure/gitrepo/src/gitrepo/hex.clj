(ns gitrepo.hex
  "Hexadecimal ids and \"byte strings\".

  Names, messages and ident lines in a repository are arbitrary bytes. gitrepo
  carries them as ISO-8859-1 strings (one char per byte, so string order is
  byte order and nothing is ever re-encoded). `latin1` and `latin1-bytes`
  convert between the two views; `utf8->latin1` turns an ordinary Java string
  into the byte-string for its UTF-8 encoding."
  (:import [java.nio.charset StandardCharsets]))

(set! *warn-on-reflection* true)

(def ^:private ^String digits "0123456789abcdef")

(defn bytes->hex
  "Lowercase hex of `n` bytes of `b` starting at `off` (default: all of `b`)."
  (^String [^bytes b] (bytes->hex b 0 (alength b)))
  (^String [^bytes b ^long off ^long n]
   (let [sb (StringBuilder. (int (* 2 n)))]
     (dotimes [i n]
       (let [v (bit-and 0xff (aget b (+ off i)))]
         (.append sb (.charAt digits (bit-shift-right v 4)))
         (.append sb (.charAt digits (bit-and v 15)))))
     (.toString sb))))

(defn hex-digit
  "The value 0-15 of hex character `c` (either case), or -1."
  ^long [c]
  (let [c (long (int (char c)))]
    (cond (and (>= c 48) (<= c 57)) (- c 48)
          (and (>= c 97) (<= c 102)) (- c 87)
          (and (>= c 65) (<= c 70)) (- c 55)
          :else -1)))

(defn hex-string?
  "True when `s` consists only of hex digits (either case)."
  [^String s]
  (every? #(>= (hex-digit %) 0) s))

(defn hex->bytes
  "Bytes of the hex string `s`, which must have even length and hex digits."
  ^bytes [^String s]
  (let [n (quot (.length s) 2)
        b (byte-array n)]
    (dotimes [i n]
      (aset b i (unchecked-byte (+ (* 16 (hex-digit (.charAt s (* 2 i))))
                                   (hex-digit (.charAt s (inc (* 2 i))))))))
    b))

(defn object-id?
  "True when `s` is 40 lowercase hex digits."
  [s]
  (and (string? s)
       (= 40 (.length ^String s))
       (every? #(>= (hex-digit %) 0) s)
       (= s (.toLowerCase ^String s))))

(defn latin1
  "The byte-string for `n` bytes of `b` from `off` (default: all of `b`)."
  (^String [^bytes b] (String. b StandardCharsets/ISO_8859_1))
  (^String [^bytes b ^long off ^long n]
   (String. b (int off) (int n) StandardCharsets/ISO_8859_1)))

(defn latin1-bytes
  "The bytes of byte-string `s`."
  ^bytes [^String s]
  (.getBytes s StandardCharsets/ISO_8859_1))

(defn utf8->latin1
  "The byte-string for the UTF-8 encoding of the Java string `s`."
  ^String [^String s]
  (latin1 (.getBytes s StandardCharsets/UTF_8)))
