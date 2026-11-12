(ns buildsys.vfs
  "The virtual file system: a persistent sorted map from workspace path to file.

  Because the map is persistent, taking a snapshot is O(1) (the scheduler
  uses that to give each command the files as they were at its start time) and
  because it is sorted, `glob` can find the paths sharing a wildcard-free
  prefix by binary search.

  Each file is `{:content byte-string :hash delay :stamp long}`.  The hash is
  a `delay`, so each distinct content is hashed at most once, however many
  builds and freshness checks look at it.  `:stamp` is the modification stamp;
  nothing ever reads it."
  (:require [buildsys.hash :as h])
  (:import (java.nio.charset StandardCharsets)
           (java.nio.file Files LinkOption Path Paths)
           (java.nio.file.attribute FileAttribute)
           (java.util.concurrent.atomic AtomicLong)))

(set! *warn-on-reflection* true)

(def ^:private ^AtomicLong stamp-clock (AtomicLong. 0))

;; ---------------------------------------------------------------- byte strings

(defn bytes->str
  "A byte array viewed as a byte string (one char per byte)."
  ^String [^bytes bs]
  (String. bs StandardCharsets/ISO_8859_1))

(defn str->bytes
  "The bytes of a byte string."
  ^bytes [^String s]
  (.getBytes s StandardCharsets/ISO_8859_1))

(defn utf8->str
  "Converts an ordinary (Unicode) string to a byte string by UTF-8 encoding it."
  ^String [^String s]
  (bytes->str (.getBytes s StandardCharsets/UTF_8)))

(defn str->utf8
  "Decodes a byte string as UTF-8 text (invalid bytes become U+FFFD)."
  ^String [^String s]
  (String. (str->bytes s) StandardCharsets/UTF_8))

;; ----------------------------------------------------------------------- paths

(defn- pchar? [c]
  (or (<= (int \a) c (int \z)) (<= (int \A) c (int \Z)) (<= (int \0) c (int \9))
      (= c (int \_)) (= c (int \.)) (= c (int \+)) (= c (int \-))))

(defn valid-path?
  "True when `s` is a workspace path: 1..1024 bytes, `/`-separated components
  of 1..255 `[A-Za-z0-9_.+-]` bytes, none of them `.` or `..`."
  [s]
  (and (string? s)
       (let [^String s s
             n (.length s)]
         (and (<= 1 n 1024)
              (loop [i 0 start 0]
                (if (= i n)
                  (and (< start n) (<= (- n start) 255)
                       (let [comp (subs s start n)] (not (or (= comp ".") (= comp "..")))))
                  (let [c (int (.charAt s i))]
                    (cond
                      (= c (int \/))
                      (and (< start i) (<= (- i start) 255)
                           (let [comp (subs s start i)] (not (or (= comp ".") (= comp ".."))))
                           (recur (inc i) (inc i)))
                      (pchar? c) (recur (inc i) start)
                      :else false))))))))

(defn first-component
  "The text of `path` before its first `/` (the whole path if it has none)."
  ^String [^String path]
  (let [i (.indexOf path "/")]
    (if (neg? i) path (subs path 0 i))))

(defn generated-path?
  "True for paths under the reserved `out` tree."
  [^String path]
  (= "out" (first-component path)))

(def state-path ".kiln-state")

;; ------------------------------------------------------------------- the vfs

(defn empty-vfs "An empty workspace." [] (sorted-map))

(defn make-file
  "A file value holding byte string `content`."
  [^String content]
  {:content content
   :hash    (delay (h/hash-hex content))
   :stamp   (.incrementAndGet stamp-clock)})

(defn put
  "Returns `vfs` with `path` holding `content` (replacing any previous file)."
  [vfs ^String path ^String content]
  (assoc vfs path (make-file content)))

(defn delete "Returns `vfs` without `path`." [vfs path] (dissoc vfs path))

(defn touch
  "Updates only the modification stamp of `path` (a no-op if it is absent)."
  [vfs path]
  (if (contains? vfs path)
    (assoc-in vfs [path :stamp] (.incrementAndGet stamp-clock))
    vfs))

(defn exists? [vfs path] (contains? vfs path))

(defn content
  "The content of `path`, or nil when there is no such file."
  [vfs path]
  (:content (get vfs path)))

(defn content-hash
  "The 16-hex-digit hash of the content of `path`, or nil when absent.  Each
  distinct content is hashed once."
  [vfs path]
  (some-> (get vfs path) :hash deref))

(defn paths-with-prefix
  "The paths that start with `prefix`, ascending, in O(log F + k)."
  [vfs ^String prefix]
  (->> (subseq vfs >= prefix)
       (map key)
       (take-while #(.startsWith ^String % prefix))))

(defn from-contents
  "Builds a vfs from a map of path -> byte string."
  [m]
  (reduce-kv put (empty-vfs) m))

;; ------------------------------------------------------------ real directories

(defn load-dir
  "Loads every regular file below directory `dir` (a path string) into a vfs,
  except a top-level `session.txt`.  Content is read as bytes."
  [dir]
  (let [root (Paths/get dir (make-array String 0))
        no-follow (make-array LinkOption 0)]
    (with-open [stream (Files/walk root (make-array java.nio.file.FileVisitOption 0))]
      (reduce
       (fn [vfs ^Path p]
         (if (Files/isRegularFile p no-follow)
           (let [rel (-> (.relativize root p) str (.replace "\\" "/"))]
             (if (= rel "session.txt")
               vfs
               (put vfs rel (bytes->str (Files/readAllBytes p)))))
           vfs))
       (empty-vfs)
       (iterator-seq (.iterator stream))))))

(defn read-file
  "The content of the file at `dir`/`name` as a byte string."
  [dir name]
  (bytes->str (Files/readAllBytes (Paths/get dir (into-array String [name])))))

(defn write-dir!
  "Writes every file of `vfs` to `dir`/`path`, creating parent directories."
  [vfs dir]
  (let [root (Paths/get dir (make-array String 0))]
    (doseq [[path {:keys [content]}] vfs]
      (let [target (.resolve root ^String path)]
        (when-let [parent (.getParent target)]
          (Files/createDirectories parent (make-array FileAttribute 0)))
        (Files/write target (str->bytes content) ^"[Ljava.nio.file.OpenOption;" (make-array java.nio.file.OpenOption 0))))))
