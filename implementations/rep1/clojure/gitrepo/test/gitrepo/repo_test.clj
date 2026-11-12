(ns gitrepo.repo-test
  "End-to-end tests over small repositories built on disk."
  (:require [clojure.string :as str]
            [clojure.test :refer [deftest is testing use-fixtures]]
            [gitrepo.command :as command]
            [gitrepo.core :as g]
            [gitrepo.error :as err]
            [gitrepo.hex :as hex]
            [gitrepo.test-util :as u])
  (:import [java.io File]))

(def ^:dynamic *git* nil)
(def ^:dynamic *ids* nil)

(defn- build!
  "A repository with three commits (c1 <- c2 <- c3 on main), a tag and a
  detached-looking HEAD file."
  [^File git]
  (let [b1 (u/write-loose! git :blob "one\n")
        b2 (u/write-loose! git :blob "two\n")
        b3 (u/write-loose! git :blob "cafÃ©\n")
        sub (u/write-loose! git :tree (u/tree-payload [["100644" "b.txt" b2]]))
        t1 (u/write-loose! git :tree (u/tree-payload [["100644" "a.txt" b1]]))
        t2 (u/write-loose! git :tree (u/tree-payload [["100644" "a.txt" b1] ["40000" "dir" sub]]))
        t3 (u/write-loose! git :tree (u/tree-payload [["100755" "a.txt" b1]
                                                      ["100644" "cafÃ©.txt" b3]
                                                      ["40000" "dir" sub]]))
        c1 (u/write-loose! git :commit (u/commit-payload t1 [] {:message "first\n"}))
        c2 (u/write-loose! git :commit
                           (u/commit-payload t2 [c1] {:committer "A <a@x> 2000 +0000"
                                                      :author "Ada <a@x> 1500 +0000"
                                                      :message "\nsecond\nline  \n\nbody\n"}))
        c3 (u/write-loose! git :commit
                           (u/commit-payload t3 [c2] {:committer "A <a@x> 3000 +0000" :message "third\n"}))
        tag (u/write-loose! git :tag (str "object " c2 "\ntype commit\ntag v1\ntagger T <t@x> 1 +0000\n\nrel\n"))]
    (u/write-ref! git "HEAD" "ref: refs/heads/main\n")
    (u/write-ref! git "refs/heads/main" (str c3 "\n"))
    (u/write-ref! git "refs/tags/v1" (str tag "\n"))
    {:b1 b1 :b2 b2 :b3 b3 :t1 t1 :t2 t2 :t3 t3 :c1 c1 :c2 c2 :c3 c3 :tag tag :sub sub}))

(use-fixtures :once
  (fn [f]
    (let [git (u/tmp-dir)
          ids (build! git)]
      (binding [*git* git *ids* ids] (f)))))

(defn- run [line]
  (let [out (command/execute (g/open-repo *git*) line)]
    (hex/latin1 out)))

(defn- fails? [line]
  (try (run line) false (catch Throwable e (err/failure? e))))

