(ns template.scope
  "Lexical scopes: a mutable name->value table plus a parent. Creating a scope
  is O(1); a lookup costs O(chain depth)."
  (:require [template.values :as v])
  (:import (java.util HashMap)))

(set! *warn-on-reflection* true)

(deftype Scope [^HashMap vars parent])

(def ^:private not-found (Object.))

(defn new-scope
  "A fresh empty scope below `parent` (which may be nil)."
  [parent]
  (Scope. (HashMap.) parent))

(defn scope-over
  "A scope whose table is `vars` itself (not copied), below `parent`."
  [^HashMap vars parent]
  (Scope. vars parent))

(defn bind!
  "Bind `name` to `value` in `scope` itself."
  [^Scope scope ^String name value]
  (.put ^HashMap (.-vars scope) name value)
  nil)

(defn lookup
  "The value bound to `name` in `scope` or an ancestor, else undefined."
  [^Scope scope ^String name]
  (loop [s scope]
    (if (nil? s)
      v/undefined
      (let [val (.getOrDefault ^HashMap (.-vars ^Scope s) name not-found)]
        (if (identical? val not-found)
          (recur (.-parent ^Scope s))
          val)))))

(defn bound-here?
  "True when `name` is bound in `scope` itself."
  [^Scope scope ^String name]
  (.containsKey ^HashMap (.-vars scope) name))
