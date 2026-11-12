(ns langvm.test-util
  "Helpers shared by the test namespaces."
  (:require [clojure.java.io :as io]
            [clojure.string :as str]
            [langvm.core :as core]))

(defn run
  "Run the module stream `src` and return everything written to stdout."
  [src]
  (core/run-string src))

(defn prog
  "Wrap `body` as the `main` function of module `main`; `decls` (optional)
  are extra top-level items placed before it."
  ([body] (prog "" body))
  ([decls body]
   (str "@module main\n" decls "\nfn main() {\n" body "\n}\n")))

(defn run-main
  "Run `body` as the body of `main`."
  ([body] (run (prog body)))
  ([decls body] (run (prog decls body))))

(defn normalize
  "Strip trailing whitespace on each line and trailing newlines, as the
  conformance runner does."
  [s]
  (-> (str/join "\n" (map str/trimr (str/split (str/replace s "\r\n" "\n") #"\n" -1)))
      (str/replace #"\n+$" "")))

(defn same-output? [expected actual]
  (= (normalize expected) (normalize actual)))

(defn resource-files
  "Files in the test resource directory `dir` with extension `ext`."
  [dir ext]
  (->> (.listFiles (io/file "test/resources" dir))
       (filter #(str/ends-with? (.getName ^java.io.File %) ext))
       (sort-by #(.getName ^java.io.File %))))
