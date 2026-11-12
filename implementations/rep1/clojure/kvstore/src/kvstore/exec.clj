(ns kvstore.exec
  "Executes parsed commands and produces result blocks (spec sections 18, 19).

  `run-line` is the whole pipeline for one command line: lex, parse, execute,
  format.  It never throws for a bad command; errors become `error <kind>`."
  (:require [kvstore.btree :as bt]
            [kvstore.docs :as docs]
            [kvstore.header :as h]
            [kvstore.index :as ix]
            [kvstore.parser :as parser]
            [kvstore.query :as query]
            [kvstore.render :as render]
            [kvstore.txn :as txn]
            [kvstore.value :as v]))

(set! *warn-on-reflection* true)

(defn execute!
  "Run a parsed command against pager `pg`.  Returns `[status payload-lines]`
  or throws `ex-info` with a `:kind`."
  [pg {:keys [cmd] :as c}]
  (case cmd
    :begin (do (txn/begin! pg) ["ok begin" []])
    :commit (let [{:keys [txn-id frames]} (txn/commit! pg)]
              [(str "ok commit " txn-id " frames " frames) []])
    :rollback (do (txn/rollback! pg) ["ok rollback" []])
    :checkpoint [(str "ok checkpoint pages " (txn/checkpoint! pg)) []]
    :stat ["ok stat" (render/stat-lines (docs/stats pg))]
    :indexes (let [slots (h/live-slots pg)]
               [(str "ok indexes " (count slots)) (mapv render/index-line slots)])
    :put [(str "ok put " (name (docs/put! pg (:key c) (:doc c)))) []]
    :get [ "ok get value" [(v/render (docs/get-doc pg (:key c)))]]
    :delete (do (docs/delete! pg (:key c)) ["ok delete removed" []])
    :update (do (docs/update! pg (:key c) (:path c) (:value c)) ["ok update updated" []])
    :unset (do (docs/unset! pg (:key c) (:path c)) ["ok unset updated" []])
    :scan (let [cells (docs/scan pg c)]
            [(str "ok scan " (count cells))
             (if (:keys c)
               (mapv #(render/render-key (:key %)) cells)
               (mapv #(render/row-line (:key %) (docs/cell-doc pg %)) cells))])
    :find (let [{:keys [plan rows]} (query/find-docs pg (:pred c) (:limit c))]
            [(str "ok find " (count rows) " plan " plan)
             (mapv (fn [[k doc]] (render/row-line k doc)) rows)])
    :create-index (let [n (ix/create! pg (:path c) docs/primary #(docs/cell-doc pg %))]
                    [(str "ok create index " (render/path-text (:path c)) " entries " n) []])
    :drop-index (let [n (ix/drop! pg (render/path-text (:path c)))]
                  [(str "ok drop index " (render/path-text (:path c)) " pages " n) []])))

(defn run-line
  "Process one command line; returns `[status payload-lines]`."
  [pg ^String line]
  (try
    (execute! pg (parser/parse-line line))
    (catch clojure.lang.ExceptionInfo e
      (if-let [kind (:kind (ex-data e))]
        [(str "error " (name kind)) []]
        (throw e)))))