(deftest rev-parse-forms
  (let [{:keys [c1 c2 c3 tag t3]} *ids*
        repo (g/open-repo *git*)
        rp #(g/rev-parse repo %)]
    (is (= c3 (rp "HEAD")))
    (is (= c3 (rp "main")))
    (is (= c3 (rp "refs/heads/main")))
    (is (= c2 (rp "main^")))
    (is (= c2 (rp "main~1")))
    (is (= c1 (rp "main~2")))
    (is (= c1 (rp "main^^")))
    (is (= c3 (rp "main^0")))
    (is (= tag (rp "v1")))
    (is (= c2 (rp "v1^{commit}")))
    (is (= c2 (rp "v1^{}")))
    (is (= t3 (rp "main^{tree}")))
    (is (= c3 (rp "main^{object}")))
    (is (= c2 (rp (str (subs tag 0 8) "^{commit}"))))
    (is (= c3 (rp (str/upper-case (subs c3 0 10)))))))

(deftest rev-parse-failures
  (doseq [bad ["nope" "main~3" "main^2" "main^{blob}" "main^{bogus}" "config" "abc"
               "^" "~1" "refs/heads/../heads/main" "0000000000000000000000000000000000000000"]]
    (is (fails? (str "rev-parse " bad)) bad)))

(deftest ambiguous-abbreviation
  (let [git (u/tmp-dir)
        ids (set (for [i (range 400)] (u/write-loose! git :blob (str "blob " i))))
        by-prefix (group-by #(subs % 0 4) ids)
        dup (some #(when (> (count (val %)) 1) (key %)) by-prefix)
        repo (g/open-repo git)]
    (when dup
      (is (thrown? Exception (g/rev-parse repo dup))))
    (let [[p [only]] (first (filter #(= 1 (count (val %))) by-prefix))]
      (is (= only (g/rev-parse repo p))))))

(deftest log-order-and-format
  (let [{:keys [c1 c2 c3]} *ids*]
    (is (= (str c3 " A U Thor 1000 third\n"
                c2 " Ada 1500 second line\n"
                c1 " A U Thor 1000 first\n")
           (run "log HEAD")))
    (is (= (str c3 " A U Thor 1000 third\n") (run "log HEAD 1")))
    (is (= "" (run "log HEAD 0")))
    (is (= (str c2 " Ada 1500 second line\n" c1 " A U Thor 1000 first\n") (run "log v1")))
    (is (fails? "log HEAD x"))
    (is (fails? "log HEAD -1"))
    (is (fails? "log HEAD 1 2"))
    (is (fails? "log"))))

(deftest ls-tree-output
  (let [{:keys [b1 b2 b3 sub]} *ids*]
    (is (= (str "100755 blob " b1 "\ta.txt\n"
                "100644 blob " b3 "\t\"caf\\303\\251.txt\"\n"
                "040000 tree " sub "\tdir\n")
           (run "ls-tree HEAD")))
    (is (= (str "100644 blob " b2 "\tb.txt\n") (run "ls-tree HEAD dir")))
    (doseq [bad ["ls-tree HEAD a.txt" "ls-tree HEAD missing" "ls-tree HEAD dir/" "ls-tree HEAD /dir"
                 "ls-tree HEAD ." "ls-tree HEAD dir//x" "ls-tree HEAD " "ls-tree HEAD dir/b.txt"
                 "ls-tree"]]
      (is (fails? bad) bad))))

(deftest diff-output
  (let [{:keys [b1 b2 b3]} *ids*
        z (apply str (repeat 40 \0))]
    (is (= (str ":100644 100755 " b1 " " b1 " M\ta.txt\n"
                ":000000 100644 " z " " b3 " A\t\"caf\\303\\251.txt\"\n")
           (run "diff main~1 main")))
    (is (= (str ":100644 000000 " b1 " " z " D\ta.txt\n"
                ":000000 100644 " z " " b2 " A\tb.txt\n")
           (run (str "diff main~2 " (:sub *ids*)))))
    (is (= "" (run "diff main main")))))

(deftest cat-file-output
  (let [{:keys [b1 t1]} *ids*]
    (is (= "blob 4\none\n" (run (str "cat-file " b1))))
    (is (str/starts-with? (run (str "cat-file " t1)) (str "tree " 33 "\n")))
    (is (fails? (str "cat-file " (apply str (repeat 40 \1)))))
    (is (fails? "cat-file"))))

(deftest count-objects-output
  (is (= "loose: 11\nin-pack: 0\npacks: 0\n" (run "count-objects")))
  (is (fails? "count-objects "))
  (is (fails? "count-objects x")))

(deftest malformed-commands
  (doseq [bad ["" "frobnicate" "rev-parse  HEAD" "rev-parse HEAD " "rev-parse" "LOG HEAD"]]
    (is (fails? bad) (pr-str bad))))

(deftest damaged-loose-object
  (let [git (u/tmp-dir)
        payload (u/bytes-of "hello\n")
        id (u/object-id :blob payload)]
    ;; header claims a size of 7
    (u/write-file! (File. git (str "objects/" (subs id 0 2) "/" (subs id 2)))
                   (u/deflate (u/bytes-of "blob 7\u0000hello\n")))
    (let [repo (g/open-repo git)]
      (is (= id (g/rev-parse repo id)))
      (is (thrown? Exception (g/cat-file repo id))))))

(deftest hash-mismatch-detected
  (let [git (u/tmp-dir)
        id (u/object-id :blob (u/bytes-of "hello\n"))]
    ;; well-formed object stored under the wrong id
    (u/write-file! (File. git (str "objects/ab/" (subs id 2)))
                   (u/deflate (u/stored-form :blob (u/bytes-of "hello\n"))))
    (is (thrown? Exception (g/cat-file (g/open-repo git) (str "ab" (subs id 2)))))))

;; --------------------------------------------------------------------------
;; packs, packed refs

(defn- varint [v]
  (loop [v v out []]
    (if (< v 128)
      (conj out v)
      (recur (bit-shift-right v 7) (conj out (bit-or 128 (bit-and v 127)))))))

(defn- append-delta
  "A delta that copies all of `base` (at most 65535 bytes) and then inserts
  `extra` (at most 127 bytes)."
  [^bytes base ^bytes extra]
  (let [n (alength base)]
    (byte-array (map unchecked-byte
                     (concat (varint n) (varint (+ n (alength extra)))
                             [(bit-or 0x80 0x10 0x20) (bit-and n 255) (bit-shift-right n 8)]
                             [(alength extra)] (map #(bit-and 255 %) extra))))))

(deftest packed-objects-and-deltas
  (let [base-text (apply str (repeat 50 "the quick brown fox\n"))
        target-text (str base-text "and more\n")
        base (u/bytes-of base-text)
        target (u/bytes-of target-text)
        delta (append-delta base (u/bytes-of "and more\n"))
        target-id (u/object-id :blob target)
        base-id (u/object-id :blob base)]
    (testing "OFS_DELTA inside one pack"
      (let [git (u/tmp-dir)]
        (u/write-pack! git "pack-a" [{:type :blob :payload base}
                                     {:ofs-base 0 :delta delta :id target-id}])
        (let [repo (g/open-repo git)]
          (is (= {:loose 0 :in-pack 2 :packs 1} (g/count-objects repo)))
          (is (= base-text (hex/latin1 (:data (g/cat-file repo base-id)))))
          (is (= target-text (hex/latin1 (:data (g/cat-file repo target-id)))))
          (is (= base-id (g/rev-parse repo (subs base-id 0 6)))))))
    (testing "REF_DELTA against a loose base"
      (let [git (u/tmp-dir)
            loose-id (u/write-loose! git :blob base)]
        (u/write-pack! git "p1" [{:ref-base loose-id :delta delta :id target-id}])
        (let [repo (g/open-repo git)]
          (is (= target-text (hex/latin1 (:data (g/cat-file repo target-id)))))
          (is (= {:loose 1 :in-pack 1 :packs 1} (g/count-objects repo))))))
    (testing "an idx without a pack is ignored"
      (let [git (u/tmp-dir)]
        (u/write-pack! git "p" [{:type :blob :payload base}])
        (.delete (File. git "objects/pack/p.pack"))
        (is (= {:loose 0 :in-pack 0 :packs 0} (g/count-objects (g/open-repo git))))))))

(deftest packed-refs-and-symrefs
  (let [git (u/tmp-dir)
        id (u/write-loose! git :blob "x")]
    (u/write-file! (File. git "packed-refs")
                   (u/bytes-of (str "# pack-refs with: peeled\n" id " refs/heads/packed\n"
                                    "^" (apply str (repeat 40 \e)) "\n"
                                    id " refs/tags/t\n")))
    (u/write-ref! git "HEAD" "ref: refs/heads/packed\n")
    (u/write-ref! git "refs/heads/loose" (str id "  \n"))
    (u/write-ref! git "refs/heads/s1" "ref: refs/heads/s2")
    (u/write-ref! git "refs/heads/s2" "ref: refs/heads/s3")
    (u/write-ref! git "refs/heads/s3" "ref: refs/heads/s4")
    (u/write-ref! git "refs/heads/s4" "ref: refs/heads/s5")
    (u/write-ref! git "refs/heads/s5" "ref: refs/heads/s6")
    (u/write-ref! git "refs/heads/s6" (str id))
    (u/write-ref! git "refs/heads/s0" "ref: refs/heads/s1")
    (let [repo (g/open-repo git)]
      (doseq [r ["HEAD" "packed" "loose" "t" "refs/tags/t" "s2" "s1"]]
        (is (= id (g/rev-parse repo r)) r))
      (testing "a symbolic chain longer than 5 does not resolve"
        (is (thrown? Exception (g/rev-parse repo "s0")))))))
