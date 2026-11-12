(ns mime.text
  "Small string helpers shared by the header parsers: blank stripping,
  comment skipping, quoted strings and hexadecimal digits.

  Throughout the library \"blank\" means SPACE or TAB, nothing else."
  (:import (java.util Locale)))

(set! *warn-on-reflection* true)

(defn ws?
  "True for SPACE and TAB."
  [c]
  (or (= c \space) (= c \tab)))

(defn strip
  "Removes leading and trailing SPACE and TAB characters."
  ^String [^String s]
  (let [n (.length s)
        a (loop [i 0] (if (and (< i n) (ws? (.charAt s i))) (recur (inc i)) i))
        b (loop [j n] (if (and (> j a) (ws? (.charAt s (dec j)))) (recur (dec j)) j))]
    (.substring s (int a) (int b))))

(defn collapse
  "Replaces each run of SPACE/TAB with one SPACE, then strips both ends."
  ^String [^String s]
  (let [sb (StringBuilder.)
        n (.length s)]
    (loop [i 0 in-ws? false]
      (when (< i n)
        (let [c (.charAt s i)]
          (if (ws? c)
            (recur (inc i) true)
            (do (when in-ws? (.append sb \space))
                (.append sb c)
                (recur (inc i) false))))))
    ;; a leading run produced a leading space; remove it.
    (let [r (.toString sb)]
      (if (and (pos? (.length r)) (= (.charAt r 0) \space)) (.substring r 1) r))))

(defn lower
  "Lower-cases `s`."
  ^String [^String s]
  (.toLowerCase s Locale/ROOT))

(defn ascii-lower
  "Lower-cases the ASCII letters of `s`, leaving every other character alone."
  ^String [^String s]
  (let [n (.length s)
        sb (StringBuilder. n)]
    (dotimes [i n]
      (let [c (.charAt s i)]
        (.append sb (if (and (>= (int c) 65) (<= (int c) 90)) (char (+ (int c) 32)) c))))
    (.toString sb)))

(defn hex-val
  "Value of the hexadecimal digit with code `c` (0-9, A-F, a-f), or -1."
  ^long [^long c]
  (cond (and (>= c 48) (<= c 57)) (- c 48)
        (and (>= c 65) (<= c 70)) (- c 55)
        (and (>= c 97) (<= c 102)) (- c 87)
        :else -1))

(defn skip-comment
  "`s` has `(` at index `i`. Returns the index just after the matching `)`,
  counting nesting and treating `\\x` as a literal x; an unterminated comment
  runs to the end of `s`."
  ^long [^String s ^long i]
  (let [n (.length s)]
    (loop [j (inc i) depth 1]
      (if (>= j n)
        n
        (let [c (.charAt s j)]
          (cond (= c \\) (recur (+ j 2) depth)
                (= c \() (recur (inc j) (inc depth))
                (= c \)) (if (== depth 1) (inc j) (recur (inc j) (dec depth)))
                :else (recur (inc j) depth)))))))

(defn scan-quoted
  "`s` has `\"` at index `i`. Returns `[contents end]`: the unescaped contents
  of the quoted string and the index just after its closing quote (or the end of
  `s` when it is never closed). A backslash and the character after it stand
  for that character; a backslash at the very end stands for itself."
  [^String s ^long i]
  (let [n (.length s)
        sb (StringBuilder.)]
    (loop [j (inc i)]
      (if (>= j n)
        [(.toString sb) n]
        (let [c (.charAt s j)]
          (cond (= c \\) (if (< (inc j) n)
                           (do (.append sb (.charAt s (inc j))) (recur (+ j 2)))
                           (do (.append sb \\) (recur (inc j))))
                (= c \") [(.toString sb) (inc j)]
                :else (do (.append sb c) (recur (inc j)))))))))

(defn percent-decode
  "Percent-decodes `s` into a byte array: `%HH` yields that byte, any other
  `%` is a literal `%`, and every other character contributes its UTF-8 bytes."
  ^bytes [^String s]
  (let [out (java.io.ByteArrayOutputStream.)
        n (.length s)]
    (loop [i 0]
      (when (< i n)
        (let [c (.charAt s i)]
          (if (and (= c \%) (< (+ i 2) n)
                   (>= (hex-val (int (.charAt s (+ i 1)))) 0)
                   (>= (hex-val (int (.charAt s (+ i 2)))) 0))
            (do (.write out (int (+ (* 16 (hex-val (int (.charAt s (+ i 1)))))
                                    (hex-val (int (.charAt s (+ i 2)))))))
                (recur (+ i 3)))
            (let [cp (.codePointAt s i)
                  len (Character/charCount cp)]
              (.write out (.getBytes (.substring s i (+ i len)) java.nio.charset.StandardCharsets/UTF_8))
              (recur (+ i len)))))))
    (.toByteArray out)))
