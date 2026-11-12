(ns template.json
  "A small recursive-descent JSON (RFC 8259) parser producing template values.

  Numbers without a fraction or exponent are `Long`s, the others `Double`s;
  objects become insertion-ordered `LinkedHashMap`s, arrays vectors, `null`
  nil."
  (:import (java.util LinkedHashMap)))

(set! *warn-on-reflection* true)

(defn- fail [^String s ^long pos msg]
  (throw (ex-info (str "invalid JSON at offset " pos ": " msg) {:template/json true :offset pos})))

(defn- skip-ws ^long [^String s ^long i]
  (let [n (.length s)]
    (loop [i i]
      (if (and (< i n) (let [c (.charAt s i)] (or (= c \space) (= c \newline) (= c \tab) (= c \return))))
        (recur (inc i))
        i))))

(declare parse-value)

(defn- parse-string
  "Parse a string starting at the opening quote at `i`; returns [string next-i]."
  [^String s ^long i]
  (let [n (.length s)]
    (loop [j (inc i) start (inc i) sb nil]
      (when (>= j n) (fail s i "unterminated string"))
      (let [c (.charAt s j)]
        (cond
          (= c \") [(if sb (.toString (.append ^StringBuilder sb (.substring s start j))) (.substring s start j))
                     (inc j)]
          (= c \\)
          (let [sb (or sb (StringBuilder.))
                _  (.append ^StringBuilder sb (.substring s start j))
                e  (when (< (inc j) n) (.charAt s (inc j)))]
            (case e
              \" (do (.append ^StringBuilder sb \") (recur (+ j 2) (+ j 2) sb))
              \\ (do (.append ^StringBuilder sb \\) (recur (+ j 2) (+ j 2) sb))
              \/ (do (.append ^StringBuilder sb \/) (recur (+ j 2) (+ j 2) sb))
              \b (do (.append ^StringBuilder sb \backspace) (recur (+ j 2) (+ j 2) sb))
              \f (do (.append ^StringBuilder sb \formfeed) (recur (+ j 2) (+ j 2) sb))
              \n (do (.append ^StringBuilder sb \newline) (recur (+ j 2) (+ j 2) sb))
              \r (do (.append ^StringBuilder sb \return) (recur (+ j 2) (+ j 2) sb))
              \t (do (.append ^StringBuilder sb \tab) (recur (+ j 2) (+ j 2) sb))
              \u (do (when (> (+ j 6) n) (fail s j "bad unicode escape"))
                     (let [cp (try (Integer/parseInt (.substring s (+ j 2) (+ j 6)) 16)
                                   (catch NumberFormatException _ (fail s j "bad unicode escape")))]
                       (.append ^StringBuilder sb (char cp))
                       (recur (+ j 6) (+ j 6) sb)))
              (fail s j "bad escape")))
          (< (int c) 0x20) (fail s j "control character in string")
          :else (recur (inc j) start sb))))))

(defn- parse-number [^String s ^long i]
  (let [n (.length s)
        j (loop [j i]
            (if (and (< j n) (let [c (.charAt s j)]
                               (or (Character/isDigit c) (= c \-) (= c \+) (= c \.) (= c \e) (= c \E))))
              (recur (inc j))
              j))
        tok (.substring s i j)
        floating? (or (>= (.indexOf tok ".") 0) (>= (.indexOf tok "e") 0) (>= (.indexOf tok "E") 0))]
    (when (== i j) (fail s i "unexpected character"))
    [(try
       (if floating?
         (Double/parseDouble tok)
         (try (Long/parseLong tok)
              (catch NumberFormatException _ (.doubleValue (java.math.BigInteger. tok)))))
       (catch NumberFormatException _ (fail s i "bad number")))
     j]))

(defn- parse-array [^String s ^long i]
  (let [i (skip-ws s (inc i))]
    (if (and (< i (.length s)) (= (.charAt s i) \]))
      [[] (inc i)]
      (loop [i i out (transient [])]
        (let [[v j] (parse-value s i)
              j (skip-ws s j)
              out (conj! out v)]
          (when (>= j (.length s)) (fail s j "unterminated array"))
          (let [c (.charAt s j)]
            (cond
              (= c \,) (recur (skip-ws s (inc j)) out)
              (= c \]) [(persistent! out) (inc j)]
              :else (fail s j "expected , or ]"))))))))

(defn- parse-object [^String s ^long i]
  (let [m (LinkedHashMap.)
        i (skip-ws s (inc i))]
    (if (and (< i (.length s)) (= (.charAt s i) \}))
      [m (inc i)]
      (loop [i i]
        (when-not (and (< i (.length s)) (= (.charAt s i) \")) (fail s i "expected string key"))
        (let [[k j] (parse-string s i)
              j (skip-ws s j)]
          (when-not (and (< j (.length s)) (= (.charAt s j) \:)) (fail s j "expected :"))
          (let [[v j] (parse-value s (skip-ws s (inc j)))
                j (skip-ws s j)]
            (.put m k v)
            (when (>= j (.length s)) (fail s j "unterminated object"))
            (let [c (.charAt s j)]
              (cond
                (= c \,) (recur (skip-ws s (inc j)))
                (= c \}) [m (inc j)]
                :else (fail s j "expected , or }")))))))))

(defn- parse-value [^String s ^long i]
  (when (>= i (.length s)) (fail s i "unexpected end of input"))
  (let [c (.charAt s i)]
    (cond
      (= c \{) (parse-object s i)
      (= c \[) (parse-array s i)
      (= c \") (parse-string s i)
      (.startsWith s "true" (int i)) [true (+ i 4)]
      (.startsWith s "false" (int i)) [false (+ i 5)]
      (.startsWith s "null" (int i)) [nil (+ i 4)]
      :else (parse-number s i))))

(defn parse
  "Parse the JSON document in string `s`. Throws `ex-info` on malformed input."
  [^String s]
  (let [i (skip-ws s 0)
        [v j] (parse-value s i)
        j (skip-ws s j)]
    (when (< j (.length s)) (fail s j "trailing characters"))
    v))
