(ns kvstore.cli
  "Command-line tool: `kvstore <input dir> <output dir>`.

  Reads `commands.txt` (and optionally `main.tdb` / `main.twal`) from the
  input directory, runs the script and writes `results.txt`, `main.tdb` and
  `main.twal` into the output directory (spec section 2)."
  (:require [kvstore.exec :as exec]
            [kvstore.recover :as recover]
            [kvstore.render :as render]
            [kvstore.pager :as pager]
            [kvstore.txn :as txn])
  (:import (java.io File)
           (java.nio.charset StandardCharsets)
           (java.nio.file Files Path Paths)
           (java.nio.file.attribute FileAttribute))
  (:gen-class))

(set! *warn-on-reflection* true)

(defn split-lines
  "Split script bytes at LF into line strings.  A trailing LF terminates the
  last line rather than starting another; an empty script has no lines."
  [^bytes data]
  (let [n (alength data)]
    (loop [start 0 i 0 acc (transient [])]
      (cond
        (== i n) (persistent! (if (< start n)
                                (conj! acc (String. data (int start) (int (- n start)) StandardCharsets/UTF_8))
                                acc))
        (== (aget data i) 10) (recur (inc i) (inc i)
                                     (conj! acc (String. data (int start) (int (- i start)) StandardCharsets/UTF_8)))
        :else (recur start (inc i) acc)))))

(defn run-script
  "Run `commands` (script bytes) against the database given by `main` and
  `wal` bytes (either may be nil).  Returns `{:results string :main bytes :wal bytes}`."
  [^bytes commands main wal]
  (let [pg (recover/open main wal)
        sb (StringBuilder.)]
    (doseq [[i line] (map-indexed vector (split-lines commands))]
      (let [[status lines] (exec/run-line pg line)]
        (.append sb (render/block (inc i) status lines))))
    (txn/end-of-script! pg)
    {:results (.toString sb)
     :main (pager/main-file pg)
     :wal (.toByteArray (pager/log pg))}))

(def ^:private ^"[Ljava.nio.file.OpenOption;" open-opts (make-array java.nio.file.OpenOption 0))

(defn- read-optional ^bytes [^Path p]
  (when (Files/exists p (make-array java.nio.file.LinkOption 0))
    (Files/readAllBytes p)))

(defn run-dirs
  "Run the script in directory `in`, writing the three outputs to `out`."
  [^String in ^String out]
  (let [in-dir (Paths/get in (make-array String 0))
        out-dir (Paths/get out (make-array String 0))
        commands (Files/readAllBytes (.resolve in-dir "commands.txt"))
        {:keys [results main wal]} (run-script commands
                                               (read-optional (.resolve in-dir "main.tdb"))
                                               (read-optional (.resolve in-dir "main.twal")))]
    (Files/createDirectories out-dir (make-array FileAttribute 0))
    (Files/write (.resolve out-dir "results.txt") (.getBytes ^String results StandardCharsets/UTF_8)
                 open-opts)
    (Files/write (.resolve out-dir "main.tdb") ^bytes main open-opts)
    (Files/write (.resolve out-dir "main.twal") ^bytes wal open-opts)))

(defn -main
  [& args]
  (if (not= 2 (count args))
    (do (binding [*out* *err*]
          (println "usage: kvstore <input dir> <output dir>"))
        (System/exit 2))
    (let [failure (volatile! nil)
          ;; run on a thread with a large stack: predicates may nest deeply
          t (Thread. nil
                     (fn []
                       (try (run-dirs (first args) (second args))
                            (catch Throwable e (vreset! failure e))))
                     "kvstore-main" (* 512 1024 1024))]
      (.start t)
      (.join t)
      (if-let [e @failure]
        (do (.printStackTrace ^Throwable e) (System/exit 1))
        (System/exit 0)))))
