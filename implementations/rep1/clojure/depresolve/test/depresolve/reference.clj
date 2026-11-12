(ns depresolve.reference
  "A direct, naive transcription of the recursive algorithm in SPEC.md, used
  as an oracle for the optimised search. Only suitable for small inputs."
  (:require [depresolve.range :as range]))

(defn resolve-naive
  "Returns a map name -> version vector, or nil on failure."
  [{:keys [registry root]}]
  (let [versions (reduce (fn [m e] (update m (:name e) (fnil conj []) e)) {} registry)
        resolve*
        (fn resolve* [pending chosen]
          (if (empty? pending)
            chosen
            (let [{:keys [name range]} (first pending)
                  rest (rest pending)
                  rng (if (string? range) (depresolve.range/parse range) range)]
              (if-let [cv (chosen name)]
                (when (range/accepts? rng cv)
                  (resolve* rest chosen))
                (let [cands (->> (versions name)
                                 (filter #(range/accepts? rng (:version %)))
                                 (sort-by :version #(compare %2 %1)))]
                  (some (fn [e]
                          (resolve* (concat (:requirements e) rest)
                                    (assoc chosen name (:version e))))
                        cands))))))]
    (resolve* root {})))
