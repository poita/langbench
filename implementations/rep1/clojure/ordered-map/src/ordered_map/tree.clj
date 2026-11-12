(ns ordered-map.tree
  "Persistent insertion and deletion on AVL trees of `ordered-map.node/Node`.
  Every function takes and returns the root of a tree (`nil` = empty). All
  updates are O(log n) and share structure with the input tree."
  (:require [ordered-map.node :as n :refer [balance node]])
  (:import (ordered_map.node Node)))

(set! *warn-on-reflection* true)

(defn insert
  "Returns the tree with key `k` mapped to `v`, replacing any existing value."
  ^Node [^Node t ^long k v]
  (if (nil? t)
    (node k v nil nil)
    (let [tk (.-k t)]
      (cond
        (< k tk) (balance tk (.-v t) (insert (.-left t) k v) (.-right t))
        (> k tk) (balance tk (.-v t) (.-left t) (insert (.-right t) k v))
        :else    (node k v (.-left t) (.-right t))))))

(defn- remove-min
  "Returns `t` without its smallest key. `t` must not be empty."
  ^Node [^Node t]
  (let [l (.-left t)]
    (if (nil? l)
      (.-right t)
      (balance (.-k t) (.-v t) (remove-min l) (.-right t)))))

(defn- leftmost ^Node [^Node t]
  (loop [t t]
    (let [l (.-left t)]
      (if (nil? l) t (recur l)))))

(defn- join-children
  "Merges the two subtrees of a deleted node into one balanced tree."
  ^Node [^Node l ^Node r]
  (cond
    (nil? l) r
    (nil? r) l
    :else (let [^Node m (leftmost r)]
            (balance (.-k m) (.-v m) l (remove-min r)))))

(defn delete
  "Returns the tree without key `k`; `t` itself if `k` is absent."
  ^Node [^Node t ^long k]
  (if (nil? t)
    nil
    (let [tk (.-k t)]
      (cond
        (< k tk) (let [l (.-left t) l' (delete l k)]
                   (if (identical? l l')
                     t
                     (balance tk (.-v t) l' (.-right t))))
        (> k tk) (let [r (.-right t) r' (delete r k)]
                   (if (identical? r r')
                     t
                     (balance tk (.-v t) (.-left t) r')))
        :else    (join-children (.-left t) (.-right t))))))
