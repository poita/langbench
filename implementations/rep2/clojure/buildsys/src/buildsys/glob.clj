(ns buildsys.glob
  "Glob patterns: compilation and matching.

  A pattern is split on `/` into components.  A component is `**` (zero or
  more whole components) or a vector of items:

    [:lit ch]   :any (`?`)   :star (`*`)   [:class negated? [[lo hi] ...]]

  Matching uses the classic two-pointer algorithm with backtracking to the most
  recent star, giving O(pattern x path) behaviour, at both the component level
  (for `**`) and the byte level (for `*`).")

(set! *warn-on-reflection* true)

(defn- split-on-slash
  "Splits at every `/`, keeping empty components (\"\" -> [\"\"])."
  [^String s]
  (loop [start 0 acc []]
    (let [i (.indexOf s (int \/) (int start))]
      (if (neg? i)
        (conj acc (subs s start))
        (recur (inc i) (conj acc (subs s start i)))))))

(defn- parse-class
  "Parses a class whose `[` is at index `i` of `comp`.  Returns
  `[item next-index]` or nil when malformed."
  [^String comp ^long i]
  (let [n (.length comp)
        negated? (and (< (inc i) n) (= \! (.charAt comp (inc i))))
        start (if negated? (+ i 2) (inc i))]
    (loop [j start ranges []]
      (cond
        (>= j n) nil
        (= \] (.charAt comp j)) (when (seq ranges) [[:class negated? ranges] (inc j)])
        (and (< (+ j 2) n)
             (= \- (.charAt comp (inc j)))
             (not= \] (.charAt comp (+ j 2))))
        (let [lo (.charAt comp j) hi (.charAt comp (+ j 2))]
          (when-not (> (int lo) (int hi))
            (recur (+ j 3) (conj ranges [lo hi]))))
        :else (let [c (.charAt comp j)] (recur (inc j) (conj ranges [c c])))))))

(defn- compile-component [^String comp]
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
              \[ (when-let [[item nxt] (parse-class comp i)]
                   (recur (long nxt) (conj items item)))
              (recur (inc i) (conj items [:lit c])))))))))

(defn compile-pattern
  "Compiles glob `pattern`; returns a vector of components, or nil when the
  pattern is malformed (empty, leading/trailing `/`, empty component, bad
  character class)."
  [^String pattern]
  (when-not (zero? (.length pattern))
    (let [comps (split-on-slash pattern)]
      (when-not (some #(zero? (.length ^String %)) comps)
        (let [compiled (mapv compile-component comps)]
          (when-not (some nil? compiled) compiled))))))

(defn literal-prefix
  "The leading part of `pattern` before its first wildcard byte; every path the
  pattern matches starts with it.  A `/` directly before a `**` component is
  dropped, because `**` may match zero components (`lib/**` matches `lib`)."
  ^String [^String pattern]
  (let [n (.length pattern)
        i (loop [i 0]
            (if (and (< i n) (not (#{\* \? \[} (.charAt pattern i))))
              (recur (inc i))
              i))]
    (if (and (pos? i) (< i n) (= \/ (.charAt pattern (dec i))) (.startsWith pattern "**" (int i)))
      (subs pattern 0 (dec i))
      (subs pattern 0 i))))

(defn- item-matches? [item ^Character c]
  (let [ch (.charValue c)]
    (cond
      (= item :any) true
      (= :lit (nth item 0)) (= ch (char (nth item 1)))
      :else (let [hit (boolean (some (fn [[lo hi]] (<= (int lo) (int ch) (int hi))) (nth item 2)))]
              (if (nth item 1) (not hit) hit)))))

(defn- match-component? [items ^String s]
  (let [pn (count items) n (.length s)]
    (loop [p 0 i 0 star-p -1 star-i 0]
      (if (< i n)
        (cond
          (and (< p pn) (= :star (nth items p))) (recur (inc p) i p i)
          (and (< p pn) (item-matches? (nth items p) (.charAt s i))) (recur (inc p) (inc i) star-p star-i)
          (>= star-p 0) (recur (inc star-p) (inc star-i) star-p (inc star-i))
          :else false)
        (loop [p p]
          (cond (>= p pn) true
                (= :star (nth items p)) (recur (inc p))
                :else false))))))

(defn matches?
  "True when compiled `pattern` matches the whole candidate string `s`."
  [pattern ^String s]
  (let [cands (split-on-slash s)
        pn (count pattern) cn (count cands)]
    (loop [p 0 i 0 star-p -1 star-i 0]
      (if (< i cn)
        (cond
          (and (< p pn) (= :globstar (nth pattern p))) (recur (inc p) i p i)
          (and (< p pn) (match-component? (nth pattern p) (nth cands i)))
          (recur (inc p) (inc i) star-p star-i)
          (>= star-p 0) (recur (inc star-p) (inc star-i) star-p (inc star-i))
          :else false)
        (loop [p p]
          (cond (>= p pn) true
                (= :globstar (nth pattern p)) (recur (inc p))
                :else false))))))
