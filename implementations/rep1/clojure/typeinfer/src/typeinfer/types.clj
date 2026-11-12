(ns typeinfer.types
  "Type representation and the core of Algorithm J: unification, level-based
  generalisation and instantiation.

  Types are a shared graph (a DAG):

  * `TVar` is a union-find node: an unbound variable has a nil `link`; binding
    a variable sets its link. Every variable carries a *level* (Rémy), the
    nesting depth of the `let` at which it was created or the shallowest
    level it has been unified with. A variable whose level is `generic` is
    quantified in the scheme that contains it.
  * `TCon` is a type constructor (`:int :bool :unit :arrow :list :tuple`)
    applied to a vector of argument types.

  Every walk over a type (occurs check, generalisation, instantiation,
  unification) visits each *distinct* node once per walk, using a per-walk
  epoch stamp stored on the node, so shared types are never expanded to
  trees. The stamps only record what the current walk has already done; no
  level or other summary is cached for use by later walks.

  Errors are signalled with `ex-info` whose data is `{:kind k}` where `k` is
  `:unify` or `:occurs`."
  (:import (java.util.concurrent.atomic AtomicLong)))

(set! *warn-on-reflection* true)

(def ^:const generic
  "The level of a quantified (generic) type variable."
  Long/MAX_VALUE)

(definterface IVar
  (^long getLevel [])
  (setLevel [^long l])
  (getLink [])
  (setLink [t]))

(definterface IMemo
  (^long getMark [])
  (setMark [^long m])
  (getCopy [])
  (setCopy [c]))

(deftype TVar [^:unsynchronized-mutable ^long level
               ^:unsynchronized-mutable link
               ^:unsynchronized-mutable ^long mark
               ^:unsynchronized-mutable copy]
  IVar
  (getLevel [_] level)
  (setLevel [_ l] (set! level l))
  (getLink [_] link)
  (setLink [_ t] (set! link t))
  IMemo
  (getMark [_] mark)
  (setMark [_ m] (set! mark m))
  (getCopy [_] copy)
  (setCopy [_ c] (set! copy c)))

(deftype TCon [tag
               ^clojure.lang.IPersistentVector args
               ^:unsynchronized-mutable ^long mark
               ^:unsynchronized-mutable copy]
  IMemo
  (getMark [_] mark)
  (setMark [_ m] (set! mark m))
  (getCopy [_] copy)
  (setCopy [_ c] (set! copy c)))

(defn tvar?  [t] (instance? TVar t))

(defn fresh-var
  "A fresh unbound type variable at `level`."
  [^long level]
  (->TVar level nil 0 nil))

(defn generic-var
  "A fresh quantified variable, for building type schemes."
  []
  (fresh-var generic))

(defn tcon
  "Construct a constructor type `tag` applied to the vector `args`."
  [tag args]
  (->TCon tag args 0 nil))

(def int-type  (tcon :int []))
(def bool-type (tcon :bool []))
(def unit-type (tcon :unit []))

(defn arrow [a b] (tcon :arrow [a b]))
(defn list-of [t] (tcon :list [t]))
(defn tuple-of [ts] (tcon :tuple (vec ts)))

(defn tag  [^TCon t] (.-tag t))
(defn args [^TCon t] (.-args t))

;; ---------------------------------------------------------------------------
;; Union-find

(defn prune
  "Follow variable links to the representative of `t`, compressing the path."
  [t]
  (if (instance? TVar t)
    (let [root (loop [t t]
                 (let [l (.getLink ^TVar t)]
                   (if (and l (instance? TVar l)) (recur l) (or l t))))]
      ;; Path compression: point every variable on the chain at the root.
      (loop [t t]
        (when (and (instance? TVar t) (not (identical? t root)))
          (let [l (.getLink ^TVar t)]
            (.setLink ^TVar t root)
            (recur l))))
      root)
    t))

(defn level
  "The level of the variable `v`."
  ^long [v]
  (.getLevel ^TVar v))

(defonce ^:private ^AtomicLong epochs (AtomicLong. 0))

(defn- new-epoch ^long [] (.incrementAndGet epochs))

(defn- fail [kind]
  (throw (ex-info (name kind) {:kind kind})))

