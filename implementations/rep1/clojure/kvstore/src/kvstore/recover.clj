(ns kvstore.recover
  "Opening a database: choose the main file, scan the log and keep only the
  committed transactions (spec section 16)."
  (:require [kvstore.pager :as pager]
            [kvstore.wal :as wal])
  (:import (java.io ByteArrayOutputStream)))

(set! *warn-on-reflection* true)

(defn open
  "Open a database from the raw bytes of `main.tdb` and `main.twal` (either
  may be nil or empty).  The log is trimmed to its last committed
  transaction; the main file is left untouched.  Returns a pager."
  [^bytes main ^bytes log]
  (let [main (if (and main (pos? (alength main))) main (pager/fresh-main))
        {:keys [valid-end images header-ok?]} (if log (wal/scan log) {:header-ok? false})
        overlay (into {} images)
        buf (if header-ok?
              (doto (ByteArrayOutputStream. (max 4096 (int valid-end)))
                (.write log 0 (int valid-end)))
              (wal/new-log))]
    (pager/create main overlay buf)))
