(ns sitegen.io
  "File-system access: reading a site source tree, writing generated files and
  copying static files."
  (:import (java.nio.charset StandardCharsets)
           (java.nio.file Files LinkOption Path Paths StandardCopyOption FileVisitOption)
           (java.nio.file.attribute FileAttribute)))

(set! *warn-on-reflection* true)

(defn- path ^Path [^String p & more]
  (Paths/get p (into-array String more)))

(defn- regular-file? [^Path p]
  (Files/isRegularFile p (make-array LinkOption 0)))

(defn read-text
  "Reads the UTF-8 text file at `p` (a Path)."
  ^String [^Path p]
  (String. (Files/readAllBytes p) StandardCharsets/UTF_8))

(defn list-files
  "The regular files directly inside directory `dir` (a Path) whose name ends
  with `suffix`, sorted by name.  An absent directory has no files."
  [^Path dir ^String suffix]
  (if (Files/isDirectory dir (make-array LinkOption 0))
    (with-open [stream (Files/newDirectoryStream dir)]
      (->> (iterator-seq (.iterator stream))
           (filter regular-file?)
           (filter #(.endsWith (str (.getFileName ^Path %)) suffix))
           (sort-by #(str (.getFileName ^Path %)))
           vec))
    []))

(defn- file-name ^String [^Path p] (str (.getFileName p)))

(defn read-source
  "Reads the site source tree rooted at `input-dir` into a map:

  `:config`     the text of site.toml
  `:posts`      vector of [file-name text] for content/posts/*.md
  `:pages`      vector of [file-name text] for content/pages/*.md
  `:templates`  map from template file name to source text, with one
                trailing newline removed
  `:static-dir` the Path of the static directory"
  [^String input-dir]
  (let [root (path input-dir)
        read-all (fn [dir suffix] (mapv (fn [p] [(file-name p) (read-text p)])
                                        (list-files (.resolve root ^String dir) suffix)))]
    {:config (read-text (.resolve root "site.toml"))
     :posts (read-all "content/posts" ".md")
     :pages (read-all "content/pages" ".md")
     :templates (into {}
                      (map (fn [[name ^String text]]
                             [name (if (.endsWith text "\n") (.substring text 0 (dec (.length text))) text)]))
                      (read-all "templates" ".html"))
     :static-dir (.resolve root "static")}))

(defn write-text!
  "Writes `text` as UTF-8 to `relative-path` (`/`-separated) below `out-dir`,
  creating directories as needed."
  [^String out-dir ^String relative-path ^String text]
  (let [target (.resolve (path out-dir) relative-path)]
    (Files/createDirectories (.getParent target) (make-array FileAttribute 0))
    (Files/write target (.getBytes text StandardCharsets/UTF_8) ^"[Ljava.nio.file.OpenOption;" (make-array java.nio.file.OpenOption 0))
    nil))

(defn copy-static!
  "Copies every regular file below `static-dir` (a Path) byte for byte to the
  same relative path below `out-dir`, including dotfiles and empty files.
  Does nothing when `static-dir` does not exist."
  [^Path static-dir ^String out-dir]
  (when (Files/isDirectory static-dir (make-array LinkOption 0))
    (let [out (path out-dir)]
      (with-open [stream (Files/walk static-dir (make-array FileVisitOption 0))]
        (doseq [^Path f (iterator-seq (.iterator stream))
                :when (regular-file? f)]
          (let [target (.resolve out (str (.relativize static-dir f)))]
            (Files/createDirectories (.getParent target) (make-array FileAttribute 0))
            (Files/copy f target ^"[Ljava.nio.file.CopyOption;" (into-array java.nio.file.CopyOption [StandardCopyOption/REPLACE_EXISTING]))))))))
