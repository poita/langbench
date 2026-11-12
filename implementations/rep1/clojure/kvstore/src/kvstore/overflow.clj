(ns kvstore.overflow
  "Overflow page chains for documents longer than `MAX_INLINE` (spec section 9)."
  (:require [kvstore.bytes :as b]
            [kvstore.freelist :as fl]
            [kvstore.limits :as lim]
            [kvstore.pager :as pager]))

(set! *warn-on-reflection* true)

(defn write-chain!
  "Store `tail` (document bytes from offset 192 on) in a fresh chain.  Pages
  are allocated in chain order, first chunk first.  Returns the first page."
  ^long [pg ^bytes tail]
  (let [n (quot (+ (alength tail) (dec lim/ovf-payload)) lim/ovf-payload)
        pages (vec (repeatedly n #(fl/allocate! pg)))]
    (dotimes [i n]
      (let [from (* i lim/ovf-payload)
            len (min lim/ovf-payload (- (alength tail) from))
            img (byte-array lim/page-size)]
        (b/put-u8! img 0 3)
        (b/put-u32! img 4 (if (< (inc i) n) (pages (inc i)) 0))
        (b/put-u16! img 8 len)
        (System/arraycopy tail from img 12 len)
        (pager/write-page! pg (pages i) img)))
    (pages 0)))

(defn read-chain
  "The bytes held by the chain starting at page `first-page`."
  ^bytes [pg ^long first-page ^long total]
  (let [out (byte-array total)]
    (loop [p first-page off 0]
      (when (and (pos? p) (< off total))
        (let [^bytes img (pager/read-page pg p)
              len (b/u16 img 8)]
          (System/arraycopy img 12 out off len)
          (recur (b/u32 img 4) (+ off len)))))
    out))

(defn chain-pages
  "Page numbers of the chain starting at `first-page`, in chain order."
  [pg ^long first-page]
  (loop [p first-page acc []]
    (if (zero? p)
      acc
      (recur (b/u32 (pager/read-page pg p) 4) (conj acc p)))))

(defn free-chain!
  "Free every page of the chain in chain order (so the last page ends up at
  the head of the free list).  A zero `first-page` is a no-op."
  [pg ^long first-page]
  (doseq [p (chain-pages pg first-page)]
    (fl/free! pg p)))
