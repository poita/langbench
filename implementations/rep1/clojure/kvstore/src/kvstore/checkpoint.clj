(ns kvstore.checkpoint
  "Copying the log's committed pages into the main file (spec 15.6)."
  (:require [kvstore.bytes :as b]
            [kvstore.limits :as lim]
            [kvstore.pager :as pager]
            [kvstore.wal :as wal])
  (:import (java.util Arrays)))

(set! *warn-on-reflection* true)

(defn checkpoint!
  "Write every overlay image into the main file in ascending page order,
  size the file to `page_count` pages, empty the overlay and reset the log to
  its header.  Returns the number of pages copied."
  [pg]
  (let [overlay (pager/overlay pg)
        n (count overlay)
        ^bytes main (pager/main-file pg)
        page-count (if-let [^bytes p1 (get overlay 1)]
                     (b/u32 p1 12)
                     (b/u32 main 12))
        ^bytes out (Arrays/copyOf main (int (* page-count lim/page-size)))]
    (doseq [[p ^bytes img] (sort-by key overlay)]
      (System/arraycopy img 0 out (* (dec (long p)) lim/page-size) lim/page-size))
    (pager/set-main-file! pg out)
    (pager/clear-overlay! pg)
    (wal/reset-log! (pager/log pg))
    n))
