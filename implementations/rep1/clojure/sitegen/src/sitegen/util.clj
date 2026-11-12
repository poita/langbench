(ns sitegen.util
  "Small helpers shared by the library's modules.")

(set! *warn-on-reflection* true)

(defn compare-code-points
  "Compares two strings as sequences of Unicode code points (which differs
  from `String/compareTo`, which compares UTF-16 code units, only when a
  supplementary character meets a character in U+E000-U+FFFF).  Returns a
  negative, zero or positive integer."
  ^long [^String a ^String b]
  (let [na (.length a) nb (.length b)
        n (min na nb)]
    (loop [i 0]
      (if (< i n)
        (let [x (.charAt a i) y (.charAt b i)]
          (if (== (int x) (int y))
            (recur (inc i))
            ;; Surrogates (U+D800-U+DFFF) must sort above U+E000-U+FFFF.
            (let [fix (fn [c] (let [c (int c)] (cond (>= c 0xE000) (- c 0x800) (>= c 0xD800) (+ c 0x2000) :else c)))
                  sx (Character/isSurrogate x) sy (Character/isSurrogate y)]
              (if (or sx sy)
                (long (- (int (fix x)) (int (fix y))))
                (long (- (int x) (int y)))))))
        (long (- na nb))))))
