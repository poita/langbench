(ns gitrepo.corpus-test
  "Runs the CLI over the shared test corpus when it is checked out next to
  this project (../problems/gitrepo/tests); otherwise does nothing."
  (:require [clojure.string :as str]
            [clojure.test :refer [deftest is testing]]
            [gitrepo.main :as main])
  (:import [java.io File]
           [java.nio.file Files]))

(def corpus (File. "../problems/gitrepo/tests"))

(defn- slurp-normalised [^File f]
  (let [s (String. (Files/readAllBytes (.toPath f)) "ISO-8859-1")]
    (str/replace (str/join "\n" (map str/trim-newline (str/split s #"\n"))) #"\s+\z" "")))

(deftest corpus-cases
  (if-not (.isDirectory corpus)
    (println "corpus not found; skipping")
    (doseq [^File t (sort (.listFiles corpus)) :when (.isDirectory t)]
      (testing (.getName t)
        (let [out (.toFile (Files/createTempDirectory "gitrepo-out" (into-array java.nio.file.attribute.FileAttribute [])))]
          (main/run (str (File. t "input")) (str out))
          (let [expected (sort (.listFiles (File. t "expected")))]
            (is (= (map #(.getName ^File %) expected)
                   (sort (map #(.getName ^File %) (.listFiles out)))))
            (doseq [^File e expected]
              (is (= (slurp-normalised e) (slurp-normalised (File. out (.getName e))))
                  (str (.getName t) "/" (.getName e))))))))))
