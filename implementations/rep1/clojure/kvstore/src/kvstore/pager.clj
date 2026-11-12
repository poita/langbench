(ns kvstore.pager
  "The page cache: the main file, the overlay of committed log images and the
  open transaction's dirty pages (spec section 13).

  A page is looked up in the dirty set first, then the overlay, then the main
  file.  Page images handed out by `read-page` must be treated as immutable;
  to modify a page, build a new array and `write-page!` it (or use
  `mutable-page!` for the header page)."
  (:require [kvstore.bytes :as b]
            [kvstore.limits :as lim]
            [kvstore.wal :as wal])
  (:import (java.util Arrays)))

(set! *warn-on-reflection* true)

(defrecord Pager [main overlay dirty log explicit])
;; main     - volatile holding the main file as a byte array
;; overlay  - volatile map page-no -> newest committed image
;; dirty    - volatile sorted map page-no -> image of the open transaction
;; log      - ByteArrayOutputStream holding the current log
;; explicit - volatile boolean, true while an explicit transaction is open

(defn create
  "Build a pager over `main` bytes, with committed `overlay` images and a
  `log` buffer that already holds the accepted part of the log."
  [^bytes main overlay log]
  (->Pager (volatile! main) (volatile! overlay) (volatile! (sorted-map)) log (volatile! false)))

(defn main-page-count
  "Number of pages in the main file."
  ^long [^Pager pg]
  (quot (alength ^bytes @(.main pg)) lim/page-size))

(defn read-page
  "The newest image of page `n` (1024 bytes).  Never mutate the result."
  ^bytes [^Pager pg ^long n]
  (or (get @(.dirty pg) n)
      (get @(.overlay pg) n)
      (let [^bytes main @(.main pg)
            from (* (dec n) lim/page-size)]
        (if (<= (+ from lim/page-size) (alength main))
          (Arrays/copyOfRange main (int from) (int (+ from lim/page-size)))
          (byte-array lim/page-size)))))

(defn write-page!
  "Record `img` as page `n` of the open transaction.  The page becomes dirty
  even when the bytes are unchanged.  The array is owned by the pager from
  here on."
  [^Pager pg ^long n ^bytes img]
  (assert (== (alength img) lim/page-size))
  (vswap! (.dirty pg) assoc n img)
  nil)

(defn mutable-page!
  "A private, mutable copy of page `n` registered as dirty (the same array on
  repeated calls within a transaction)."
  ^bytes [^Pager pg ^long n]
  (or (get @(.dirty pg) n)
      (let [img (Arrays/copyOf ^bytes (read-page pg n) (int lim/page-size))]
        (vswap! (.dirty pg) assoc n img)
        img)))

(defn dirty-pages
  "The open transaction's dirty pages, a sorted map of page-no to image."
  [^Pager pg]
  @(.dirty pg))

(defn discard-dirty!
  "Throw away the open transaction's pages."
  [^Pager pg]
  (vreset! (.dirty pg) (sorted-map))
  nil)

(defn merge-into-overlay!
  "Make `images` (page-no -> bytes) the newest committed images."
  [^Pager pg images]
  (vswap! (.overlay pg) into images)
  nil)

(defn overlay
  "Map of page number to the newest committed image still in the log."
  [^Pager pg]
  @(.overlay pg))

(defn clear-overlay! [^Pager pg]
  (vreset! (.overlay pg) {})
  nil)

(defn main-file
  "The main file's bytes."
  ^bytes [^Pager pg]
  @(.main pg))

(defn set-main-file! [^Pager pg ^bytes bs]
  (vreset! (.main pg) bs)
  nil)

(defn log
  "The log buffer (a `ByteArrayOutputStream`)."
  ^java.io.ByteArrayOutputStream [^Pager pg]
  (.log pg))

(defn log-size
  "Current size of the log in bytes."
  ^long [^Pager pg]
  (.size (log pg)))

(defn explicit? [^Pager pg] @(.explicit pg))

(defn set-explicit! [^Pager pg v]
  (vreset! (.explicit pg) (boolean v))
  nil)

(defn fresh-main
  "The one-page main file of a fresh database (spec 7.3)."
  ^bytes []
  (let [p (byte-array lim/page-size)]
    (b/put-bytes! p 0 (b/utf8 "TESSERA1"))
    (b/put-u16! p 8 1)
    (b/put-u16! p 10 lim/page-size)
    (b/put-u32! p 12 1)
    p))

(defn open-empty
  "A pager over a fresh database with an empty log."
  []
  (create (fresh-main) {} (wal/new-log)))
