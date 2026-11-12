(ns kvstore.txn
  "Explicit and implicit transactions, commit and rollback (spec section 13)."
  (:require [kvstore.checkpoint :as ckpt]
            [kvstore.header :as h]
            [kvstore.limits :as lim]
            [kvstore.pager :as pager]
            [kvstore.wal :as wal]))

(set! *warn-on-reflection* true)

(defn- fail [kind msg]
  (throw (ex-info msg {:kind kind})))

(defn begin!
  "Open an explicit transaction.  Fails with `:txn-active` when one is open."
  [pg]
  (when (pager/explicit? pg) (fail :txn-active "a transaction is already open"))
  (pager/set-explicit! pg true))

(defn rollback!
  "Discard the open explicit transaction (`:no-txn` when none is open)."
  [pg]
  (when-not (pager/explicit? pg) (fail :no-txn "no transaction is open"))
  (pager/discard-dirty! pg)
  (pager/set-explicit! pg false))

(defn- commit-dirty!
  "Append the dirty pages to the log and make them the overlay.  Returns
  `{:txn-id :frames}`; runs an automatic checkpoint when the log is full."
  [pg]
  (h/add-field! pg :commit-counter 1)
  (let [txn-id (h/get-field pg :commit-counter)
        images (pager/dirty-pages pg)
        frames (count images)]
    (wal/append-commit! (pager/log pg) txn-id images)
    (pager/merge-into-overlay! pg images)
    (pager/discard-dirty! pg)
    (when (>= (pager/log-size pg) lim/wal-limit)
      (ckpt/checkpoint! pg))
    {:txn-id txn-id :frames frames}))

(defn commit!
  "Commit the open explicit transaction (`:no-txn` when none is open)."
  [pg]
  (when-not (pager/explicit? pg) (fail :no-txn "no transaction is open"))
  (pager/set-explicit! pg false)
  (commit-dirty! pg))

(defn run-write
  "Run `f` (which receives the pager and makes changes) as a write command:
  inside the open transaction if there is one, otherwise in an implicit
  transaction that is committed at once.  If `f` throws in the implicit case
  its pages are discarded.  Returns `f`'s result."
  [pg f]
  (if (pager/explicit? pg)
    (f pg)
    (try
      (let [r (f pg)]
        (commit-dirty! pg)
        r)
      (catch Throwable t
        (pager/discard-dirty! pg)
        (throw t)))))

(defn checkpoint!
  "Explicit checkpoint; `:txn-active` inside a transaction.  Returns the
  number of pages copied."
  [pg]
  (when (pager/explicit? pg) (fail :txn-active "a transaction is open"))
  (ckpt/checkpoint! pg))

(defn end-of-script!
  "Roll back a transaction left open when the script ends."
  [pg]
  (when (pager/explicit? pg)
    (rollback! pg)))
