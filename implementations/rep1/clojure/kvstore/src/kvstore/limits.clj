(ns kvstore.limits
  "Constants fixed by the Tessera specification (section 5.2)."
  (:refer-clojure :exclude [max-key]))

(def ^:const page-size 1024)
(def ^:const max-key 128)
(def ^:const max-index-key 128)
(def ^:const max-inline 192)
(def ^:const ovf-payload 1012)
(def ^:const max-doc 65536)
(def ^:const max-depth 32)
(def ^:const btree-header 16)
(def ^:const capacity 1008)
(def ^:const min-fill 336)
(def ^:const max-indexes 16)
(def ^:const max-path 30)
(def ^:const max-path-segments 8)
(def ^:const wal-limit 262144)
(def ^:const max-limit 2147483647)
