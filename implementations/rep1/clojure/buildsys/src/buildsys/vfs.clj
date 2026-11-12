(ns buildsys.vfs
  "The virtual file system: an immutable map from workspace path to file.

  File contents are byte strings (see [[buildsys.hash]]).  Each file carries
  its content hash, computed lazily and at most once per distinct content, and
  a modification stamp that exists only because `touch` must have somewhere to
  record itself: Kiln never reads it back."
  (:require [clojure.string :as str]
            [buildsys.glob :as glob]
            [buildsys.hash :as hash]
            [buildsys.path :as path])
  (:import (java.nio.charset StandardCharsets)
           (java.nio.file Files LinkOption Path Paths)
           (java.nio.file.attribute FileAttribute)))

(set! *warn-on-reflection* true)

(defrecord File [content hash-hex stamp])

(defn make-file
  "A file with `content` (a byte string) and stamp `stamp`."
  ([content] (make-file content 0))
  ([content stamp]
   (->File content (delay (hash/hash-hex content)) stamp)))

(defn empty-vfs
  "A new, empty file system."
  []
  (sorted-map))

(defn exists? [vfs p] (contains? vfs p))

(defn content
  "The content of the file at `p`, or nil."
  [vfs p]
  (some-> (get vfs p) :content))

(defn file-hash
  "The hex content hash of the file at `p`, or nil when absent."
  [vfs p]
  (some-> ^File (get vfs p) :hash-hex deref))

(defn write
  "Create or replace the file at `p` with `content`."
  [vfs p content]
  (assoc vfs p (make-file content (or (:stamp (get vfs p)) 0))))

(defn delete
  "Remove the file at `p`."
  [vfs p]
  (dissoc vfs p))

(defn touch
  "Update the modification stamp of `p`; content and hash are unchanged."
  [vfs p]
  (if-let [f (get vfs p)]
    (assoc vfs p (assoc f :stamp (inc (:stamp f))))
    vfs))

(defn- eligible? [p]
  (and (not (path/generated? p))
       (not= p ".kiln-state")))

(defn glob-paths
  "The sorted workspace paths matching compiled glob `pattern`, excluding the
  reserved `out` tree and `.kiln-state`.  Only the paths sharing the pattern's
  wildcard-free prefix are examined."
  [vfs pattern]
  (let [prefix ^String (glob/literal-prefix pattern)
        candidates (if (.isEmpty prefix)
                     (keys vfs)
                     (->> (subseq vfs >= prefix)
                          (map key)
                          (take-while (fn [^String p] (.startsWith p prefix)))))]
    (->> candidates
         (filter eligible?)
         (filter #(glob/matches? pattern %))
         vec)))

(defn clean
  "Remove every path in the `out` tree and `.kiln-state`.  Returns
  `[vfs' removed-paths]` with the removed paths sorted ascending."
  [vfs]
  (let [removed (filterv (fn [p] (or (path/generated? p) (= p ".kiln-state")))
                         (keys vfs))]
    [(apply dissoc vfs removed) removed]))

(defn- latin1 ^String [^bytes bs] (String. bs StandardCharsets/ISO_8859_1))

(defn load-dir
  "Load every regular file below directory `dir` (a path string) into a new
  file system, skipping the top-level `session.txt` when `skip-session?`."
  [^String dir skip-session?]
  (let [root (Paths/get dir (make-array String 0))]
    (with-open [stream (Files/walk root (make-array java.nio.file.FileVisitOption 0))]
      (reduce
       (fn [vfs ^Path p]
         (if (Files/isRegularFile p (make-array LinkOption 0))
           (let [rel (str/join "/" (map str (.relativize root p)))]
             (if (and skip-session? (= rel "session.txt"))
               vfs
               (write vfs rel (latin1 (Files/readAllBytes p)))))
           vfs))
       (empty-vfs)
       (iterator-seq (.iterator stream))))))

(defn write-dir
  "Write every file of `vfs` below directory `dir`, creating directories."
  [vfs ^String dir]
  (let [root (Paths/get dir (make-array String 0))]
    (doseq [[p f] vfs]
      (let [target (.resolve root ^String p)]
        (Files/createDirectories (.getParent target) (make-array FileAttribute 0))
        (Files/write target
                     (.getBytes ^String (:content f) StandardCharsets/ISO_8859_1)
                     ^"[Ljava.nio.file.OpenOption;" (make-array java.nio.file.OpenOption 0))))))
