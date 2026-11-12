(ns gitrepo.rev
  "Revision syntax: `<rev>`, `<rev>^n`, `<rev>~n`, `<rev>^{type}`, ref names
  and abbreviated ids."
  (:require [gitrepo.error :as err]
            [gitrepo.hex :as hex]
            [gitrepo.object :as obj]
            [gitrepo.refs :as refs]
            [gitrepo.store :as store]))

(set! *warn-on-reflection* true)

(defn- bad [^String s] (err/fail :bad-rev (str "cannot resolve revision: " s) {:rev s}))

(defn peel
  "Peels object `id` as `^{kind}` does. `kind` is `:commit`, `:tree`, `:blob`,
  `:tag`, `:object` or nil (for `^{}`). Returns an id; throws on failure."
  [repo ^String id kind]
  (case kind
    :object (if (store/present? repo id) id (err/fail :missing (str "no such object: " id)))
    nil (loop [id id]
          (let [o (store/read-object repo id)]
            (if (= :tag (:type o)) (recur (:object (obj/tag repo id))) id)))
    (loop [id id]
      (let [t (:type (store/read-object repo id))]
        (cond (= t kind) id
              (= t :tag) (recur (:object (obj/tag repo id)))
              (= t :commit) (recur (:tree (obj/commit repo id)))
              :else (err/fail :bad-rev (str "cannot peel " id " to " (name kind))))))))

(defn peel-to-commit
  "Peels `id` to a commit id, as `^{commit}` does."
  [repo id] (peel repo id :commit))

(defn peel-to-tree
  "Peels `id` to a tree id, as `^{tree}` does."
  [repo id] (peel repo id :tree))

(def ^:private peel-kinds
  {"" nil "commit" :commit "tree" :tree "blob" :blob "tag" :tag "object" :object})

(defn- digit? [c] (<= (int \0) (int c) (int \9)))

(defn- resolve-name [repo ^String s]
  (some #(refs/resolve-ref repo %)
        [s (str "refs/" s) (str "refs/tags/" s) (str "refs/heads/" s)
         (str "refs/remotes/" s) (str "refs/remotes/" s "/HEAD")]))

(defn- resolve-hex [repo ^String s]
  (let [n (.length s)]
    (when (and (<= 4 n 40) (hex/hex-string? s))
      (let [lower (.toLowerCase s)]
        (if (= n 40)
          (when (store/present? repo lower) lower)
          (let [ids (store/ids-with-prefix repo lower 2)]
            (when (= 1 (count ids)) (first ids))))))))

(defn resolve-rev
  "Resolves revision string `s` to an object id (40 lowercase hex digits).
  Throws a `:bad-rev` failure when it does not resolve. `repo` is a map as
  returned by `gitrepo.core/open-repo`."
  [repo ^String s]
  (let [n (.length s)
        brace (when (.endsWith s "}") (.lastIndexOf s "^{"))
        run-start (loop [i n] (if (and (pos? i) (digit? (.charAt s (dec i)))) (recur (dec i)) i))
        op-at (dec run-start)]
    (cond
      (and brace (pos? brace))
      (let [kind (get peel-kinds (.substring s (+ brace 2) (dec n)) ::unknown)]
        (when (= kind ::unknown) (bad s))
        (peel repo (resolve-rev repo (.substring s 0 brace)) kind))

      (and (pos? op-at) (#{\^ \~} (.charAt s op-at)))
      (let [num (if (= run-start n) 1N (bigint (BigInteger. (.substring s run-start))))
            commit-id (peel-to-commit repo (resolve-rev repo (.substring s 0 op-at)))]
        (cond
          (zero? num) commit-id
          (= \^ (.charAt s op-at))
          (let [parents (:parents (obj/commit repo commit-id))]
            (if (<= num (count parents)) (nth parents (dec (int num))) (bad s)))
          :else
          (loop [id commit-id k num]
            (if (zero? k)
              id
              (let [parents (:parents (obj/commit repo id))]
                (if (seq parents) (recur (first parents) (dec k)) (bad s)))))))

      :else
      (or (resolve-name repo s) (resolve-hex repo s) (bad s)))))
