(ns buildsys.session-test
  (:require [buildsys.session :as session]
            [buildsys.test-util :refer [session-log]]
            [clojure.test :refer [deftest is testing]]))

(deftest parsing
  (is (= [{:op :build :targets [] :workers 1}
          {:op :build :targets ["@all" "out/a"] :workers 4}
          {:op :build :targets ["-j"] :workers 1}
          {:op :build :targets ["out/a" "-j"] :workers 1}
          {:op :build :targets [] :workers 8}
          {:op :touch :path "a"}
          {:op :delete :path "b"}
          {:op :clean}]
         (session/parse-session
          (str "# comment\n\n   \t\n"
               "build\n"
               "  build   @all\tout/a -j 4  \n"
               "build -j\n"
               "build out/a -j\n"
               "build -j 8\n"
               "touch a\n delete b\n   clean\n")))))

(deftest content-blocks-are-verbatim
  (is (= [{:op :create :path "p" :content "  lead\n\n# not a comment\ntrail \t\n"}
          {:op :edit :path "q" :content ""}
          {:op :clean}]
         (session/parse-session
          "create p\n  lead\n\n# not a comment\ntrail \t\n---\nedit q\n---\nclean\n"))))

(deftest log-format
  (is (= (str "step 1: create a.txt\n  ok size=2\n"
              "step 2: edit a.txt\n  ok size=0\n"
              "step 3: build (default) -j 1\n  error E_NO_BUILD_FILE main.kiln\n"
              "step 4: delete a.txt\n  ok\n"
              "step 5: clean\n  ok removed=0\n")
         (session-log {} "create a.txt\nx\n---\nedit a.txt\n---\nbuild\ndelete a.txt\nclean\n")))
  (is (= "" (session-log {} "# nothing\n"))))
