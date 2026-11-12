(ns buildsys.hash
  "64-bit FNV-1a content hashing.

  Kiln strings are *byte strings* held in Java `String`s whose chars are all
  in 0..255 (ISO-8859-1 view of the bytes), so hashing walks chars as bytes.")

(set! *warn-on-reflection* true)

(def ^:private ^:const offset-basis (unchecked-long 0xcbf29ce484222325N))
(def ^:private ^:const prime 0x100000001b3)

(defn fnv1a
  "The FNV-1a 64-bit hash of byte string `s`, as a (signed) long."
  ^long [^String s]
  (let [n (.length s)]
    (loop [i 0 h offset-basis]
      (if (< i n)
        (recur (inc i)
               (unchecked-multiply
                (bit-xor h (long (bit-and (int (.charAt s i)) 0xff)))
                prime))
        h))))

(defn hex
  "A long rendered as exactly 16 lowercase hex digits."
  ^String [^long h]
  (let [s (Long/toHexString h)]
    (str (subs "0000000000000000" (count s)) s)))

(defn hash-hex
  "The 16-digit lowercase hex FNV-1a hash of byte string `s`."
  ^String [^String s]
  (hex (fnv1a s)))
