(ns buildsys.commands-test
  (:require [clojure.string :as str]
            [buildsys.commands :as commands]
            [buildsys.error :as err]
            [buildsys.vfs :as vfs]
            [clojure.test :refer [deftest is testing are]]))

(defn- run1
  "Run command `cmd` with `args` over a single input `content`."
  [cmd args content]
  (let [v (vfs/write (vfs/empty-vfs) "in.txt" content)
        r (commands/execute {:cmd cmd :args args :file-ins ["in.txt"] :outs ["out/x"]} v)]
    (second (first (:outputs r)))))

(deftest lines
  (is (= [] (commands/split-lines "")))
  (is (= [""] (commands/split-lines "\n")))
  (is (= ["a" "b"] (commands/split-lines "a\nb\n")))
  (is (= ["a" "b"] (commands/split-lines "a\nb")))
  (is (= ["a" "" "b"] (commands/split-lines "a\n\nb\n")))
  (is (= ["a\r"] (commands/split-lines "a\r\n")) "carriage returns are content"))

(deftest single-input-commands
  (are [cmd args in out] (= out (run1 cmd args in))
    "write" ["hi\n"] "" "hi\n"
    "copy" [] "x\u0000y" "x\u0000y"
    "upper" [] "abcé" "ABCé"
    "lower" [] "ABC1" "abc1"
    "grep" ["b"] "abc\nxyz\nb" "abc\nb\n"
    "grep" [""] "a\nb" "a\nb\n"
    "replace" ["aa" "b"] "aaa\naa" "ba\nb"
    "sort_lines" [] "b\na\nc" "a\nb\nc\n"
    "reverse_lines" [] "a\nb\nc\n" "c\nb\na\n"
    "dedup" [] "a\nb\na\nb\nc" "a\nb\nc\n"
    "number" [] "a\nb\nc\n" "1: a\n2: b\n3: c\n"
    "indent" [2] "a\n\nb" "  a\n  \n  b\n"
    "wrap" ["<" ">"] "x" "<x>"
    "wrap" ["<" ">"] "" "<>"))

(deftest multi-input-commands
  (let [v (-> (vfs/empty-vfs) (vfs/write "a" "1\n2\n") (vfs/write "b" ""))
        run (fn [cmd ins]
              (-> (commands/execute {:cmd cmd :args [] :file-ins ins :outs ["out/x"]} v)
                  :outputs first second))]
    (is (= "1\n2\n1\n2\n" (run "concat" ["a" "a"])))
    (is (= "2 a\n0 b\n2 total\n" (run "count_lines" ["a" "b"])))
    (is (= "8943a78b9f342c58 a\ncbf29ce484222325 b\n"
           (str/replace (run "hash" ["a" "b"]) #"^[0-9a-f]{16}" "8943a78b9f342c58")))))

(deftest preprocess
  (let [v (-> (vfs/empty-vfs)
              (vfs/write "main" "title\n@need p\nend\n")
              (vfs/write "p" "PART\n@need d\n")
              (vfs/write "d" "DEEP\n"))
        step {:cmd "preprocess" :args [] :file-ins ["main"] :outs ["out/doc"] :depfile "out/doc.d"}
        r (commands/execute step v)]
    (is (= [["out/doc" "title\nPART\nDEEP\nend\n"]
            ["out/doc.d" "kiln-deps 1\nneed d\nneed p\n"]]
           (:outputs r)))
    (is (= ["d" "p"] (map first (:deps r))))
    (testing "execution errors"
      (let [fails (fn [files]
                    (let [v (reduce-kv vfs/write (vfs/empty-vfs) files)]
                      (try (commands/execute step v) nil
                           (catch clojure.lang.ExceptionInfo e (err/render e)))))]
        (is (= "E_NEED_MISSING gone needed by main" (fails {"main" "@need gone\n"})))
        (is (= "E_NEED_PATH ../x" (fails {"main" "@need ../x\n"})))
        (is (= "E_NEED_CYCLE main" (fails {"main" "@need a\n" "a" "@need main\n"})))
        (is (= "E_NEED_CYCLE a" (fails {"main" "@need a\n" "a" "@need a\n"})))
        (testing "a directive needs the exact prefix and a non-empty remainder"
          (is (nil? (fails {"main" "@need\n@need \n @need x\n"}))))))))

(deftest canonical-strings
  (is (= "write(\"hello\\n\")" (commands/canonical "write" ["hello\n"])))
  (is (= "replace(\"a\\\\b\", \"c\")" (commands/canonical "replace" ["a\\b" "c"])))
  (is (= "indent(4)" (commands/canonical "indent" [4])))
  (is (= "write(\"\\x00\\x7f\\\"\\t\\rü\")" (commands/canonical "write" ["\u0000\u007f\"\t\rü"])))
  (is (= "preprocess()" (commands/canonical "preprocess" []))))
