(ns buildsys.hash
  "64-bit FNV-1a content hashing.

  Strings throughout Kiln are *byte strings*: Java strings whose chars are all
  in the range 0-255, one char per byte (ISO-8859-1).")

(set! *warn-on-reflection* true)

(def ^:private ^:const offset-basis
  (.longValue (java.math.BigInteger. "cbf29ce484222325" 16)))

(def ^:private ^:const prime 0x100000001b3)

(defn fnv1a
  "The raw 64-bit FNV-1a hash of byte string `s`, as a signed long."
  ^long [^String s]
  (let [n (.length s)]
    (loop [i 0 h offset-basis]
      (if (< i n)
        (recur (unchecked-inc i)
               (unchecked-multiply (bit-xor h (long (int (.charAt s i)))) prime))
        h))))

(defn hex
  "Format the long `h` as exactly 16 lowercase hexadecimal digits."
  [^long h]
  (let [s (Long/toHexString h)]
    (str (subs "0000000000000000" (.length s)) s)))

(defn hash-hex
  "The 16-digit lowercase hex FNV-1a hash of byte string `s`."
  [^String s]
  (hex (fnv1a s)))
