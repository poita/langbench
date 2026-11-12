(ns typeset.core-test
  "End-to-end tests built from the worked examples of the specification."
  (:require [clojure.string :as str]
            [clojure.test :refer [deftest is testing]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [typeset.test-util :as t :refer [small-cfg]]))

(defn- layout= [doc cfg expected]
  (is (= (str/join "\n" (concat ["layout 1"] expected [""])) (t/layout doc cfg))))

(deftest example-5-one-line
  (layout= "The quick brown fox.\n" small-cfg
           ["pages 1"
            "page 1 1 200000 120000 20000 20000 160000 80000"
            "  text body serif 10000 38000 27310 15630 \"The\""
            "  text body serif 10000 56170 27310 22240 \"quick\""
            "  text body serif 10000 80950 27310 25140 \"brown\""
            "  text body serif 10000 108630 27310 15810 \"fox.\""])
  (is (= {"lines" 1 "paragraphs" 1 "total-demerits" 100 "pages" 1}
         (select-keys (t/report-map "The quick brown fox.\n" small-cfg)
                      ["lines" "paragraphs" "total-demerits" "pages"]))))

(deftest example-6-two-justified-lines
  (layout= "The quick brown fox jumps over the lazy dog.\n" small-cfg
           ["pages 1"
            "page 1 1 200000 120000 20000 20000 160000 80000"
            "  text body serif 10000 38000 27310 15630 \"The\""
            "  text body serif 10000 55521 27310 22240 \"quick\""
            "  text body serif 10000 79653 27310 25140 \"brown\""
            "  text body serif 10000 106685 27310 13280 \"fox\""
            "  text body serif 10000 121856 27310 24600 \"jumps\""
            "  text body serif 10000 148348 27310 17390 \"over\""
            "  text body serif 10000 167630 27310 12370 \"the\""
            "  text body serif 10000 20000 39310 16370 \"lazy\""
            "  text body serif 10000 38910 39310 17480 \"dog.\""])
  (is (= 3016 (get (t/report-map "The quick brown fox jumps over the lazy dog.\n" small-cfg)
                   "total-demerits"))))

(deftest example-7-ragged-alignments
  (let [doc "The quick brown fox jumps over the lazy dog.\n"
        rep #(t/report-map doc (str small-cfg "align = " % "\n"))]
    (doseq [a ["left" "right" "center"]]
      (is (= 244 (get (rep a) "total-demerits")) a))
    (is (str/includes? (t/layout doc (str small-cfg "align = right\n"))
                       "text body serif 10000 128700 39310 12370 \"the\""))
    (is (str/includes? (t/layout doc (str small-cfg "align = center\n"))
                       "text body serif 10000 74350 39310 12370 \"the\""))))

(deftest example-8-hyphenated-break
  (let [cfg (str small-cfg "par-indent = 0\n")
        doc "Algorithm integer column every typesetting.\n"]
    (layout= doc cfg
             ["pages 1"
              "page 1 1 200000 120000 20000 20000 160000 80000"
              "  text body serif 10000 20000 27310 41620 \"Algorithm\""
              "  text body serif 10000 63382 27310 27800 \"integer\""
              "  text body serif 10000 92945 27310 29880 \"column\""
              "  text body serif 10000 124587 27310 22030 \"every\""
              "  text body serif 10000 148380 27310 31620 \"typeset-\""
              "  text body serif 10000 20000 39310 18120 \"ting.\""])
    (let [r (t/report-map doc cfg)]
      (is (= 14996 (r "total-demerits")))
      (is (= 1 (r "hyphenated-lines"))))))

(deftest example-9-numbered-heading
  (layout= "@h1 Introduction\nThe quick brown fox.\n" small-cfg
           ["pages 1"
            "page 1 1 200000 120000 20000 20000 160000 80000"
            "  text body sans-bold 20000 20000 35460 11400 \"1\""
            "  text body sans-bold 20000 37400 35460 114340 \"Introduction\""
            "  text body serif 10000 38000 56630 15630 \"The\""
            "  text body serif 10000 56170 56630 22240 \"quick\""
            "  text body serif 10000 80950 56630 25140 \"brown\""
            "  text body serif 10000 108630 56630 15810 \"fox.\""]))

(deftest example-10-nested-lists
  (let [doc "@ul\n@li First item.\n@li Second item.\n@ul\n@li Nested one.\n@end\n@end\n"]
    (layout= doc small-cfg
             ["pages 1"
              "page 1 1 200000 120000 20000 20000 160000 80000"
              "  text body serif 10000 30560 27310 3440 \"•\""
              "  text body serif 10000 38000 27310 18360 \"First\""
              "  text body serif 10000 58900 27310 20350 \"item.\""
              "  text body serif 10000 30560 39310 3440 \"•\""
              "  text body serif 10000 38000 39310 29430 \"Second\""
              "  text body serif 10000 69970 39310 20350 \"item.\""
              "  text body serif 10000 47060 54850 4940 \"–\""
              "  text body serif 10000 56000 54850 28070 \"Nested\""
              "  text body serif 10000 86610 54850 16950 \"one.\""])
    (is (= 3 (get (t/report-map doc small-cfg) "lines")))))

(deftest example-11-preformatted
  (layout= "@pre\nlet x = 1\n  y = x + 2\n@end\n" small-cfg
           ["pages 1"
            "page 1 1 200000 120000 20000 20000 160000 80000"
            "  text body mono 9000 20000 26300 48600 \"let x = 1\""
            "  text body mono 9000 20000 37300 59400 \"  y = x + 2\""]))

(deftest example-12-table
  (let [doc "@table cols=3 align=llr\nItem | Qty | Price\n@hrule\nWidget | 2 | 4.50\nGadget | 11 | 19.95\n@end\n"
        out (t/layout doc small-cfg)]
    (is (str/includes? out "  rule body 20000 31540 82990 400"))
    (is (str/includes? out "  text body serif 10000 85510 41250 17480 \"4.50\""))
    (is (str/includes? out "  text body serif 10000 80530 52790 22460 \"19.95\""))))

(deftest example-13-footnote
  (layout= "Delta{n|A short note.} gamma.\n" small-cfg
           ["pages 1"
            "page 1 1 200000 120000 20000 20000 160000 80000"
            "  text body serif 7000 59720 25117 3444 \"1\""
            "  text body serif 10000 38000 28117 21720 \"Delta\""
            "  text body serif 10000 65704 28117 32050 \"gamma.\""
            "  rule footnote 20000 88968 120000 400"
            "  text footnote serif 6000 25048 96216 2952 \"1\""
            "  text footnote serif 8000 30000 98216 5864 \"A\""
            "  text footnote serif 8000 37896 98216 15984 \"short\""
            "  text footnote serif 8000 55912 98216 15800 \"note.\""]))

(deftest example-15-deferred-figure
  (layout= "@fig height=30pt\nA framed box.\n@end\nAlpha one.\n\nBeta two.\n" small-cfg
           ["pages 2"
            "page 1 1 200000 120000 20000 20000 160000 80000"
            "  text body serif 10000 38000 27310 24510 \"Alpha\""
            "  text body serif 10000 65050 27310 16950 \"one.\""
            "  text body serif 10000 38000 39310 18290 \"Beta\""
            "  text body serif 10000 58830 39310 17420 \"two.\""
            "page 2 2 200000 120000 20000 20000 160000 80000"
            "  box float 20000 20000 160000 30000"
            "  text float serif 9000 55556 60579 23571 \"Figure\""
            "  text float serif 9000 81413 60579 6705 \"1.\""
            "  text float serif 9000 92118 60579 6597 \"A\""
            "  text float serif 9000 101001 60579 25515 \"framed\""
            "  text float serif 9000 128802 60579 15642 \"box.\""]))

(deftest example-16-table-of-contents
  (let [doc "@toc\n@h1 Introduction\nAlpha one.\n@newpage\n@h1 Results\nBeta two.\n"
        out (t/layout doc small-cfg)]
    (is (str/starts-with? out "layout 1\npages 3\npage 1 i "))
    (is (str/includes? out "page 2 1 ") )
    (is (str/includes? out "page 3 2 "))
    (is (str/includes? out "  text body sans-bold 20000 20000 35460 82500 \"Contents\""))
    (is (str/includes? out "  text body serif 10000 175010 73630 4990 \"2\""))
    (is (= {"pages" 3 "front-pages" 1 "body-pages" 2 "lines" 7 "headings" 2 "total-demerits" 700}
           (select-keys (t/report-map doc small-cfg)
                        ["pages" "front-pages" "body-pages" "lines" "headings" "total-demerits"])))))

(deftest example-17-errors
  (is (= {"error.txt" "settings.cfg:2:15: bad-length\n"}
         (t/run "x\n" "page-width = 200pt\nmargin-left = 20px\n")))
  (is (= {"error.txt" "document.cdx:2:1: unknown-inline\n"}
         (t/run "@h1 Title\n{z|oops}\n" small-cfg)))
  (is (= {"error.txt" "-:0:0: missing-document\n"}
         (t/run nil small-cfg))))

(deftest example-18-running-headers
  (let [cfg (str small-cfg "header-baseline = 10pt\nfooter-baseline = 112pt\n"
                 "header-right = {chapter}\nfooter-center = {page}\n")
        out (t/layout "@toc\n@h1 Introduction\nAlpha one.\n@newpage\n@h1 Results\nBeta two.\n" cfg)]
    (is (str/includes? out "  text footer sans 9000 98780 112000 2439 \"i\""))
    (is (str/includes? out "  text header sans 9000 127413 10000 4545 \"1\""))
    (is (str/includes? out "  text header sans 9000 134487 10000 45513 \"Introduction\""))
    (is (str/includes? out "  text footer sans 9000 97727 112000 4545 \"1\""))))

(deftest empty-document
  (is (= "layout 1\npages 0\n" (t/layout "" nil))))

;; ---------------------------------------------------------------------------
;; Properties

(def ^:private word-gen
  (gen/fmap #(apply str %) (gen/vector (gen/elements (seq "abcdefghilmnoprstu")) 1 12)))

(def ^:private words-gen (gen/vector word-gen 1 120))

(defn- reading-order-text
  "All text of a layout in output order, spaces and hyphens removed."
  [layout]
  (->> (str/split-lines layout)
       (keep #(second (re-matches #"  text \S+ \S+ \d+ -?\d+ -?\d+ \d+ \"(.*)\"" %)))
       (apply str)
       (#(str/replace % "-" ""))))

(defspec text-is-preserved 40
  (prop/for-all [ws words-gen]
    (let [doc (str (str/join " " ws) "\n")]
      (= (apply str ws) (reading-order-text (t/layout doc small-cfg))))))

(defspec output-is-deterministic 20
  (prop/for-all [ws words-gen]
    (let [doc (str (str/join " " ws) "\n")]
      (= (t/run doc small-cfg) (t/run doc small-cfg)))))

(defspec lines-never-start-left-of-the-body 40
  (prop/for-all [ws words-gen]
    (every? #(>= % 20000)
            (for [l (str/split-lines (t/layout (str (str/join " " ws) "\n") small-cfg))
                  :let [m (re-matches #"  text \S+ \S+ \d+ (-?\d+) .*" l)]
                  :when m]
              (parse-long (second m))))))
