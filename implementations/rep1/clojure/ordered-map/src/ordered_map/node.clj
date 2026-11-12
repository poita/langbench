(ns ordered-map.node
  "AVL tree nodes: an immutable node type augmented with subtree sizes, plus
  the rebalancing primitives that every structural update goes through.

  This is an implementation namespace; see `ordered-map.core` for the public
  API. A `nil` node is the empty tree."
  (:import (clojure.lang Util)))

(set! *warn-on-reflection* true)

(deftype Node [^long k v left right ^long height ^long size])

(defn height
  "Height of the tree rooted at `n` (0 for the empty tree)."
  ^long [^Node n]
  (if (nil? n) 0 (.-height n)))

(defn size
  "Number of keys in the tree rooted at `n`."
  ^long [^Node n]
  (if (nil? n) 0 (.-size n)))

(defn node
  "Builds a node, computing its height and size from its children."
  [^long k v ^Node l ^Node r]
  (Node. k v l r
         (unchecked-inc (Math/max (height l) (height r)))
         (unchecked-inc (unchecked-add (size l) (size r)))))

(defn- balance-factor ^long [^Node n]
  (unchecked-subtract (height (.-left n)) (height (.-right n))))

(defn- rotate-right [^Node n]
  (let [^Node l (.-left n)]
    (node (.-k l) (.-v l) (.-left l)
          (node (.-k n) (.-v n) (.-right l) (.-right n)))))

(defn- rotate-left [^Node n]
  (let [^Node r (.-right n)]
    (node (.-k r) (.-v r)
          (node (.-k n) (.-v n) (.-left n) (.-left r))
          (.-right r))))

(defn balance
  "Builds a node from key `k`, value `v` and subtrees `l` and `r`, which are
  AVL trees whose heights differ by at most 2, restoring the AVL invariant
  with at most two rotations."
  [^long k v ^Node l ^Node r]
  (let [d (unchecked-subtract (height l) (height r))]
    (cond
      (> d 1)
      (let [^Node l (if (< (balance-factor l) 0) (rotate-left l) l)]
        (rotate-right (node k v l r)))

      (< d -1)
      (let [^Node r (if (> (balance-factor r) 0) (rotate-right r) r)]
        (rotate-left (node k v l r)))

      :else (node k v l r))))
