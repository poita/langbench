(ns kvstore.btree
  "Canonical-page B+trees (spec sections 11 and 12).

  A *tree* is a small map describing where its root pointer lives:

      {:leaf-type 1|5, :get-root (fn [pager] root), :set-root! (fn [pager root])}

  `primary-tree` and `slot-tree` build the two kinds.  A decoded page is
  `{:type t :link n :cells [...]}` with cells in key order:

  | page type    | cell                                                  |
  |--------------|-------------------------------------------------------|
  | 1 primary    | `{:key :doc-len :inline :overflow}`                   |
  | 2 interior   | `{:key :child}`                                       |
  | 5 index leaf | `{:key}`                                              |

  Keys are byte arrays compared unsigned byte-wise."
  (:require [kvstore.bytes :as b]
            [kvstore.freelist :as fl]
            [kvstore.header :as h]
            [kvstore.limits :as lim]
            [kvstore.pager :as pager]))

(set! *warn-on-reflection* true)

(def ^:const primary-leaf 1)
(def ^:const interior 2)
(def ^:const index-leaf 5)

;; ---------------------------------------------------------------------------
;; Canonical page codec

(defn- cell-size
  ^long [^long type cell]
  (let [klen (alength ^bytes (:key cell))]
    (case (int type)
      1 (+ 12 klen (alength ^bytes (:inline cell)))
      2 (+ 6 klen)
      5 (+ 2 klen))))

(defn used
  "Payload size of a node: 2n plus the cell sizes."
  ^long [{:keys [type cells]}]
  (let [t (long type)]
    (reduce (fn [^long acc c] (+ acc 2 (cell-size t c))) 0 cells)))

(defn- decode-cell [^long type ^bytes pg ^long off]
  (let [klen (b/u16 pg off)]
    (case (int type)
      1 (let [inline-len (b/u16 pg (+ off 6))
              kstart (+ off 12)]
          {:key (b/sub pg kstart (+ kstart klen))
           :doc-len (b/u32 pg (+ off 2))
           :inline (b/sub pg (+ kstart klen) (+ kstart klen inline-len))
           :overflow (b/u32 pg (+ off 8))})
      2 {:key (b/sub pg (+ off 6) (+ off 6 klen))
         :child (b/u32 pg (+ off 2))}
      5 {:key (b/sub pg (+ off 2) (+ off 2 klen))})))

(defn decode-page
  "Decode a B+tree page image into a node."
  [^bytes pg]
  (let [type (b/u8 pg 0)
        n (b/u16 pg 2)]
    {:type type
     :link (b/u32 pg 8)
     :cells (loop [i 0 acc (transient [])]
              (if (< i n)
                (recur (inc i) (conj! acc (decode-cell type pg (b/u16 pg (+ 16 (* 2 i))))))
                (persistent! acc)))}))

(defn- encode-cell! [^long type ^bytes pg ^long off cell]
  (let [^bytes k (:key cell)
        klen (alength k)]
    (b/put-u16! pg off klen)
    (case (int type)
      1 (let [^bytes inl (:inline cell)]
          (b/put-u32! pg (+ off 2) (:doc-len cell))
          (b/put-u16! pg (+ off 6) (alength inl))
          (b/put-u32! pg (+ off 8) (:overflow cell))
          (b/put-bytes! pg (+ off 12) k)
          (b/put-bytes! pg (+ off 12 klen) inl))
      2 (do (b/put-u32! pg (+ off 2) (:child cell))
            (b/put-bytes! pg (+ off 6) k))
      5 (b/put-bytes! pg (+ off 2) k))))

(defn encode-page
  "Encode a node as its canonical 1024-byte image."
  ^bytes [{:keys [type link cells] :as node}]
  (let [t (long type)
        pg (byte-array lim/page-size)
        n (count cells)
        total (reduce (fn [^long acc c] (+ acc (cell-size t c))) 0 cells)
        start (- lim/page-size total)]
    (b/put-u8! pg 0 t)
    (b/put-u16! pg 2 n)
    (b/put-u16! pg 4 start)
    (b/put-u32! pg 8 link)
    (loop [i 0 off start cs (seq cells)]
      (when cs
        (let [c (first cs)]
          (b/put-u16! pg (+ 16 (* 2 i)) off)
          (encode-cell! t pg off c)
          (recur (inc i) (+ off (cell-size t c)) (next cs)))))
    pg))

(defn read-node [pg ^long page-no]
  (decode-page (pager/read-page pg page-no)))

