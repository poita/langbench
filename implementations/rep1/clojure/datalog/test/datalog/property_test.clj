(ns datalog.property-test
  "Checks the engine against a deliberately naive reference evaluator on
  randomly generated stratified programs."
  (:require [clojure.test :refer [deftest is]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [datalog.core :as dl]
            [datalog.syntax :as syn]))

;; ---------------------------------------------------------------------------
;; Reference evaluator: brute-force substitutions over the constant domain,
;; naive fixpoint per stratum.

(def domain [1 2 -3 :a :b])
(def vars ['X 'Y 'Z])
(def preds [["p0" 1] ["p1" 2] ["p2" 1] ["p3" 2] ["p4" 1] ["p5" 2]])

(defn- stratum [[name _]] (quot (Long/parseLong (subs name 1)) 2))

(defn- val-of [env t] (if (symbol? t) (env t) t))

(defn- holds? [db env lit]
  (case (:op lit)
    :pos (contains? (db (syn/atom-key (:atom lit)))
                    (mapv #(val-of env %) (:args (:atom lit))))
    :neg (not (contains? (db (syn/atom-key (:atom lit)))
                         (mapv #(val-of env %) (:args (:atom lit)))))
    :cmp (let [c (syn/compare-constants (val-of env (:left lit)) (val-of env (:right lit)))]
           (case (:cmp lit)
             :< (neg? c) :<= (not (pos? c)) :> (pos? c) :>= (not (neg? c))
             := (zero? c) :!= (not (zero? c))))))

(defn- rule-vars [rule]
  (distinct (filter symbol? (concat (:args (:head rule))
                                    (mapcat #(or (:args (:atom %)) [(:left %) (:right %)])
                                            (:body rule))))))

(defn- envs [vs]
  (reduce (fn [es v] (for [e es d domain] (assoc e v d))) [{}] vs))

(defn- derive-rule [db rule]
  (for [env (envs (rule-vars rule))
        :when (every? #(holds? db env %) (:body rule))]
    [(syn/atom-key (:head rule)) (mapv #(val-of env %) (:args (:head rule)))]))

(defn reference-model [{:keys [rules]}]
  (loop [strata (sort (distinct (map (comp stratum syn/atom-key :head) rules)))
         db (zipmap preds (repeat #{}))]
    (if-let [s (first strata)]
      (let [rs (filter #(= s (stratum (syn/atom-key (:head %)))) rules)
            db' (loop [db db]
                  (let [new (reduce (fn [d [k t]] (update d k conj t)) db
                                    (mapcat #(derive-rule db %) rs))]
                    (if (= new db) db (recur new))))]
        (recur (rest strata) db'))
      db)))

;; ---------------------------------------------------------------------------
;; Generators. Predicate pN lives in stratum N/2: positive atoms may use
;; predicates of the same or a lower stratum (so recursion, including mutual
;; and non-linear recursion, occurs), negated atoms only strictly lower ones.

(def gen-const (gen/elements domain))

(defn- gen-atom [[name arity] term-gen]
  (gen/fmap (fn [args] {:pred name :args (vec args)}) (gen/vector term-gen arity)))

(def gen-fact
  (gen/let [k (gen/elements preds)
            a (gen-atom k gen-const)]
    {:head a :body []}))

(defn- gen-rule []
  (gen/bind
   (gen/let [head-key (gen/elements preds)
             n-pos (gen/choose 1 3)
             pos-keys (gen/vector (gen/elements (filter #(<= (stratum %) (stratum head-key)) preds))
                                  n-pos)
             pos-atoms (apply gen/tuple
                              (map #(gen-atom % (gen/frequency [[5 (gen/elements vars)]
                                                                [1 gen-const]]))
                                   pos-keys))]
     [head-key pos-atoms])
   (fn [[head-key pos-atoms]]
     (let [bound (vec (distinct (filter symbol? (mapcat :args pos-atoms))))
           bound-term (if (seq bound)
                        (gen/frequency [[4 (gen/elements bound)] [1 gen-const]])
                        gen-const)
           lower (filter #(< (stratum %) (stratum head-key)) preds)]
       (gen/let [head (gen-atom head-key bound-term)
                 negs (if (seq lower)
                        (gen/vector (gen/bind (gen/elements lower) #(gen-atom % bound-term)) 0 2)
                        (gen/return []))
                 cmps (gen/vector (gen/let [op (gen/elements [:< :<= :> :>= := :!=])
                                            l bound-term
                                            r bound-term]
                                    {:op :cmp :cmp op :left l :right r})
                                  0 2)
                 order (gen/shuffle (concat (map #(hash-map :op :pos :atom %) pos-atoms)
                                            (map #(hash-map :op :neg :atom %) negs)
                                            cmps))]
         {:head head :body (vec order)})))))

(def gen-program
  (gen/let [facts (gen/vector gen-fact 0 25)
            rules (gen/vector (gen-rule) 0 6)
            qs (gen/vector (gen/let [k (gen/elements preds)]
                             (gen-atom k (gen/frequency [[2 (gen/elements vars)] [1 gen-const]
                                                         [1 (gen/return '_)]])))
                           1 4)]
    {:rules (vec (concat facts rules)) :queries qs}))

(defn- match? [q tuple]
  (let [env (volatile! {})]
    (every? true?
            (map (fn [t v]
                   (cond (syn/anonymous? t) true
                         (symbol? t) (if-let [b (@env t)] (= b v) (do (vswap! env assoc t v) true))
                         :else (= t v)))
                 (:args q) tuple))))

(defspec engine-agrees-with-naive-evaluation 300
  (prop/for-all [program gen-program]
    (let [ref (reference-model program)
          model (dl/solve program)]
      (every? (fn [q]
                (let [expected (->> (ref (syn/atom-key q))
                                    (filter #(match? q %))
                                    (sort (fn [a b]
                                            (or (first (remove zero? (map syn/compare-constants a b))) 0)))
                                    vec)]
                  (= expected (dl/query model q))))
              (:queries program)))))

(deftest generated-programs-are-nontrivial
  (let [ps (gen/sample gen-program 60)]
    (is (some #(seq (mapcat val (reference-model %))) ps))))
