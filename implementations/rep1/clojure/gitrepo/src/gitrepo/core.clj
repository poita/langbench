(ns gitrepo.core
  "Public API: read a git repository straight off disk.

      (require '[gitrepo.core :as g])
      (def repo (g/open-repo \"/path/to/repo/.git\"))
      (g/rev-parse repo \"main~2\")
      (g/log repo \"HEAD\" 10)

  A repo is a plain map; opening it lists loose objects and loads pack
  indexes once, and reading objects fills caches in it, so reuse one repo for
  many queries. Every query throws an `ex-info` (see `gitrepo.error`) when it
  fails: the revision does not resolve, or an object is missing or damaged.

  Names, messages and idents in results are byte-strings: ISO-8859-1 strings
  holding one char per repository byte (see `gitrepo.hex`)."
  (:require [clojure.string :as str]
            [gitrepo.error :as err]
            [gitrepo.hex :as hex]
            [gitrepo.object :as obj]
            [gitrepo.refs :as refs]
            [gitrepo.rev :as rev]
            [gitrepo.store :as store])
  (:import [java.util PriorityQueue Comparator HashSet]))

(set! *warn-on-reflection* true)

(defn open-repo
  "Opens the repository whose `.git` (or bare) directory is `git-dir`."
  [git-dir]
  (assoc (store/open-store git-dir)
         :packed-refs (refs/read-packed-refs git-dir)))

(defn rev-parse
  "The object id (40 lowercase hex digits) that revision `rev` names."
  [repo rev]
  (rev/resolve-rev repo rev))

(defn cat-file
  "Reads and verifies the object `rev` names. Returns
  `{:id :type <:commit|:tree|:blob|:tag> :size n :data <payload bytes>}`.
  Throws when the SHA-1 of the stored form is not the object's id."
  [repo rev]
  (let [id (rev/resolve-rev repo rev)
        o (store/read-object repo id)]
    (when-not (= id (store/object-hash o))
      (err/fail :damaged (str "object " id " fails its checksum")))
    {:id id :type (:type o) :size (alength ^bytes (:data o)) :data (:data o)}))

(defn commit
  "The parsed commit with id `id`:
  `{:tree :parents :author :committer :message}`, idents being
  `{:name :timestamp}`."
  [repo id]
  (obj/commit repo id))

(defn- date [c] (:timestamp (:committer c)))

(defn log
  "Walks history from the commit `rev` names (peeled to a commit) in git's
  default order (newest committer date first, ties in discovery order) and
  returns a vector of commit maps `{:id :tree :parents :author :committer
  :message :subject}`. With `limit` (a non-negative integer) at most that many
  commits are returned."
  ([repo rev] (log repo rev nil))
  ([repo rev limit]
   (let [start (rev/peel-to-commit repo (rev/resolve-rev repo rev))
         counter (long-array 1)
         entry (fn [id]
                 (let [c (obj/commit repo id)
                       order (aget counter 0)]
                   (aset counter 0 (inc order))
                   [(date c) order id c]))
         pq (PriorityQueue. 11 (reify Comparator
                                 (compare [_ a b]
                                   (let [c (compare (nth b 0) (nth a 0))]
                                     (if (zero? c) (compare (nth a 1) (nth b 1)) c)))))
         seen (HashSet.)]
     (.add seen start)
     (.add pq (entry start))
     (loop [out (transient [])]
       (if (or (.isEmpty pq) (and limit (>= (count out) limit)))
         (persistent! out)
         (let [[_ _ id c] (.poll pq)]
           (doseq [p (:parents c)]
             (when (.add seen p) (.add pq (entry p))))
           (recur (conj! out (assoc c :id id :subject (obj/subject (:message c)))))))))))

(defn- resolve-tree-path
  [repo tree-id components]
  (reduce (fn [tid component]
            (let [e (first (filter #(= component (:name %)) (obj/tree repo tid)))]
              (if (and e (= :tree (obj/mode-type (:mode e))))
                (:id e)
                (err/fail :bad-arg (str "not a tree: " component)))))
          tree-id
          components))

(defn ls-tree
  "The entries of the tree `rev` names (peeled to a tree), or of the subtree
  at `path` (a byte-string of `/`-separated names), in stored order, as
  `{:mode <long> :type <:blob|:tree|:commit> :id :name}`."
  ([repo rev] (ls-tree repo rev nil))
  ([repo rev path]
   (let [root (rev/peel-to-tree repo (rev/resolve-rev repo rev))
         components (when path
                     (let [cs (str/split path #"/" -1)]
                       (when (some #{"" "." ".."} cs)
                         (err/fail :bad-arg (str "bad path: " path)))
                       cs))
         tid (resolve-tree-path repo root components)]
     (mapv #(assoc % :type (obj/mode-type (:mode %))) (obj/tree repo tid)))))

(defn- flatten-tree
  "Vector of `[path mode id]` for every non-tree entry below tree `id`."
  [repo id]
  (let [acc (java.util.ArrayList.)]
    ((fn walk [id prefix]
       (doseq [{:keys [mode name id]} (obj/tree repo id)]
         (if (= :tree (obj/mode-type mode))
           (walk id (str prefix name "/"))
           (.add acc [(str prefix name) mode id]))))
     id "")
    (vec (sort-by first acc))))

(defn diff
  "Compares the trees `rev1` and `rev2` name, recursively. Returns a vector,
  sorted by path, of `{:path :status <:A|:D|:M|:T> :mode1 :mode2 :id1 :id2}`;
  an absent side has mode 0 and an all-zero id."
  [repo rev1 rev2]
  (let [t1 (rev/peel-to-tree repo (rev/resolve-rev repo rev1))
        t2 (rev/peel-to-tree repo (rev/resolve-rev repo rev2))
        a (flatten-tree repo t1)
        b (flatten-tree repo t2)
        zero-id (apply str (repeat 40 \0))
        kind-bits #(bit-and (long %) 2r1111000000000000)
        change (fn [path m1 i1 m2 i2]
                 {:path path :mode1 m1 :mode2 m2 :id1 i1 :id2 i2
                  :status (cond (nil? m1) :A
                                (nil? m2) :D
                                (= (kind-bits m1) (kind-bits m2)) :M
                                :else :T)})
        fix (fn [c] (-> c (update :mode1 #(or % 0)) (update :mode2 #(or % 0))
                        (update :id1 #(or % zero-id)) (update :id2 #(or % zero-id))))]
    (loop [a (seq a) b (seq b) out (transient [])]
      (cond
        (and (nil? a) (nil? b)) (persistent! out)
        (nil? b) (let [[p m i] (first a)] (recur (next a) b (conj! out (fix (change p m i nil nil)))))
        (nil? a) (let [[p m i] (first b)] (recur a (next b) (conj! out (fix (change p nil nil m i)))))
        :else
        (let [[p1 m1 i1] (first a) [p2 m2 i2] (first b)
              c (compare p1 p2)]
          (cond
            (neg? c) (recur (next a) b (conj! out (fix (change p1 m1 i1 nil nil))))
            (pos? c) (recur a (next b) (conj! out (fix (change p2 nil nil m2 i2))))
            (and (= m1 m2) (= i1 i2)) (recur (next a) (next b) out)
            :else (recur (next a) (next b) (conj! out (fix (change p1 m1 i1 m2 i2))))))))))

(defn count-objects
  "`{:loose n :in-pack n :packs n}`: loose object files, objects across all
  packs (an object in two packs counts twice) and packs with both an `.idx`
  and a `.pack`."
  [repo]
  (store/count-objects repo))
