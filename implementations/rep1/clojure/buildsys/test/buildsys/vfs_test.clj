(ns buildsys.vfs-test
  (:require [buildsys.glob :as glob]
            [buildsys.test-util :as u]
            [buildsys.vfs :as vfs]
            [clojure.test :refer [deftest is]])
  (:import (java.nio.file Files Paths)
           (java.nio.file.attribute FileAttribute)))

(defn- ws [& paths] (reduce #(vfs/write %1 %2 "x") (vfs/empty-vfs) paths))
(defn- glob* [v pat] (vfs/glob-paths v (glob/compile-pattern pat)))

(deftest glob-skips-generated-paths-and-state
  (let [v (ws "a.txt" "out/b.txt" ".kiln-state" "src/c.txt" "outer/d.txt" "src/out/e.txt")]
    (is (= ["a.txt" "outer/d.txt" "src/c.txt" "src/out/e.txt"] (glob* v "**")))
    (is (= ["src/c.txt"] (glob* v "src/*.txt")))
    (is (= ["src"] (glob* (ws "src" "srcx") "src/**")))))

(deftest hashes-are-lazy-and-content-based
  (let [v (-> (ws) (vfs/write "a" "hello\n"))]
    (is (= "a9bc80cca21f28b3" (vfs/file-hash v "a")))
    (is (nil? (vfs/file-hash v "missing")))))

(deftest touch-changes-nothing-observable
  (let [v (ws "a")]
    (is (= (vfs/content v "a") (vfs/content (vfs/touch v "a") "a")))
    (is (= (vfs/file-hash v "a") (vfs/file-hash (vfs/touch v "a") "a")))))

(deftest clean-removes-the-out-tree-and-state
  (let [[v removed] (vfs/clean (ws "a" "out/x" "out/y/z" ".kiln-state" "outer"))]
    (is (= [".kiln-state" "out/x" "out/y/z"] removed))
    (is (= ["a" "outer"] (keys v)))))

(deftest directory-round-trip
  (let [dir (u/tmp-dir "kiln-vfs")
        v (-> (ws "a/b/c.txt" ".hidden") (vfs/write "bin" "\u0000ÿ\u0080"))]
    (vfs/write-dir v dir)
    (let [back (vfs/load-dir dir false)]
      (is (= (keys v) (keys back)))
      (is (= "\u0000ÿ\u0080" (vfs/content back "bin"))))
    (spit (str dir "/session.txt") "build\n")
    (is (nil? (vfs/content (vfs/load-dir dir true) "session.txt")))
    (is (= "build\n" (vfs/content (vfs/load-dir dir false) "session.txt")))))
