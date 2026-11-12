(ns fulltext.scoring
  "BM25 scoring.")

(set! *warn-on-reflection* true)

(def ^:const k1 1.2)
(def ^:const b 0.75)

(defn idf
  "Inverse document frequency of an atom occurring in `df` of `n` documents:
  `ln((n - df + 0.5) / (df + 0.5) + 1)`. Always positive."
  ^double [^long n ^long df]
  (Math/log (+ (/ (+ (- n df) 0.5) (+ df 0.5)) 1.0)))

(defn term-score
  "The BM25 contribution of one atom to one document: `idf` weighted by the
  saturated, length-normalised frequency `f` in a document of `dl` tokens,
  where `avgdl` is the mean document length (when it is 0 the length ratio
  is taken to be 0)."
  ^double [^double idf ^long f ^long dl ^double avgdl]
  (let [ratio (if (zero? avgdl) 0.0 (/ (double dl) avgdl))
        denom (+ f (* k1 (+ (- 1.0 b) (* b ratio))))]
    (* idf (/ (* f (+ k1 1.0)) denom))))
