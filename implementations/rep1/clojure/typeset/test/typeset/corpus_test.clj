(ns typeset.corpus-test
  "Runs the problem's test corpus when it is available next to the project
  (`../problems/typeset/tests`); silently does nothing otherwise."
  (:require [clojure.java.io :as io]
            [clojure.string :as str]
            [clojure.test :refer [deftest is testing]]
            [typeset.core :as core]))

(def ^:private ^java.io.File corpus-dir (io/file ".." "problems" "typeset" "tests"))
(def ^:private ^java.io.File data-dir (io/file ".." "problems" "typeset" "data"))

(defn- norm [s] (str/join "\n" (map str/trimr (str/split s #"\n" -1))))

(deftest corpus
  (when (and (.isDirectory corpus-dir) (.isDirectory data-dir))
    (let [data (core/load-data (str data-dir))]
      (doseq [^java.io.File dir (sort (.listFiles corpus-dir))
              :let [in (io/file dir "input") expected (io/file dir "expected")]
              :when (.isDirectory in)]
        (testing (.getName dir)
          (let [read #(let [f (io/file in %)] (when (.isFile f) (slurp f)))
                actual (core/typeset-strings (read "document.cdx") (read "settings.cfg") data)]
            (doseq [^java.io.File ef (.listFiles expected)]
              (is (= (str/trimr (norm (slurp ef))) (str/trimr (norm (get actual (.getName ef) ""))))
                  (str (.getName dir) "/" (.getName ef))))
            (is (= (set (map #(.getName ^java.io.File %) (.listFiles expected))) (set (keys actual)))
                "same set of output files")))))))
