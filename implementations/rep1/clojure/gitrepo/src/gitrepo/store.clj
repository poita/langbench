(ns gitrepo.store
  "The object store: loose objects and packfiles of a repository.

  A store is a plain map built once by `open-store`; reading objects fills its
  caches, so every object is inflated and every delta applied at most once per
  store. The store only reads `objects/` below the repository directory."
  (:require [gitrepo.delta :as delta]
            [gitrepo.error :as err]
            [gitrepo.hex :as hex]
            [gitrepo.inflate :as inflate]
            [gitrepo.pack :as pack]
            [gitrepo.sha1 :as sha1])
  (:import [java.io File]
           [java.nio.file Files]))

(set! *warn-on-reflection* true)

(def ^:private type-names {"commit" :commit "tree" :tree "blob" :blob "tag" :tag})
(def ^:private pack-types {1 :commit 2 :tree 3 :blob 4 :tag})

(def ^:private max-delta-depth 1000)

(defn- hex-name? [^String s n]
  (and (= n (.length s))
       (every? (fn [c] (or (<= (int \0) (int c) (int \9)) (<= (int \a) (int c) (int \f)))) s)))

(defn- list-files [^File dir]
  (if (.isDirectory dir)
    (sort-by #(.getName ^File %) (or (.listFiles dir) []))
    []))

(defn- list-loose [^File objects]
  (into (sorted-set)
        (for [^File d (list-files objects)
              :when (and (.isDirectory d) (hex-name? (.getName d) 2))
              ^File f (list-files d)
              :when (and (.isFile f) (hex-name? (.getName f) 38))]
          (str (.getName d) (.getName f)))))

(defn- list-packs [^File objects]
  (let [pdir (File. objects "pack")]
    (vec (for [^File f (list-files pdir)
               :let [n (.getName f)]
               :when (and (.endsWith n ".idx") (.isFile f))
               :let [base (subs n 0 (- (.length n) 4))
                     pf (File. pdir (str base ".pack"))]
               :when (.isFile pf)
               :let [p (try (pack/open-pack base f pf) (catch Exception _ nil))]
               :when p]
           p))))

(defn open-store
  "Opens the object store of the repository (a `.git` or bare directory) at
  path `git-dir`. Lists loose objects and loads every pack that has both an
  `.idx` and a `.pack` file."
  [git-dir]
  (let [objects (File. (str git-dir) "objects")]
    {:dir (str git-dir)
     :loose (list-loose objects)
     :packs (list-packs objects)
     :objects-dir (str objects)
     :cache (atom {})}))

(defn cached
  "Returns the value cached under key `k` in `store`, computing it with the
  no-argument function `f` (and remembering it) the first time."
  [store k f]
  (let [cache (:cache store)
        v (get @cache k ::none)]
    (if (identical? v ::none)
      (let [v (f)]
        (swap! cache assoc k v)
        v)
      v)))

;; --------------------------------------------------------------------------
;; presence and abbreviation

(defn- find-packed
  "[pack position] of the first pack holding `id`, or nil."
  [store ^String id]
  (let [id20 (hex/hex->bytes id)]
    (some (fn [p]
            (let [i (pack/find-position p id20)]
              (when-not (neg? i) [p i])))
          (:packs store))))

(defn present?
  "True when the object `id` has a loose file or an entry in a pack index."
  [store ^String id]
  (boolean (or (contains? (:loose store) id) (find-packed store id))))

(defn ids-with-prefix
  "Up to `limit` distinct ids of objects in the store that start with the
  lowercase hex `prefix`, loose and packed alike, in ascending order."
  [store ^String prefix ^long limit]
  (let [loose (take limit (take-while #(.startsWith ^String % prefix)
                                      (subseq ^clojure.lang.Sorted (:loose store) >= prefix)))
        packed (mapcat #(pack/prefix-matches % prefix limit) (:packs store))]
    (vec (take limit (sort (distinct (concat loose packed)))))))

(defn count-objects
  "`{:loose n :in-pack n :packs n}` as defined by the `count-objects` query."
  [store]
  {:loose (count (:loose store))
   :in-pack (reduce + 0 (map :count (:packs store)))
   :packs (count (:packs store))})

;; --------------------------------------------------------------------------
;; reading

(defn- parse-loose
  "Splits the plaintext of a loose object into `{:type :data}`."
  [^bytes plain]
  (let [n (alength plain)
        sp (loop [i 0] (cond (>= i (min n 8)) -1 (= 32 (aget plain i)) i :else (recur (inc i))))
        type (when (pos? sp) (type-names (hex/latin1 plain 0 sp)))
        nul (when type
              (loop [i (inc sp)] (cond (>= i n) -1 (zero? (aget plain i)) i :else (recur (inc i)))))
        digits (when (and nul (pos? nul)) (hex/latin1 plain (inc sp) (- nul sp 1)))]
    (when-not (and type (some? digits) (re-matches #"[0-9]{1,15}" digits))
      (err/fail :damaged "loose object: bad header"))
    (let [size (Long/parseLong digits)
          start (inc nul)]
      (when-not (= size (- n start)) (err/fail :damaged "loose object: size mismatch"))
      {:type type :data (java.util.Arrays/copyOfRange plain (int start) (int n))})))

(defn- read-loose [store ^String id]
  (let [f (File. (str (:objects-dir store)) (str (subs id 0 2) "/" (subs id 2)))
        bytes (Files/readAllBytes (.toPath f))]
    (parse-loose (:data (inflate/inflate bytes)))))

(declare read-object*)

(defn- read-packed [store pack ^long offset ^long depth]
  (cached store [:packed (:name pack) offset]
          (fn []
            (when (> depth max-delta-depth) (err/fail :damaged "delta chain too deep"))
            (let [h (pack/read-header pack offset)
                  ^bytes pbytes (:pack pack)
                  {:keys [data end]} (inflate/inflate pbytes (:data-offset h))
                  ^bytes data data]
              (when-not (= (:size h) (alength data)) (err/fail :damaged "pack: size mismatch"))
              (case (long (:type h))
                (1 2 3 4) {:type (pack-types (:type h)) :data data}
                6 (let [base (read-packed store pack (:base-offset h) (inc depth))]
                    {:type (:type base) :data (delta/apply-delta (:data base) data)})
                7 (let [base (read-object* store (:base-id h) (inc depth))]
                    {:type (:type base) :data (delta/apply-delta (:data base) data)}))))))

(defn- read-object* [store ^String id ^long depth]
  (cached store [:object id]
          (fn []
            (cond
              (contains? (:loose store) id) (read-loose store id)
              :else
              (if-let [[p i] (find-packed store id)]
                (read-packed store p (pack/offset-at p i) depth)
                (err/fail :missing (str "object not found: " id) {:id id}))))))

(defn read-object
  "Reads object `id` (40 lowercase hex digits) and returns
  `{:type <:commit|:tree|:blob|:tag> :data <payload bytes>}`. A loose copy is
  preferred over a packed one. Throws a `:missing` failure when the object is
  absent and a `:damaged` failure when it cannot be decoded."
  [store ^String id]
  (read-object* store id 0))

(defn object-hash
  "The SHA-1 (hex) of the stored form `<type> <size>NUL<payload>` of `obj`."
  ^String [{:keys [type ^bytes data]}]
  (let [header (hex/latin1-bytes (str (name type) " " (alength data) "\u0000"))
        buf (byte-array (+ (alength header) (alength data)))]
    (System/arraycopy header 0 buf 0 (alength header))
    (System/arraycopy data 0 buf (alength header) (alength data))
    (sha1/hex-digest buf)))