(defn write-node! [pg ^long page-no node]
  (pager/write-page! pg page-no (encode-page node)))

;; ---------------------------------------------------------------------------
;; Tree handles

(defn primary-tree
  "The primary tree, rooted at the header's `primary_root`."
  []
  {:leaf-type primary-leaf
   :get-root (fn [pg] (h/get-field pg :primary-root))
   :set-root! (fn [pg r] (h/set-field! pg :primary-root r))})

(defn slot-tree
  "The index tree of directory slot `s`."
  [^long s]
  {:leaf-type index-leaf
   :get-root (fn [pg] (:root (h/read-slot pg s)))
   :set-root! (fn [pg r] (h/set-slot-root! pg s r))})

(defn- root-of ^long [pg tree] ((:get-root tree) pg))
(defn- set-root! [pg tree r] ((:set-root! tree) pg r))

;; ---------------------------------------------------------------------------
;; Searching

(defn- lower-bound
  "Smallest index `i` whose cell key is >= `key` (n when none)."
  ^long [cells ^bytes key]
  (loop [lo 0 hi (count cells)]
    (if (< lo hi)
      (let [mid (quot (+ lo hi) 2)]
        (if (neg? (b/compare-bytes (:key (nth cells mid)) key))
          (recur (inc mid) hi)
          (recur lo mid)))
      lo)))

(defn- child-index
  "Index of the child to descend into for `key`: the smallest `i` with
  `key <= k[i]`, or n (the link)."
  ^long [node key]
  (lower-bound (:cells node) key))

(defn- child-at ^long [node ^long i]
  (let [cells (:cells node)]
    (if (< i (count cells)) (:child (nth cells i)) (:link node))))

(defn- descend
  "Walk from the root to the leaf for `key` (nil = leftmost leaf).  Returns
  `{:path [[page-no node idx] ...] :page-no :node}` for the leaf."
  [pg tree key]
  (loop [page-no (root-of pg tree) path []]
    (let [node (read-node pg page-no)]
      (if (== (long (:type node)) interior)
        (let [i (if key (child-index node key) 0)]
          (recur (child-at node i) (conj path [page-no node i])))
        {:path path :page-no page-no :node node}))))

(defn search
  "The leaf cell for `key`, or nil."
  [pg tree ^bytes key]
  (when-not (zero? (root-of pg tree))
    (let [{:keys [node]} (descend pg tree key)
          cells (:cells node)
          i (lower-bound cells key)]
      (when (and (< i (count cells)) (b/bytes= (:key (nth cells i)) key))
        (nth cells i)))))

(defn height
  "Height of the tree: 0 when empty, 1 for a lone leaf."
  ^long [pg tree]
  (loop [page-no (root-of pg tree) n 0]
    (if (zero? page-no)
      n
      (let [node (read-node pg page-no)]
        (if (== (long (:type node)) interior)
          (recur (child-at node 0) (inc n))
          (inc n))))))

(defn cells-from
  "Lazy sequence of leaf cells in ascending key order, starting at the first
  cell with key >= `from` (all cells when `from` is nil).  One descent, then
  the leaf chain."
  [pg tree from]
  (if (zero? (root-of pg tree))
    ()
    (let [{:keys [node]} (descend pg tree from)
          start (if from (lower-bound (:cells node) from) 0)
          leaf-seq (fn leaf-seq [node start]
                     (lazy-seq
                      (let [cells (:cells node)
                            here (if (pos? start) (subvec cells (min start (count cells))) cells)
                            link (:link node)]
                        (concat here
                                (when (pos? link)
                                  (leaf-seq (read-node pg link) 0))))))]
      (leaf-seq node start))))

(defn- reverse-leaves
  "Lazy sequence of leaf nodes in descending key order, covering all keys
  below `upper` (nil = unbounded)."
  [pg page-no upper]
  (lazy-seq
   (let [node (read-node pg page-no)]
     (if (== (long (:type node)) interior)
       (let [n (count (:cells node))
             i0 (if upper (child-index node upper) n)]
         (apply concat
                (map (fn [i] (reverse-leaves pg (child-at node i) (when (== i i0) upper)))
                     (range i0 -1 -1))))
       (list [node upper])))))

