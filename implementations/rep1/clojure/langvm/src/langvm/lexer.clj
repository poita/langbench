(ns langvm.lexer
  "Lexer (SPEC section 3).

  `(lex lines)` turns the lines of one module body into a vector of tokens.
  A token is a vector `[kind value pos]`:

  * `kind` is `:ident`, `:int`, `:float`, `:str`, `:char` or `:eof`, or, for
    keywords, punctuation and operators, the token's own text (e.g. `\"fn\"`,
    `\"::\"`, `\"_\"`);
  * `value` is the identifier text, the numeric value, the string (a Java
    String) or the character's scalar value;
  * `pos` is a packed position (see `langvm.diag`)."
  (:require [langvm.diag :as diag]
            [langvm.source :as source])
  (:import (java.math BigInteger)))

(set! *warn-on-reflection* true)

(def ^:private two-char-ops
  #{"#[" "::" ".." "->" "==" "!=" "<=" ">=" "&&" "||" "<<" ">>" "++"})

(def ^:private one-char-ops
  #{\( \) \[ \] \{ \} \, \; \: \. \| \+ \- \* \/ \% \! \~ \& \^ \< \> \=})

(defn- ident-start? [^long c]
  (or (<= 97 c 122) (<= 65 c 90) (== c 95)))

(defn- digit? [^long c] (<= 48 c 57))

(defn- hex-digit? [^long c]
  (or (<= 48 c 57) (<= 97 c 102) (<= 65 c 70)))

(defn- hex-value ^long [^long c]
  (cond (<= 48 c 57) (- c 48)
        (<= 97 c 102) (+ 10 (- c 97))
        :else (+ 10 (- c 65))))

(defn- code-points ^ints [^String s]
  (.toArray (.codePoints s)))

(defn- line-starts
  "Indices into `cps` where each line begins."
  ^ints [^ints cps]
  (let [out (java.util.ArrayList.)]
    (.add out (int 0))
    (dotimes [i (alength cps)]
      (when (== 10 (aget cps i)) (.add out (int (inc i)))))
    (int-array out)))

(defn lex
  "Lex the module body made of `lines`.  Signals `bad-token`, `int-range`,
  `bad-escape` or `unterminated` at the first ill-formed token."
  [lines]
  (let [text (clojure.string/join "\n" lines)
        ^ints cps (code-points text)
        n (alength cps)
        ^ints starts (line-starts cps)
        pos-at (fn ^long [^long i]
                 (let [k (java.util.Arrays/binarySearch starts (int i))
                       line (if (neg? k) (- (- k) 1) (inc k))
                       ;; binarySearch gives -(insertion point) - 1 when absent;
                       ;; line number is the insertion point.
                       start (aget starts (dec line))]
                   (diag/pos line (inc (- i start)))))
        at (fn ^long [^long i] (if (< i n) (aget cps i) -1))
        out (java.util.ArrayList.)
        emit! (fn [kind v ^long p] (.add out [kind v p]))
        ;; ---- escapes: returns [codepoint next-index] ----
        read-escape
        (fn [^long i]
          ;; cps[i] is the backslash
          (let [bs-pos (pos-at i)
                c (at (inc i))
                bad #(diag/fail :bad-escape bs-pos)]
            (case (long c)
              110 [10 (+ i 2)]
              116 [9 (+ i 2)]
              114 [13 (+ i 2)]
              48 [0 (+ i 2)]
              92 [92 (+ i 2)]
              39 [39 (+ i 2)]
              34 [34 (+ i 2)]
              117 (if (== (at (+ i 2)) 123)
                    (loop [j (+ i 3), v 0, cnt 0]
                      (let [d (at j)]
                        (cond
                          (hex-digit? d) (recur (inc j)
                                                (if (> cnt 7) v (+ (* v 16) (hex-value d)))
                                                (inc cnt))
                          (and (== d 125) (<= 1 cnt 6)
                               (<= v 0x10FFFF) (not (<= 0xD800 v 0xDFFF)))
                          [v (inc j)]
                          :else (bad))))
                    (bad))
              (bad))))
        number
        (fn [^long i]
          ;; returns next index; emits a token
          (let [p (pos-at i)
                c0 (at i), c1 (at (inc i))
                run (fn ^long [^long j pred] ; consume digits / underscores
                      (loop [j j] (let [c (at j)] (if (or (pred c) (== c 95)) (recur (inc j)) j))))
                clean (fn [^long a ^long b]
                        (let [sb (StringBuilder.)]
                          (loop [k a] (when (< k b)
                                        (let [c (aget cps k)]
                                          (when-not (== c 95) (.append sb (char c))))
                                        (recur (inc k))))
                          (str sb)))
                radix-int
                (fn [radix pred]
                  (let [d (at (+ i 2))]
                    (if-not (pred d)
                      (diag/fail :bad-token p)
                      (let [e (run (+ i 2) pred)
                            v (BigInteger. ^String (clean (+ i 2) e) (int radix))]
                        (when (> (.bitLength v) 63) (diag/fail :int-range p))
                        (emit! :int (.longValue v) p)
                        e))))]
            (cond
              (and (== c0 48) (== c1 120)) (radix-int 16 hex-digit?)
              (and (== c0 48) (== c1 98)) (radix-int 2 #(or (== (long %) 48) (== (long %) 49)))
              :else
              (let [e1 (run i digit?)
                    frac? (and (== (at e1) 46) (digit? (at (inc e1))))
                    e2 (if frac? (run (inc e1) digit?) e1)
                    sign? (let [c (at (inc e2))] (or (== c 43) (== c 45)))
                    exp? (and (or (== (at e2) 101) (== (at e2) 69))
                              (digit? (at (+ e2 (if sign? 2 1)))))
                    e3 (if exp? (run (+ e2 (if sign? 2 1)) digit?) e2)]
                (if (or frac? exp?)
                  (do (emit! :float (Double/parseDouble ^String (clean i e3)) p) e3)
                  (let [v (BigInteger. ^String (clean i e1))]
                    (when (> (.bitLength v) 63) (diag/fail :int-range p))
                    (emit! :int (.longValue v) p)
                    e1))))))]
    (loop [i 0]
      (if (>= i n)
        nil
        (let [c (aget cps i)]
          (cond
            (or (== c 32) (== c 9) (== c 10) (== c 13)) (recur (inc i))

            ;; comments
            (and (== c 47) (== (at (inc i)) 47))
            (recur (long (loop [j (+ i 2)] (if (or (>= j n) (== (aget cps j) 10)) j (recur (inc j))))))

            (and (== c 47) (== (at (inc i)) 42))
            (let [start (pos-at i)]
              (recur (long (loop [j (+ i 2), depth 1]
                       (cond
                         (>= j n) (diag/fail :unterminated start)
                         (and (== (aget cps j) 47) (== (at (inc j)) 42)) (recur (+ j 2) (inc depth))
                         (and (== (aget cps j) 42) (== (at (inc j)) 47))
                         (if (== depth 1) (+ j 2) (recur (+ j 2) (dec depth)))
                         :else (recur (inc j) depth))))))

            (ident-start? c)
            (let [e (loop [j (inc i)]
                      (let [d (at j)] (if (or (ident-start? d) (digit? d)) (recur (inc j)) j)))
                  s (String. ^ints cps (int i) (int (- e i)))
                  p (pos-at i)]
              (cond
                (> (- e i) 200) (diag/fail :bad-token p)
                (= s "_") (emit! "_" nil p)
                (source/keywords s) (emit! s nil p)
                :else (emit! :ident s p))
              (recur (long e)))

            (digit? c) (recur (long (number i)))

            (== c 39)                    ; character literal
            (let [start (pos-at i)
                  c1 (at (inc i))]
              (cond
                (or (== c1 -1) (== c1 39) (== c1 10) (== c1 13)) (diag/fail :unterminated start)
                :else
                (let [[v j] (if (== c1 92) (read-escape (inc i)) [c1 (+ i 2)])]
                  (when-not (== (at j) 39) (diag/fail :unterminated start))
                  (emit! :char v start)
                  (recur (long (inc j))))))

            (== c 34)                    ; string literal
            (let [start (pos-at i)
                  sb (StringBuilder.)]
              (recur
               (long (loop [j (inc i)]
                 (let [d (at j)]
                   (cond
                     (or (== d -1) (== d 10) (== d 13)) (diag/fail :unterminated start)
                     (== d 34) (do (emit! :str (str sb) start) (inc j))
                     (== d 92) (let [[v k] (read-escape j)] (.appendCodePoint sb (int v)) (recur (long k)))
                     :else (do (.appendCodePoint sb (int d)) (recur (inc j)))))))))

            :else
            (let [p (pos-at i)
                  two (when (< (inc i) n) (String. ^ints cps (int i) (int 2)))]
              (cond
                (and two (two-char-ops two)) (do (emit! two nil p) (recur (+ i 2)))
                (one-char-ops (char c)) (do (emit! (str (char c)) nil p) (recur (inc i)))
                :else (diag/fail :bad-token p)))))))
    (let [nlines (max 1 (count lines))
          last-len (if (seq lines)
                     (let [^String l (peek lines)] (.codePointCount l 0 (.length l)))
                     0)]
      (.add out [:eof nil (diag/pos nlines (inc last-len))]))
    (vec out)))
