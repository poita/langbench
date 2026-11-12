(ns toml.table
  "The mutable table tree used while a document is being read, and the
  resolution rules of TOML 1.0.0 section \"Tables\" (explicit, implicit,
  dotted and inline tables, arrays of tables).

  Once the whole document has been read, [[freeze]] converts the tree into the
  persistent tagged tree described in `toml.data`."
  (:require [toml.error :refer [fail]])
  (:import (java.util ArrayList HashMap)))

(set! *warn-on-reflection* true)

(definterface ITable
  (^java.util.HashMap entries [])
  (kind [])
  (setKind [k]))

(deftype Tbl [^HashMap m ^:unsynchronized-mutable kind]
  ITable
  (entries [_] m)
  (kind [_] kind)
  (setKind [_ k] (set! kind k) nil))

;; An array node; `aot?` is true for an array of tables made by `[[...]]`.
(deftype Arr [^ArrayList items aot?])

(defn new-table
  "Creates an empty table of the given kind: `:explicit` (opened by a header),
  `:implicit` (an intermediate header segment), `:dotted` (an intermediate
  dotted-key segment) or `:inline` (an inline-table literal)."
  ^Tbl [kind]
  (Tbl. (HashMap.) kind))

(defn new-array
  "Creates an empty array literal."
  ^Arr []
  (Arr. (ArrayList.) false))

(defn array-add! [^Arr a v] (.add ^ArrayList (.-items a) v) nil)

(defn- entries ^HashMap [^Tbl t] (.entries t))

(defn- kind [^Tbl t] (.kind t))

(defn- last-element [^Arr a]
  (let [^ArrayList l (.-items a)] (.get l (dec (.size l)))))

(defn- step-header
  "Resolves one intermediate segment of a header path."
  ^Tbl [^Tbl t ^String k pos]
  (let [v (.get (entries t) k)]
    (cond
      (nil? v) (let [n (new-table :implicit)] (.put (entries t) k n) n)
      (instance? Tbl v) (if (identical? :inline (kind v))
                          (fail (str "cannot extend inline table `" k "`") pos)
                          v)
      (and (instance? Arr v) (.-aot? ^Arr v)) (last-element v)
      :else (fail (str "key `" k "` is not a table") pos))))

(defn- walk-header ^Tbl [^Tbl root path pos]
  (loop [t root, i 0]
    (if (< i (dec (count path)))
      (recur (step-header t (nth path i) pos) (inc i))
      t)))

(defn open-table!
  "Handles a `[a.b.c]` header; returns the table that becomes current."
  [^Tbl root path pos]
  (let [t (walk-header root path pos)
        k ^String (peek path)
        v (.get (entries t) k)]
    (cond
      (nil? v) (let [n (new-table :explicit)] (.put (entries t) k n) n)
      (and (instance? Tbl v) (identical? :implicit (kind v)))
      (do (.setKind ^Tbl v :explicit) v)
      :else (fail (str "table `" k "` is already defined") pos))))

(defn open-array-table!
  "Handles a `[[a.b.c]]` header; appends a new table and returns it."
  [^Tbl root path pos]
  (let [t (walk-header root path pos)
        k ^String (peek path)
        v (.get (entries t) k)
        n (new-table :explicit)]
    (cond
      (nil? v) (let [a (Arr. (ArrayList.) true)]
                 (.add ^ArrayList (.-items a) n)
                 (.put (entries t) k a)
                 n)
      (and (instance? Arr v) (.-aot? ^Arr v))
      (do (.add ^ArrayList (.-items ^Arr v) n) n)
      :else (fail (str "`" k "` is already defined and is not an array of tables") pos))))

(defn assign!
  "Handles `a.b.c = value` inside table `t`."
  [^Tbl t path value pos]
  (let [last-i (dec (count path))
        t (loop [t t, i 0]
            (if (< i last-i)
              (let [^String k (nth path i)
                    v (.get (entries t) k)]
                (recur (cond
                         (nil? v) (let [n (new-table :dotted)] (.put (entries t) k n) n)
                         (and (instance? Tbl v)
                              (not (identical? :explicit (kind v)))
                              (not (identical? :inline (kind v)))) v
                         :else (fail (str "cannot extend `" k "` with a dotted key") pos))
                       (inc i)))
              t))
        ^String k (peek path)]
    (when (.containsKey (entries t) k)
      (fail (str "duplicate key `" k "`") pos))
    (.put (entries t) k value)
    nil))

(defn freeze
  "Converts a mutable node into the persistent tagged tree."
  [node]
  (cond
    (instance? Tbl node)
    (let [^HashMap m (entries node)]
      (loop [it (.iterator (.entrySet m)) out (transient {})]
        (if (.hasNext it)
          (let [^java.util.Map$Entry e (.next it)]
            (recur it (assoc! out (.getKey e) (freeze (.getValue e)))))
          (persistent! out))))

    (instance? Arr node)
    (let [^ArrayList l (.-items ^Arr node)]
      (loop [i 0 out (transient [])]
        (if (< i (.size l))
          (recur (inc i) (conj! out (freeze (.get l i))))
          (persistent! out))))

    :else node))
