(ns gitrepo.command
  "The query language of the command-line tool: one command per line, tokens
  separated by single spaces."
  (:require [clojure.string :as str]
            [gitrepo.core :as core]
            [gitrepo.error :as err]
            [gitrepo.format :as fmt]
            [gitrepo.hex :as hex]))

(set! *warn-on-reflection* true)

(defn- bad-args [] (err/fail :bad-arg "bad command"))

(defn- digits? [^String s]
  (and (pos? (.length s)) (every? #(<= (int \0) (int %) (int \9)) s)))

(defn execute
  "Runs the command `line` against `repo` and returns its output as a byte
  array. Throws when the command fails."
  ^bytes [repo ^String line]
  (let [[cmd & args] (str/split line #" " -1)
        n (count args)]
    (case cmd
      "log" (do (when-not (<= 1 n 2) (bad-args))
                (let [[rev lim] args]
                  (when (and lim (not (digits? lim))) (bad-args))
                  (fmt/log (core/log repo rev (when lim (bigint (BigInteger. ^String lim)))))))
      "ls-tree" (do (when-not (<= 1 n 2) (bad-args))
                    (let [[rev path] args]
                      (fmt/ls-tree (core/ls-tree repo rev (when path (hex/utf8->latin1 path))))))
      "cat-file" (do (when-not (= n 1) (bad-args))
                     (fmt/cat-file (core/cat-file repo (first args))))
      "diff" (do (when-not (= n 2) (bad-args))
                 (fmt/diff (core/diff repo (first args) (second args))))
      "rev-parse" (do (when-not (= n 1) (bad-args))
                      (fmt/rev-parse (core/rev-parse repo (first args))))
      "count-objects" (do (when-not (zero? n) (bad-args))
                          (fmt/count-objects (core/count-objects repo)))
      (bad-args))))
