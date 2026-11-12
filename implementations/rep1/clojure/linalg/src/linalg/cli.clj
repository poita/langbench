(ns linalg.cli
  "Command-line driver: `linalg.cli <input directory> <output directory>`.

  Reads `commands.txt` from the input directory, runs each command on the
  matrix files it names and writes one result file per output into the output
  directory (`NNN_<suffix>.mtx`), or `NNN_error.txt` when the command fails."
  (:require [clojure.java.io :as io]
            [clojure.string :as str]
            [linalg.core :as core]
            [linalg.error :as err]
            [linalg.matrix :as m]
            [linalg.mmio :as mmio])
  (:gen-class))

(set! *warn-on-reflection* true)

(def commands
  "The operation table: command name -> `:arity`, `:outputs` (the suffixes of
  the result files, in order) and `:run`, a function from the argument
  matrices to a sequence of result matrices, one per output."
  {"add"       {:arity 2 :outputs ["add"] :run (fn [a b] [(core/add a b)])}
   "mul"       {:arity 2 :outputs ["mul"] :run (fn [a b] [(core/mul a b)])}
   "transpose" {:arity 1 :outputs ["transpose"] :run (fn [a] [(core/transpose a)])}
   "lu"        {:arity 1 :outputs ["lu_P" "lu_L" "lu_U"]
                :run (fn [a] (let [{:keys [P L U]} (core/lu a)] [P L U]))}
   "det"       {:arity 1 :outputs ["det"] :run (fn [a] [(m/scalar (core/det a))])}
   "inv"       {:arity 1 :outputs ["inv"] :run (fn [a] [(core/inverse a)])}
   "solve"     {:arity 2 :outputs ["solve"] :run (fn [a b] [(core/solve a b)])}
   "qr"        {:arity 1 :outputs ["qr_Q" "qr_R"]
                :run (fn [a] (let [{:keys [Q R]} (core/qr a)] [Q R]))}
   "chol"      {:arity 1 :outputs ["chol_L"] :run (fn [a] [(core/chol a)])}
   "eig"       {:arity 1 :outputs ["eig_w" "eig_V"]
                :run (fn [a] (let [{:keys [w V]} (core/eig a)] [w V]))}
   "svd"       {:arity 1 :outputs ["svd_U" "svd_S" "svd_V"]
                :run (fn [a] (let [{:keys [U S V]} (core/svd a)] [U S V]))}
   "lstsq"     {:arity 2 :outputs ["lstsq"] :run (fn [a b] [(core/lstsq a b)])}
   "norm1"     {:arity 1 :outputs ["norm1"] :run (fn [a] [(m/scalar (core/norm1 a))])}
   "norminf"   {:arity 1 :outputs ["norminf"] :run (fn [a] [(m/scalar (core/norminf a))])}
   "normfro"   {:arity 1 :outputs ["normfro"] :run (fn [a] [(m/scalar (core/normfro a))])}
   "cond"      {:arity 1 :outputs ["cond"] :run (fn [a] [(m/scalar (core/cond-number a))])}})

(defn parse-script
  "Parses the text of a commands file into a vector of token vectors,
  dropping blank lines and `#` comments (which are not counted)."
  [^String text]
  (->> (str/split text #"\r?\n")
       (map #(str/replace % #"^[ \t\r]+|[ \t\r]+$" ""))
       (remove #(or (empty? %) (str/starts-with? % "#")))
       (mapv #(str/split % #"[ \t]+"))))

(defn- result-name [n suffix] (format "%03d_%s" n suffix))

(defn- write-file! [^java.io.File out-dir ^String name ^String content]
  (spit (io/file out-dir name) content :encoding "UTF-8"))

(defn run-command!
  "Runs command number `n` (`tokens` is the operation followed by its file
  names) and writes its result files into `out-dir`. `load-matrix` maps a file
  name to a matrix. A failing command writes `NNN_error.txt` instead."
  [load-matrix out-dir n tokens]
  (let [[op & args] tokens
        {:keys [arity outputs run]} (get commands op)]
    (try
      (when-not (and run (= arity (count args)))
        (throw (ex-info "bad command" {:linalg/error :unknown-command})))
      (let [results (apply run (map load-matrix args))]
        (doseq [[suffix result] (map vector outputs results)]
          (write-file! out-dir (str (result-name n suffix) ".mtx") (mmio/format-matrix result))))
      (catch clojure.lang.ExceptionInfo e
        (if-let [code (err/error-code e)]
          (write-file! out-dir (str (result-name n "error") ".txt")
                       (str (err/code->string code) "\n"))
          (throw e))))))

(defn run-script!
  "Runs the script in `in-dir`/commands.txt, writing results to `out-dir`.
  Each matrix file is parsed once, the first time a command names it. An
  unexpected failure in one command is reported on stderr and does not stop
  the rest of the script."
  [in-dir out-dir]
  (let [in-dir (io/file in-dir) out-dir (io/file out-dir)
        script (parse-script (slurp (io/file in-dir "commands.txt") :encoding "UTF-8"))
        cache (atom {})
        load-matrix (fn [name]
                      (or (@cache name)
                          (let [a (mmio/read-matrix (io/file in-dir name))]
                            (swap! cache assoc name a)
                            a)))]
    (doseq [[n tokens] (map-indexed (fn [i t] [(inc i) t]) script)]
      (try
        (run-command! load-matrix out-dir n tokens)
        (catch Throwable t
          (binding [*out* *err*]
            (println "command" n (str/join " " tokens) "failed:" t)))))))

(defn -main
  "Entry point: `<input directory> <output directory>`."
  [& [in-dir out-dir]]
  (if (and in-dir out-dir)
    (do (run-script! in-dir out-dir)
        (shutdown-agents))
    (binding [*out* *err*]
      (println "usage: linalg <input directory> <output directory>")
      (System/exit 2))))