(defn cells-below
  "Lazy sequence of leaf cells in descending key order with key < `upper`
  (all cells when `upper` is nil)."
  [pg tree upper]
  (if (zero? (root-of pg tree))
    ()
    (mapcat (fn [[node up]]
              (let [cells (rseq (:cells node))]
                (if up
                  (filter #(neg? (b/compare-bytes (:key %) up)) cells)
                  cells)))
            (reverse-leaves pg (root-of pg tree) upper))))

;; ---------------------------------------------------------------------------
;; Insertion and splitting

(defn- insert-at [cells ^long i cell]
  (into (conj (subvec cells 0 i) cell) (subvec cells i)))

(defn- split-point
  "Smallest m in 1..n-1 with 2*P[m] >= T (spec 12.3)."
  ^long [^long type cells]
  (let [ws (mapv #(+ 2 (cell-size type %)) cells)
        total (reduce + ws)]
    (loop [m 1 p (long (first ws))]
      (if (>= (* 2 p) total)
        m
        (recur (inc m) (+ p (long (nth ws m))))))))

(defn- store!
  "Write `node` as page `page-no`; when it overflows split it and install the
  separator in the parent (the top of `path`), cascading upward."
  [pg tree path page-no node]
  (if (<= (used node) lim/capacity)
    (write-node! pg page-no node)
    (let [type (long (:type node))
          cells (:cells node)
          m (split-point type cells)
          right-no (fl/allocate! pg)
          leaf? (not= type interior)
          promoted (nth cells (dec m))
          right (assoc node :cells (subvec cells m))
          left (if leaf?
                 (assoc node :cells (subvec cells 0 m) :link right-no)
                 (assoc node :cells (subvec cells 0 (dec m)) :link (:child promoted)))
          sep (:key promoted)]
      (write-node! pg right-no right)
      (write-node! pg page-no left)
      (if (empty? path)
        (let [new-root (fl/allocate! pg)]
          (write-node! pg new-root {:type interior :link right-no
                                    :cells [{:key sep :child page-no}]})
          (set-root! pg tree new-root))
        (let [[parent-no parent j] (peek path)
              cells (:cells parent)
              parent' (if (== (long j) (count cells))
                        (assoc parent :cells (conj cells {:key sep :child page-no}) :link right-no)
                        (assoc parent :cells (insert-at (assoc-in cells [j :child] right-no)
                                                        j {:key sep :child page-no})))]
          (store! pg tree (pop path) parent-no parent'))))))

(defn insert!
  "Insert `cell`, replacing a cell with the same key in place."
  [pg tree cell]
  (let [key (:key cell)]
    (when (zero? (root-of pg tree))
      (let [r (fl/allocate! pg)]
        (write-node! pg r {:type (:leaf-type tree) :link 0 :cells []})
        (set-root! pg tree r)))
    (let [{:keys [path page-no node]} (descend pg tree key)
          cells (:cells node)
          i (lower-bound cells key)
          node' (if (and (< i (count cells)) (b/bytes= (:key (nth cells i)) key))
                  (assoc node :cells (assoc cells i cell))
                  (assoc node :cells (insert-at cells i cell)))]
      (store! pg tree path page-no node'))))

;; ---------------------------------------------------------------------------
;; Deletion and rebalancing

(declare repair!)

(defn- remove-at [cells ^long i]
  (into (subvec cells 0 i) (subvec cells (inc i))))

(defn- collapse-or-repair!
  "After a merge removed a cell from the parent (already written)."
  [pg tree path-above p-no p-node]
  (cond
    (empty? path-above)
    (when (empty? (:cells p-node))
      (set-root! pg tree (:link p-node))
      (fl/free! pg p-no))

    (>= (used p-node) lim/min-fill) nil

    :else (repair! pg tree path-above p-no p-node)))

(defn- repair!
  "Rebalance underflowing node `n-no`/`n-node` whose parent is the top of
  `path` (spec 12.5): borrow left, borrow right, merge left, merge right."
  [pg tree path n-no n-node]
  (let [[p-no p-node j] (peek path)
        j (long j)
        above (pop path)
        pcells (:cells p-node)
        np (count pcells)
        leaf? (not= (long (:type n-node)) interior)
        l-no (when (>= j 1) (child-at p-node (dec j)))
        r-no (when (< j np) (child-at p-node (inc j)))
        l-node (when l-no (read-node pg l-no))
        r-node (when r-no (read-node pg r-no))
        cost (fn [c] (+ 2 (cell-size (:type n-node) c)))]
    (cond
      ;; borrow from the left
      (and l-node (>= (- (used l-node) (cost (peek (:cells l-node)))) lim/min-fill))
      (let [lcells (:cells l-node)
            lc (peek lcells)
            lcells' (pop lcells)
            sep-key (:key (nth pcells (dec j)))
            [l' n'] (if leaf?
                      [(assoc l-node :cells lcells')
                       (assoc n-node :cells (into [lc] (:cells n-node)))]
                      [(assoc l-node :cells lcells' :link (:child lc))
                       (assoc n-node :cells (into [{:key sep-key :child (:link l-node)}] (:cells n-node)))])
            new-sep (:key (if leaf? (peek lcells') lc))
            p' (assoc p-node :cells (assoc-in pcells [(dec j) :key] new-sep))]
        (write-node! pg l-no l')
        (write-node! pg n-no n')
        (store! pg tree above p-no p'))

      ;; borrow from the right
      (and r-node (>= (- (used r-node) (cost (first (:cells r-node)))) lim/min-fill))
      (let [rcells (:cells r-node)
            rc (first rcells)
            rcells' (subvec rcells 1)
            sep-key (:key (nth pcells j))
            [r' n'] (if leaf?
                      [(assoc r-node :cells rcells')
                       (assoc n-node :cells (conj (:cells n-node) rc))]
                      [(assoc r-node :cells rcells')
                       (assoc n-node :cells (conj (:cells n-node) {:key sep-key :child (:link n-node)})
                              :link (:child rc))])
            new-sep (:key rc)
            p' (assoc p-node :cells (assoc-in pcells [j :key] new-sep))]
        (write-node! pg r-no r')
        (write-node! pg n-no n')
        (store! pg tree above p-no p'))

      ;; merge with the left: L survives, N is freed
      l-node
      (let [sep-key (:key (nth pcells (dec j)))
            merged (if leaf?
                     (assoc l-node :cells (into (:cells l-node) (:cells n-node)) :link (:link n-node))
                     (assoc l-node :cells (-> (:cells l-node)
                                              (conj {:key sep-key :child (:link l-node)})
                                              (into (:cells n-node)))
                            :link (:link n-node)))
            pcells' (remove-at pcells (dec j))
            p' (if (== j np)
                 (assoc p-node :cells pcells' :link l-no)
                 (assoc p-node :cells (assoc-in pcells' [(dec j) :child] l-no)))]
        (write-node! pg l-no merged)
        (write-node! pg p-no p')
        (fl/free! pg n-no)
        (collapse-or-repair! pg tree above p-no p'))

      ;; merge with the right: N survives, R is freed
      :else
      (let [sep-key (:key (nth pcells j))
            merged (if leaf?
                     (assoc n-node :cells (into (:cells n-node) (:cells r-node)) :link (:link r-node))
                     (assoc n-node :cells (-> (:cells n-node)
                                              (conj {:key sep-key :child (:link n-node)})
                                              (into (:cells r-node)))
                            :link (:link r-node)))
            pcells' (remove-at pcells j)
            p' (if (== (inc j) np)
                 (assoc p-node :cells pcells' :link n-no)
                 (assoc p-node :cells (assoc-in pcells' [j :child] n-no)))]
        (write-node! pg n-no merged)
        (write-node! pg p-no p')
        (fl/free! pg r-no)
        (collapse-or-repair! pg tree above p-no p')))))

(defn delete!
  "Delete `key`.  Returns false (changing nothing) when it is absent."
  [pg tree ^bytes key]
  (if (zero? (root-of pg tree))
    false
    (let [{:keys [path page-no node]} (descend pg tree key)
          cells (:cells node)
          i (lower-bound cells key)]
      (if-not (and (< i (count cells)) (b/bytes= (:key (nth cells i)) key))
        false
        (let [node' (assoc node :cells (remove-at cells i))]
          (cond
            (empty? path)
            (if (seq (:cells node'))
              (write-node! pg page-no node')
              (do (write-node! pg page-no node')
                  (fl/free! pg page-no)
                  (set-root! pg tree 0)))

            :else
            (do (write-node! pg page-no node')
                (when (< (used node') lim/min-fill)
                  (repair! pg tree path page-no node'))))
          true)))))

(defn free-tree!
  "Free every page of the tree in post-order (children left to right, then
  the page itself).  Returns the number of pages freed."
  [pg tree]
  (let [root (root-of pg tree)]
    (if (zero? root)
      0
      (letfn [(walk [page-no]
                (let [node (read-node pg page-no)
                      below (if (== (long (:type node)) interior)
                              (+ (long (reduce + 0 (map #(walk (:child %)) (:cells node))))
                                 (long (walk (:link node))))
                              0)]
                  (fl/free! pg page-no)
                  (inc below)))]
        (let [n (walk root)]
          (set-root! pg tree 0)
          n)))))
