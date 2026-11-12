(ns buildsys.glob
  "Glob patterns: compilation and matching.

  A pattern is a `/`-separated list of components.  `**` (alone) matches zero
  or more whole components; otherwise a component is a sequence of items
  `*`, `?`, `[...]` classes and literal bytes.  See SPEC.md, \"KBL: glob
  patterns\".")

(set! *warn-on-reflection* true)

(defn- parse-class
  "Parse a character class whose body starts at index `i` (just after `[`).
  Returns `[class next-index]`, or nil when malformed."
  [^String s i]
  (let [n (.length s)
        neg? (and (< i n) (= \! (.charAt s i)))]
    (loop [j (if neg? (inc i) i) ranges []]
      (when (< j n)
        (let [c (.charAt s j)]
          (cond
            (= c \]) (when (seq ranges)
                       [{:neg neg? :ranges ranges} (inc j)])
            (and (< (+ j 2) n)
                 (= \- (.charAt s (inc j)))
                 (not= \] (.charAt s (+ j 2))))
            (let [hi (.charAt s (+ j 2))]
              (when-not (> (int c) (int hi))
                (recur (+ j 3) (conj ranges [c hi]))))
            :else (recur (inc j) (conj ranges [c c]))))))))

(defn- compile-component
  "Compile one pattern component to `:globstar` or a vector of items, or nil
  when malformed.  Items are chars (literals), `:star`, `:any` or class maps."
  [^String comp]
  (if (= comp "**")
    :globstar
    (let [n (.length comp)]
      (loop [i 0 items []]
        (if (>= i n)
          items
          (let [c (.charAt comp i)]
            (case c
              \* (recur (inc i) (conj items :star))
              \? (recur (inc i) (conj items :any))
              \[ (when-let [[cls j] (parse-class comp (inc i))]
                   (recur (long j) (conj items cls)))
              (recur (inc i) (conj items c)))))))))

(defn compile-pattern
  "Compile glob `pattern` (a byte string).  Returns a compiled pattern, or nil
  when the pattern is malformed."
  [^String pattern]
  (let [comps (.split pattern "/" -1)]
    (when (every? (fn [^String c] (pos? (.length c))) comps)
      (let [compiled (mapv compile-component comps)]
        (when (every? some? compiled)
          {:comps compiled
           :prefix (let [i (->> pattern
                                (keep-indexed (fn [i c] (when (#{\* \? \[} c) i)))
                                first)
                         prefix (if i (subs pattern 0 i) pattern)]
                     ;; `**` may match zero components, so `lib/**` also
                     ;; matches the path `lib` itself
                     (if (and i (.endsWith prefix "/") (.startsWith pattern "**" i))
                       (subs prefix 0 (dec (.length prefix)))
                       prefix))})))))

(defn literal-prefix
  "The wildcard-free prefix of a compiled pattern's source text."
  [compiled]
  (:prefix compiled))

(defn- item-matches? [item ^Character c]
  (cond
    (char? item) (= (char item) c)
    (identical? item :any) true
    :else (let [in? (boolean (some (fn [[lo hi]]
                                     (<= (int lo) (int c) (int hi)))
                                   (:ranges item)))]
            (if (:neg item) (not in?) in?))))

(defn- match-component?
  "Does the items vector match all of string `s`?"
  [items ^String s]
  (let [items ^clojure.lang.IPersistentVector items
        n (count items)
        m (.length s)]
    (loop [pi 0 si 0 star-pi -1 star-si 0]
      (if (< si m)
        (let [it (when (< pi n) (nth items pi))]
          (cond
            (identical? it :star) (recur (inc pi) si pi si)
            (and (some? it) (item-matches? it (.charAt s si)))
            (recur (inc pi) (inc si) star-pi star-si)
            (>= star-pi 0) (recur (inc star-pi) (inc star-si) star-pi (inc star-si))
            :else false))
        (loop [pi pi]
          (cond (>= pi n) true
                (identical? (nth items pi) :star) (recur (inc pi))
                :else false))))))

(defn- split-slash [^String s]
  (.split s "/" -1))

(defn matches?
  "Does compiled `pattern` match the whole candidate string `candidate`?  The
  candidate is split at every `/`, empty components included."
  [pattern ^String candidate]
  (let [pcs (:comps pattern)
        m (count pcs)
        ^objects cs (split-slash candidate)
        n (alength cs)]
    ;; dp[j] = pattern components i.. match candidate components j..
    (loop [i (dec m)
           ^booleans nxt (doto (boolean-array (inc n)) (aset n true))]
      (if (neg? i)
        (aget nxt 0)
        (let [pc (nth pcs i)
              cur (boolean-array (inc n))]
          (if (identical? pc :globstar)
            (do (aset cur n (aget nxt n))
                (loop [j (dec n)]
                  (when (>= j 0)
                    (aset cur j (boolean (or (aget nxt j) (aget cur (inc j)))))
                    (recur (dec j)))))
            (loop [j (dec n)]
              (when (>= j 0)
                (aset cur j (boolean (and (aget nxt (inc j))
                                          (match-component? pc (aget cs j)))))
                (recur (dec j)))))
          (recur (dec i) cur))))))
