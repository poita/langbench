(ns minisql.eval
  "Interpreter for bound expressions (see `minisql.binder`).

  An expression is evaluated against an *environment*: a vector holding the
  current row of each table in scope (`[row-of-table-0 row-of-table-1]`).
  Aggregate calls are evaluated over a *group*: a sequence of environments.
  Evaluation never fails for data-dependent reasons: division by zero is NULL."
  (:require [minisql.like :as like]
            [minisql.value :as v]))

(defn- arith [f a b]
  (when (and (some? a) (some? b))
    (f (long a) (long b))))

(defn- divide [^long a ^long b] (when-not (zero? b) (quot a b)))
(defn- remainder [^long a ^long b] (when-not (zero? b) (rem a b)))

(defn- relation
  "NULL if either side is NULL, else 1/0 by applying `pred` to the sign of the
  three-way comparison."
  [pred a b]
  (when (and (some? a) (some? b))
    (if (pred (v/compare-values a b) 0) 1 0)))

(defn- as-text ^String [x]
  (if (string? x) x (v/render x)))

(declare evaluate)

(defn- aggregate [f arg group]
  (if (= arg :star)
    (long (count group))
    (let [vals (into [] (comp (map #(evaluate arg % nil)) (remove nil?)) group)]
      (case f
        :count (long (count vals))
        :sum (when (seq vals)
               (reduce (fn [a b] (unchecked-add (long a) (long b))) vals))
        :min (when (seq vals)
               (reduce (fn [a b] (if (neg? (v/compare-values b a)) b a)) vals))
        :max (when (seq vals)
               (reduce (fn [a b] (if (pos? (v/compare-values b a)) b a)) vals))
        :avg (when (seq vals)
               (v/average (reduce (fn [a b] (unchecked-add (long a) (long b))) 0 vals)
                          (count vals)))))))

(defn evaluate
  "Evaluate bound expression `e` in environment `env`.  `group` is the
  sequence of environments aggregate calls range over (nil outside
  aggregate queries)."
  [e env group]
  (case (nth e 0)
    :lit (nth e 1)
    :col (nth (nth env (nth e 1)) (nth e 2))
    :neg (let [x (evaluate (nth e 1) env group)]
           (when (some? x) (unchecked-negate (long x))))
    :add (arith unchecked-add (evaluate (nth e 1) env group) (evaluate (nth e 2) env group))
    :sub (arith unchecked-subtract (evaluate (nth e 1) env group) (evaluate (nth e 2) env group))
    :mul (arith unchecked-multiply (evaluate (nth e 1) env group) (evaluate (nth e 2) env group))
    :div (arith divide (evaluate (nth e 1) env group) (evaluate (nth e 2) env group))
    :mod (arith remainder (evaluate (nth e 1) env group) (evaluate (nth e 2) env group))
    :lt (relation < (evaluate (nth e 1) env group) (evaluate (nth e 2) env group))
    :le (relation <= (evaluate (nth e 1) env group) (evaluate (nth e 2) env group))
    :gt (relation > (evaluate (nth e 1) env group) (evaluate (nth e 2) env group))
    :ge (relation >= (evaluate (nth e 1) env group) (evaluate (nth e 2) env group))
    :eq (relation == (evaluate (nth e 1) env group) (evaluate (nth e 2) env group))
    :ne (relation not= (evaluate (nth e 1) env group) (evaluate (nth e 2) env group))
    :and (let [a (v/truth (evaluate (nth e 1) env group))]
           (if (false? a)
             0
             (let [b (v/truth (evaluate (nth e 2) env group))]
               (cond (false? b) 0
                     (and (true? a) (true? b)) 1
                     :else nil))))
    :or (let [a (v/truth (evaluate (nth e 1) env group))]
          (if (true? a)
            1
            (let [b (v/truth (evaluate (nth e 2) env group))]
              (cond (true? b) 1
                    (and (false? a) (false? b)) 0
                    :else nil))))
    :not (let [a (v/truth (evaluate (nth e 1) env group))]
           (v/bool->value (when (some? a) (not a))))
    :is-null (if (nil? (evaluate (nth e 1) env group)) 1 0)
    :is-not-null (if (nil? (evaluate (nth e 1) env group)) 0 1)
    :like (let [s (evaluate (nth e 1) env group)
                p (evaluate (nth e 2) env group)]
            (when (and (some? s) (some? p))
              (if (like/like? (as-text s) (as-text p)) 1 0)))
    :agg (aggregate (nth e 1) (nth e 2) group)))

(defn true-value?
  "True if the value `x` selects a row in WHERE / HAVING / ON context."
  [x]
  (true? (v/truth x)))
