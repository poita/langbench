(ns minisql.core
  "Public API of minisql, an in-memory relational database for a small SQL
  subset.

  A database is an immutable value.  Statements are executed with
  [[execute-script]], which returns the new database together with one result
  per statement:

      (require '[minisql.core :as sql])

      (let [{:keys [db results]}
            (sql/execute-script (sql/empty-db)
                                \"CREATE TABLE t (a INTEGER);
                                 INSERT INTO t VALUES (1), (2);
                                 SELECT SUM(a) FROM t;\")]
        (sql/format-results results))
      ;; => \"3\\n-- 1 rows\\n\"

  Results are maps:

      {:type :ok}                              ; CREATE / INSERT / UPDATE / DELETE
      {:type :rows :rows [[v ...] ...]}        ; SELECT; values are nil (NULL),
                                               ; Long, String or minisql.value/Real
      {:type :error :message \"...\"}          ; the statement failed, db unchanged"
  (:require [minisql.engine :as engine]
            [minisql.error :as err]
            [minisql.lexer :as lexer]
            [minisql.parser :as parser]
            [minisql.value :as value]))

(defn empty-db
  "A database with no tables."
  []
  engine/empty-db)

(defn- failure [^Throwable e]
  {:type :error
   :message (or (ex-message e) (.getName (class e)))})

(defn execute-tokens
  "Execute one statement given as lexer tokens.  Returns `[db result]`; on
  any failure the database is returned unchanged with an `:error` result."
  [db tokens]
  (try
    (engine/execute db (parser/parse-statement tokens))
    (catch Exception e [db (failure e)])
    (catch StackOverflowError e [db (failure e)])))

(defn execute-script
  "Execute every statement of the SQL text `sql` in order against `db`.
  Returns `{:db new-db :results [result ...]}` with one result per
  (non-empty) statement.  A failing statement yields an `:error` result and
  has no effect; execution continues with the next statement."
  [db sql]
  (reduce (fn [{:keys [db results]} tokens]
            (let [[db' result] (execute-tokens db tokens)]
              {:db db' :results (conj results result)}))
          {:db db :results []}
          (lexer/statements sql)))

(defn write-result
  "Write the textual form of `result` (as the CLI prints it) to the
  `java.io.Writer` `w`.  `:ok` results print nothing; `:error` prints
  `error`; row sets print one tab-separated line per row then `-- N rows`."
  [^java.io.Writer w result]
  (case (:type result)
    :ok nil
    :error (.write w "error\n")
    :rows (let [rows (:rows result)]
            (doseq [row rows]
              (loop [vs (seq row) first? true]
                (when vs
                  (when-not first? (.write w "\t"))
                  (.write w (value/render (first vs)))
                  (recur (next vs) false)))
              (.write w "\n"))
            (.write w (str "-- " (count rows) " rows\n")))))

(defn format-results
  "The text the CLI prints for a sequence of results."
  [results]
  (let [w (java.io.StringWriter.)]
    (doseq [r results] (write-result w r))
    (str w)))

(defn run-script
  "Run the SQL text `sql` on a fresh database and return the output text."
  [sql]
  (format-results (:results (execute-script (empty-db) sql))))
