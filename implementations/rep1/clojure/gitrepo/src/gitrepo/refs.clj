(ns gitrepo.refs
  "Refs: `HEAD`, loose files under `refs/` and `packed-refs`."
  (:require [clojure.string :as str]
            [gitrepo.hex :as hex])
  (:import [java.io File]
           [java.nio.file Files]
           [java.nio.charset StandardCharsets]))

(set! *warn-on-reflection* true)

(def ^:private max-symref-depth 5)

(defn read-packed-refs
  "Reads `<git-dir>/packed-refs` into a map of ref name to object id. Header
  (`#`) and peeled (`^`) lines are skipped."
  [git-dir]
  (let [f (File. (str git-dir) "packed-refs")]
    (if-not (.isFile f)
      {}
      (let [text (String. (Files/readAllBytes (.toPath f)) StandardCharsets/UTF_8)]
        (reduce (fn [m ^String line]
                  (if (and (> (.length line) 41)
                           (not (#{\# \^} (.charAt line 0)))
                           (= \space (.charAt line 40))
                           (hex/object-id? (.substring line 0 40)))
                    (let [name (.substring line 41)]
                      (if (contains? m name) m (assoc m name (.substring line 0 40))))
                    m))
                {}
                (str/split text #"\n"))))))

(defn valid-name?
  "True when `name` is `HEAD` or starts with `refs/`, and has no empty, `.`
  or `..` component."
  [^String name]
  (and (or (= name "HEAD") (.startsWith name "refs/"))
       (not-any? #{"" "." ".."} (str/split name #"/" -1))))

(defn- strip-trailing-ws [^String s]
  (loop [e (.length s)]
    (if (and (pos? e) (Character/isWhitespace (.charAt s (dec e)))) (recur (dec e)) (.substring s 0 e))))

(defn- read-loose [git-dir ^String name]
  (try
    (let [f (File. (str git-dir) name)]
      (when (.isFile f)
        (strip-trailing-ws (String. (Files/readAllBytes (.toPath f)) StandardCharsets/ISO_8859_1))))
    (catch java.nio.file.InvalidPathException _ nil)))

(defn resolve-ref
  "The object id the ref `name` holds, or nil when there is no such ref.
  `repo` is a map with `:dir` (the repository directory) and `:packed-refs`.
  A loose file wins over `packed-refs`; symbolic refs (`ref: <name>`) are
  followed at most 5 times. The object itself is not checked."
  [repo ^String name]
  (loop [name name follows 0]
    (when (valid-name? name)
      (if-let [content (read-loose (:dir repo) name)]
        (cond
          (hex/object-id? content) content
          (and (.startsWith ^String content "ref: ") (< follows max-symref-depth))
          (recur (.substring ^String content 5) (inc follows))
          :else nil)
        (get (:packed-refs repo) name)))))