;; ---------------------------------------------------------------------------
;; Unification

(defn- bind!
  "Bind the unbound variable `v` to `t` (both pruned, `t` not `v`), failing if
  `v` occurs in `t`, and lower the levels of the variables of `t` to `v`'s."
  [^TVar v t]
  (let [lvl (.getLevel v)]
    (if (instance? TVar t)
      (when (> (.getLevel ^TVar t) lvl) (.setLevel ^TVar t lvl))
      (let [ep (new-epoch)]
        ((fn walk [t]
           (let [t (prune t)]
             (if (instance? TVar t)
               (do (when (identical? t v) (fail :occurs))
                   (when (> (.getLevel ^TVar t) lvl) (.setLevel ^TVar t lvl)))
               (let [^TCon c t]
                 (when-not (== (.getMark c) ep)
                   (.setMark c ep)
                   (doseq [a (.-args c)] (walk a)))))))
         t)))
    (.setLink v t)))

(defn- unify* [a b ^long ep]
  (let [a (prune a)
        b (prune b)]
    (cond
      (identical? a b) nil
      (instance? TVar a) (bind! a b)
      (instance? TVar b) (bind! b a)
      :else
      (let [^TCon ca a
            ^TCon cb b]
        ;; (mark, copy) of `ca` remembers "already unified with `cb`" during
        ;; this call, so a shared pair of sub-DAGs is walked only once.
        (when-not (and (== (.getMark ca) ep) (identical? (.getCopy ca) cb))
          (let [xs (.-args ca)
                ys (.-args cb)
                n (count xs)]
            (when-not (and (identical? (.-tag ca) (.-tag cb)) (== n (count ys)))
              (fail :unify))
            (.setMark ca ep)
            (.setCopy ca cb)
            (loop [i 0]
              (when (< i n)
                (unify* (nth xs i) (nth ys i) ep)
                (recur (inc i))))))))))

(defn unify
  "Unify types `a` and `b` in place. Components are unified left to right,
  each completely before the next; the occurs check runs whenever a variable
  is bound. Throws `{:kind :unify}` or `{:kind :occurs}`."
  [a b]
  (unify* a b (new-epoch)))

;; ---------------------------------------------------------------------------
;; Generalisation and instantiation

(defn generalize!
  "Quantify every unbound variable reachable from `t` whose level is greater
  than `lvl`, by setting its level to `generic`. Visits each distinct node of
  `t` once; never looks at an environment."
  [t ^long lvl]
  (let [ep (new-epoch)]
    ((fn walk [t]
       (let [t (prune t)]
         (if (instance? TVar t)
           (when (> (.getLevel ^TVar t) lvl) (.setLevel ^TVar t generic))
           (let [^TCon c t]
             (when-not (== (.getMark c) ep)
               (.setMark c ep)
               (doseq [a (.-args c)] (walk a)))))))
     t)
    nil))

(defn instantiate
  "Copy `t`, replacing each generic variable by a fresh variable at `lvl`
  (one fresh variable per generic variable). Every distinct node is visited
  once; sub-terms that contain no generic variable are shared, not copied,
  and the sharing of `t` is preserved in the copy."
  [t ^long lvl]
  (let [ep (new-epoch)]
    ((fn walk [t]
       (let [t (prune t)]
         (if (instance? TVar t)
           (let [^TVar v t]
             (if (== (.getLevel v) generic)
               (if (== (.getMark v) ep)
                 (.getCopy v)
                 (let [f (fresh-var lvl)]
                   (.setMark v ep)
                   (.setCopy v f)
                   f))
               v))
           (let [^TCon c t]
             (if (== (.getMark c) ep)
               (.getCopy c)
               (let [xs (.-args c)
                     n (count xs)
                     ys (loop [i 0, acc (transient [])]
                          (if (< i n)
                            (recur (inc i) (conj! acc (walk (nth xs i))))
                            (persistent! acc)))
                     same? (loop [i 0]
                             (or (== i n)
                                 (and (identical? (nth ys i) (prune (nth xs i)))
                                      (recur (inc i)))))
                     r (if same? c (->TCon (.-tag c) ys 0 nil))]
                 (.setMark c ep)
                 (.setCopy c r)
                 r))))))
     t)))
