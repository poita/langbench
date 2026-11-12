(ns sitegen.mutable
  "A tiny helper for the few places where a parser genuinely needs mutable,
  pointer-linked nodes (the Markdown block tree, the inline node list and the
  delimiter stack).  Everything built on top of it keeps the mutation private
  to one parsing run; nothing mutable escapes through the public API.")

(defmacro defmutable
  "Defines a mutable record-like type.

  `(defmutable Node node- [kind parent next])` defines the type `Node`, a
  constructor `(->Node kind parent next)` and, for every field `f`, an accessor
  `(node-f n)` and a mutator `(node-f! n v)` (which returns `v`).  All fields
  are plain objects."
  [tname prefix fields]
  (let [munged  (fn [f] (clojure.lang.Compiler/munge (name f)))
        getter  (fn [f] (symbol (str "get_" (munged f))))
        setter  (fn [f] (symbol (str "set_" (munged f))))
        iface   (symbol (str "I" tname))
        obj     (with-meta 'o {:tag tname})]
    `(do
       (definterface ~iface
         ~@(mapcat (fn [f] [(list (getter f) []) (list (setter f) '[v])]) fields))
       (deftype ~tname ~(mapv #(vary-meta % assoc :unsynchronized-mutable true) fields)
         ~iface
         ~@(mapcat (fn [f]
                     [(list (getter f) '[_] f)
                      (list (setter f) '[_ v] (list 'set! f 'v) 'v)])
                   fields))
       ~@(mapcat (fn [f]
                   [`(defn ~(symbol (str prefix (name f)))
                       [~obj] (. ~'o ~(getter f)))
                    `(defn ~(symbol (str prefix (name f) "!"))
                       [~obj ~'v] (. ~'o ~(setter f) ~'v))])
                 fields))))
