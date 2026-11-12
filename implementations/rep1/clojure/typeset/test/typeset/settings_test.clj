(ns typeset.settings-test
  (:require [clojure.test :refer [deftest is testing]]
            [typeset.settings :as s]
            [typeset.test-util :as t]
            [typeset.util :as u]))

(deftest length-literals
  (is (= 2500 (s/parse-length "2.5pt")))
  (is (= 500 (s/parse-length "0.5pt")))
  (is (= 4252 (s/parse-length "1.5mm")))
  (is (= -6000 (s/parse-length "-6pt")))
  (is (= 734 (s/parse-length "734")))
  (is (= 72000 (s/parse-length "1in")))
  (is (= 12000 (s/parse-length "1pc")))
  (is (= 28350 (s/parse-length "1cm")))
  (doseq [bad ["" "+1pt" "1.2345pt" ".5pt" "1.pt" "20px" "1 pt" "pt" "1pt "]]
    (is (nil? (s/parse-length bad)) (pr-str bad))))

(deftest integer-literals
  (is (= 42 (s/parse-integer "42")))
  (is (= -3 (s/parse-integer "-3")))
  (is (nil? (s/parse-integer "+3")))
  (is (nil? (s/parse-integer "3.0")))
  (is (nil? (s/parse-integer ""))))

(defn- err [text]
  (try (s/parse text) nil
       (catch clojure.lang.ExceptionInfo e (u/error-line (u/input-error e)))))

(deftest defaults
  (let [m (s/parse nil)]
    (is (= 612000 (m "page-width")))
    (is (= 468000 (:body-width m)))
    (is (= 648000 (:body-height m)))
    (is (= 756000 (m "footer-baseline")))
    (is (= 324000 (m "footnote-max-height")))
    (is (= :justify (m "align")))
    (is (= (m "header-left") (m "header-left-even")))))

(deftest derived-defaults-follow-explicit-settings
  (let [m (s/parse "page-height = 200pt\nheader-left = x\n")]
    (is (= 164000 (m "footer-baseline")))
    (is (= ["x"] (m "header-left-even")))
    (is (= 28000 (m "footnote-max-height")))))

(deftest error-reports
  (is (= "settings.cfg:2:15: bad-length" (err "page-width = 200pt\nmargin-left = 20px\n")))
  (is (= "settings.cfg:1:1: bad-syntax" (err "no equals\n")))
  (is (= "settings.cfg:2:3: bad-syntax" (err "# c\n  Bad = 1\n")))
  (is (= "settings.cfg:1:1: unknown-setting" (err "nope = 1\n")))
  (is (= "settings.cfg:2:1: duplicate-setting" (err "leading = 12pt\nleading = 13pt\n")))
  (is (= "settings.cfg:1:13: bad-boolean" (err "hyphenate = yes\n")))
  (is (= "settings.cfg:1:11: bad-length" (err "leading = \n")) "empty value: end of line")
  (is (= "settings.cfg:1:11: bad-value" (err "leading = 100\n")))
  (is (= "settings.cfg:1:9: bad-enum" (err "align = middle\n")))
  (is (= "settings.cfg:1:13: unknown-font" (err "body-font = comic\n")))
  (is (= "settings.cfg:1:19: unknown-patterns" (err "hyphen-patterns = x\n"))))

(deftest text-values
  (testing "placeholders and escapes"
    (let [m (s/parse "header-left = Page {page} of {pages} \\{ \\\\\n")]
      (is (= ["Page " :page " of " :pages " { \\"] (m "header-left")))))
  (testing "errors are positioned at the offending character"
    (is (= "settings.cfg:1:21: stray-brace" (err "header-left = \\{page}\n")) "escaped brace closes nothing")
    (is (= "settings.cfg:1:15: stray-brace" (err "header-left = }\\q\n")))
    (is (= "settings.cfg:1:15: unknown-placeholder" (err "header-left = {pa\\ge}\n")))
    (is (= "settings.cfg:1:15: unknown-placeholder" (err "header-left = {page\n")))
    (is (= "settings.cfg:1:17: bad-escape" (err "header-left = ab\\q\n")))
    (is (= "settings.cfg:1:13: bad-value" (err "toc-title = {page}\n")))
    (is (= "settings.cfg:1:14: bad-value" (err "toc-leader = a b\n")))
    (is (= "settings.cfg:1:14: bad-value" (err "toc-leader = abcdefghi\n")))))

(deftest body-rectangle-check
  ;; reported at the value of the last explicitly assigned geometry key
  (is (= "settings.cfg:3:14: bad-value"
         (err "page-width = 100pt\nmargin-left = 50pt\nmargin-top = 1pt\n"))))
