(ns kvstore.freelist
  "Page allocation and the LIFO free list (spec section 10)."
  (:require [kvstore.bytes :as b]
            [kvstore.header :as h]
            [kvstore.limits :as lim]
            [kvstore.pager :as pager]))

(set! *warn-on-reflection* true)

(defn allocate!
  "Pop the free list, or extend the file by one page.  Returns the page
  number; the caller is expected to overwrite the whole page."
  ^long [pg]
  (let [head (h/get-field pg :freelist-head)]
    (if (zero? head)
      (let [n (inc (h/get-field pg :page-count))]
        (h/set-field! pg :page-count n)
        n)
      (let [nxt (b/u32 (pager/read-page pg head) 4)]
        (h/set-field! pg :freelist-head nxt)
        (h/add-field! pg :freelist-count -1)
        head))))

(defn free!
  "Push page `p` onto the free list, writing it as a free page."
  [pg ^long p]
  (let [img (byte-array lim/page-size)]
    (b/put-u32! img 4 (h/get-field pg :freelist-head))
    (pager/write-page! pg p img)
    (h/set-field! pg :freelist-head p)
    (h/add-field! pg :freelist-count 1)))
