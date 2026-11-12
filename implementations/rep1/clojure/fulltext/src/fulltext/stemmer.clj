(ns fulltext.stemmer
  "The Porter stemming algorithm (1980), in the form of Martin Porter's
  reference implementation `porter.c`, including its two departures from the
  published paper (`BLI -> BLE` and `LOGI -> LOG` in step 2).

  The only public function is [[stem]]. Words are non-empty strings of ASCII
  lower-case letters; anything else is outside the algorithm's domain."
  (:require [clojure.string :as str]))

(set! *warn-on-reflection* true)

;; ---------------------------------------------------------------------------
;; Word predicates. Every one works on a String and an end index (exclusive),
;; so conditions can be evaluated on a stem without copying it.

(defn- consonant?
  "Is `w[i]` a consonant? `y` is a consonant at the start of a word or after a
  vowel-less position, i.e. when the previous letter is not a consonant it is
  a vowel."
  [^String w ^long i]
  (case (.charAt w i)
    (\a \e \i \o \u) false
    \y (or (zero? i) (not (consonant? w (dec i))))
    true))

(defn- measure
  "The measure m of `w[0, end)`: the number of VC sequences in [C](VC){m}[V]."
  ^long [^String w ^long end]
  (loop [i 0 m 0 in-vowel? false]
    (if (< i end)
      (let [c? (consonant? w i)]
        (cond
          (and c? in-vowel?) (recur (inc i) (inc m) false)
          c? (recur (inc i) m false)
          :else (recur (inc i) m true)))
      m)))

(defn- vowel-in-stem?
  "`*v*`: does `w[0, end)` contain a vowel?"
  [^String w ^long end]
  (loop [i 0]
    (and (< i end)
         (or (not (consonant? w i)) (recur (inc i))))))

(defn- double-consonant?
  "`*d`: does `w[0, end)` end with two identical consonants?"
  [^String w ^long end]
  (and (>= end 2)
       (= (.charAt w (- end 1)) (.charAt w (- end 2)))
       (consonant? w (dec end))))

(defn- cvc?
  "`*o`: does `w[0, end)` end consonant-vowel-consonant, the last consonant
  not being `w`, `x` or `y`?"
  [^String w ^long end]
  (and (>= end 3)
       (consonant? w (- end 1))
       (not (consonant? w (- end 2)))
       (consonant? w (- end 3))
       (not (#{\w \x \y} (.charAt w (dec end))))))

(defn- stem-end
  "End index of the stem left after removing `suffix` from `w`."
  ^long [^String w ^String suffix]
  (- (.length w) (.length suffix)))

;; ---------------------------------------------------------------------------
;; Rule tables. A table is an ordered vector of [suffix replacement]; the first
;; suffix that matches the word is the only rule considered.

(defn- table
  "Build a rule table from a whitespace-separated `suffix replacement` list
  where `-` stands for the empty replacement."
  [spec]
  (mapv (fn [[s r]] [s (if (= r "-") "" r)])
        (partition 2 (str/split (str/trim spec) #"\s+"))))

(def ^:private step2-rules
  (table "ational ate  tional tion  enci ence  anci ance  izer ize  bli ble
          alli al  entli ent  eli e  ousli ous  ization ize  ation ate
          ator ate  alism al  iveness ive  fulness ful  ousness ous
          aliti al  iviti ive  biliti ble  logi log"))

(def ^:private step3-rules
  (table "icate ic  ative -  alize al  iciti ic  ical ic  ful -  ness -"))

(def ^:private step4-suffixes
  ["al" "ance" "ence" "er" "ic" "able" "ible" "ant" "ement" "ment" "ent" "ion"
   "ou" "ism" "ate" "iti" "ous" "ive" "ize"])

(defn- apply-m>0-table
  "Steps 2 and 3: the first rule whose suffix matches fires if the stem has
  measure > 0; if its condition fails the word is left as it is."
  ^String [rules ^String w]
  (if-let [[^String suffix ^String repl]
           (some (fn [[^String s :as rule]] (when (.endsWith w s) rule)) rules)]
    (let [end (stem-end w suffix)]
      (if (pos? (measure w end))
        (str (.substring w 0 end) repl)
        w))
    w))

;; ---------------------------------------------------------------------------
;; Steps

(defn- step-1a ^String [^String w]
  (cond
    (.endsWith w "sses") (.substring w 0 (- (.length w) 2))
    (.endsWith w "ies") (str (.substring w 0 (- (.length w) 2)))
    (.endsWith w "ss") w
    (.endsWith w "s") (.substring w 0 (dec (.length w)))
    :else w))

(defn- step-1b-cleanup
  "Applied after `ED`/`ING` was removed: restore a final `e`, undouble a
  consonant."
  ^String [^String w]
  (let [n (.length w)]
    (cond
      (.endsWith w "at") (str w "e")
      (.endsWith w "bl") (str w "e")
      (.endsWith w "iz") (str w "e")
      (double-consonant? w n)
      (if (#{\l \s \z} (.charAt w (dec n))) w (.substring w 0 (dec n)))
      (and (== 1 (measure w n)) (cvc? w n)) (str w "e")
      :else w)))

(defn- step-1b ^String [^String w]
  (cond
    (.endsWith w "eed")
    (if (pos? (measure w (stem-end w "eed")))
      (.substring w 0 (dec (.length w)))
      w)

    (.endsWith w "ed")
    (let [end (stem-end w "ed")]
      (if (vowel-in-stem? w end) (step-1b-cleanup (.substring w 0 end)) w))

    (.endsWith w "ing")
    (let [end (stem-end w "ing")]
      (if (vowel-in-stem? w end) (step-1b-cleanup (.substring w 0 end)) w))

    :else w))

(defn- step-1c ^String [^String w]
  (let [n (.length w)]
    (if (and (.endsWith w "y") (vowel-in-stem? w (dec n)))
      (str (.substring w 0 (dec n)) "i")
      w)))

(defn- step-4 ^String [^String w]
  (if-let [^String suffix (some (fn [^String s] (when (.endsWith w s) s))
                                step4-suffixes)]
    (let [end (stem-end w suffix)]
      (if (and (> (measure w end) 1)
               (or (not= suffix "ion")
                   (and (pos? end) (#{\s \t} (.charAt w (dec end))))))
        (.substring w 0 end)
        w))
    w))

(defn- step-5a ^String [^String w]
  (if (.endsWith w "e")
    (let [end (dec (.length w))
          m (measure w end)]
      (if (or (> m 1) (and (== m 1) (not (cvc? w end))))
        (.substring w 0 end)
        w))
    w))

(defn- step-5b ^String [^String w]
  (let [n (.length w)]
    (if (and (> (measure w n) 1)
             (double-consonant? w n)
             (= \l (.charAt w (dec n))))
      (.substring w 0 (dec n))
      w)))

(defn stem
  "The Porter stem of `word`, a string of ASCII lower-case letters. Words of
  one or two letters are returned unchanged.

      (stem \"relational\") ;=> \"relat\"
      (stem \"controlled\") ;=> \"control\""
  ^String [^String word]
  (if (<= (.length word) 2)
    word
    (->> word
         step-1a step-1b step-1c
         (apply-m>0-table step2-rules)
         (apply-m>0-table step3-rules)
         step-4 step-5a step-5b)))
