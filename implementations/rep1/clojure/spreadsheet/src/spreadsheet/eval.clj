(ns spreadsheet.eval
  "Evaluation of syntax trees (see `spreadsheet.parser`).

  Values are: a double (number), a string, an error keyword
  (`:error/div0`, `:error/ref`, `:error/cycle`, `:error/value`) or nil
  (empty). References read the *stored* value of the cell they name from the
  `cells` map (`{id {:value v ...}}`); they never evaluate other cells."
  (:require [spreadsheet.cell :as cell]
            [spreadsheet.format :as fmt]))

(declare ev)

(defn- finite-or-value [^double r]
  (if (or (Double/isInfinite r) (Double/isNaN r)) :error/value r))

(defn- as-number
  "Coerces an evaluated operand for arithmetic: a number, or an error keyword."
  [v]
  (cond (nil? v) 0.0
        (string? v) :error/value
        :else v))

(defn- compare-code-points
  "Compares two strings by Unicode code point."
  ^long [^String a ^String b]
  (let [la (.length a) lb (.length b)]
    (loop [i 0 j 0]
      (cond
        (and (>= i la) (>= j lb)) 0
        (>= i la) -1
        (>= j lb) 1
        :else
        (let [ca (.codePointAt a i) cb (.codePointAt b j)]
          (if (== ca cb)
            (recur (+ i (Character/charCount ca)) (+ j (Character/charCount cb)))
            (if (< ca cb) -1 1)))))))

(defn- arith [op a b]
  (let [a (as-number a)]
    (if (keyword? a)
      a
      (let [b (as-number b)]
        (if (keyword? b)
          b
          (let [^double x a ^double y b]
            (case op
              :+ (finite-or-value (+ x y))
              :- (finite-or-value (- x y))
              :* (finite-or-value (* x y))
              :/ (if (== y 0.0) :error/div0 (finite-or-value (/ x y))))))))))

(defn- text-of [v]
  (cond (nil? v) "" (string? v) v :else (fmt/display v)))

(defn- compare-values [op a b]
  (let [[a b] (cond
                (and (nil? a) (nil? b)) [0.0 0.0]
                (nil? a) [(if (string? b) "" 0.0) b]
                (nil? b) [a (if (string? a) "" 0.0)]
                :else [a b])]
    (if (not= (string? a) (string? b))
      (case op :eq 0.0 :ne 1.0 :error/value)
      (let [c (if (string? a)
                (compare-code-points a b)
                (let [^double x a ^double y b] (cond (< x y) -1 (> x y) 1 :else 0)))]
        (if (case op
              :eq (zero? c) :ne (not (zero? c)) :lt (neg? c)
              :gt (pos? c) :le (<= c 0) :ge (>= c 0))
          1.0 0.0)))))

(defn- aggregate
  "Evaluates an aggregate over `args`; `fn-key` is :sum :min :max :avg or :count."
  [cells fn-key args]
  (let [acc (double-array 4)               ; count, sum, min, max
        add! (fn [^double x]
               (let [n (aget acc 0)]
                 (aset acc 1 (+ (aget acc 1) x))
                 (when (or (== n 0.0) (< x (aget acc 2))) (aset acc 2 x))
                 (when (or (== n 0.0) (> x (aget acc 3))) (aset acc 3 x))
                 (aset acc 0 (inc n))
                 nil))
        err (reduce
             (fn [_ arg]
               (if (= :range (nth arg 0))
                 (let [[_ r1 c1 r2 c2] arg]
                   (loop [r (long r1) c (long c1)]
                     (cond
                       (> r (long r2)) nil
                       (> c (long c2)) (recur (inc r) (long c1))
                       :else
                       (let [v (:value (get cells (cell/->id c r)))]
                         (cond
                           (keyword? v) (reduced v)
                           (number? v) (do (add! v) (recur r (inc c)))
                           :else (recur r (inc c)))))))
                 (let [v (ev cells arg)]
                   (cond
                     (keyword? v) (reduced v)
                     (string? v) (reduced :error/value)
                     (nil? v) nil
                     :else (add! v)))))
             nil args)]
    (or err
        (let [n (aget acc 0) sum (aget acc 1)]
          (case fn-key
            :count n
            :sum (finite-or-value sum)
            :min (if (== n 0.0) 0.0 (aget acc 2))
            :max (if (== n 0.0) 0.0 (aget acc 3))
            :avg (if (== n 0.0) :error/div0 (finite-or-value (/ sum n))))))))

(defn ev
  "Evaluates syntax tree `node` against the stored values in `cells`."
  [cells node]
  (case (nth node 0)
    :num (nth node 1)
    :str (nth node 1)
    :err (nth node 1)
    :ref (:value (get cells (nth node 1)))
    :neg (let [v (as-number (ev cells (nth node 1)))]
           (if (keyword? v) v (- ^double v)))
    :arith (let [a (ev cells (nth node 2))]
             (if (keyword? a)
               a
               (if (string? a)
                 :error/value
                 (let [b (ev cells (nth node 3))]
                   (if (keyword? b) b (arith (nth node 1) a b))))))
    :cat (let [a (ev cells (nth node 1))]
           (if (keyword? a)
             a
             (let [b (ev cells (nth node 2))]
               (if (keyword? b) b (str (text-of a) (text-of b))))))
    :cmp (let [a (ev cells (nth node 2))]
           (if (keyword? a)
             a
             (let [b (ev cells (nth node 3))]
               (if (keyword? b) b (compare-values (nth node 1) a b)))))
    :if (let [c (as-number (ev cells (nth node 1)))]
          (cond
            (keyword? c) c
            (== ^double c 0.0) (ev cells (nth node 3))
            :else (ev cells (nth node 2))))
    :agg (aggregate cells (nth node 1) (nth node 2))))
