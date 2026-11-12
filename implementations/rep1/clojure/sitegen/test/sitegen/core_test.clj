(ns sitegen.core-test
  (:require [clojure.java.io :as io]
            [clojure.string :as str]
            [clojure.test :refer [deftest is testing]]
            [sitegen.core :as sitegen]
            [sitegen.test-util :refer [temp-dir tree]]))

(defn- text [bytes] (String. (byte-array bytes) "UTF-8"))

(def ^:private sample (io/file (io/resource "sample-site/input")))
(def ^:private expected (io/file (io/resource "sample-site/expected")))

(deftest generate-the-worked-example
  (let [out (temp-dir)
        n (sitegen/generate! (str sample) (str out))
        files (tree (.toFile out))]
    (testing "exactly the specified files are produced"
      (is (= 10 n) "generated files, not counting static ones")
      (is (= [".well-known/note.txt" "about/index.html" "empty.dat" "feed.xml" "img/pixel.bin" "index.html"
              "page/2/index.html" "posts/ducks/index.html" "posts/hello-world/index.html" "robots.txt"
              "sitemap.xml" "tags/birds/index.html" "tags/index.html" "tags/meta/index.html"]
             (sort (keys files)))))
    (testing "the outputs given in the specification are reproduced exactly"
      (doseq [[path bytes] (tree expected)]
        (is (= (str/trim-newline (text bytes)) (str/trim-newline (text (files path)))) path)))
    (testing "other pages"
      (is (= (str "<!doctype html>\n<title>Pond Notes</title>\n<h1>Meta (2)</h1>\n<ul><li>On Ducks</li><li>Hello, world</li></ul>")
             (text (files "tags/meta/index.html"))))
      (is (= "<!doctype html>\n<title>About</title>\n<h1>About</h1>\n<p>Nothing here.</p>\n"
             (text (files "about/index.html"))))
      (is (str/includes? (text (files "page/2/index.html")) "Hello, world")))
    (testing "static files are copied byte for byte, dotfiles and empty files included"
      (is (= [0 -1 10 13 0 1 2] (files "img/pixel.bin")))
      (is (= [] (files "empty.dat")))
      (is (= "dotfile dir\n" (text (files ".well-known/note.txt")))))))

(deftest build-site-in-memory
  (let [files (sitegen/build-site
               {:config "title = \"T\"\nbase_url = \"https://e.org\"\nauthor = \"A\"\nposts_per_page = 5\nextra = [\"x\", \"y\"]\n"
                :posts [["p.md" "+++\ntitle = \"P\"\ndate = \"2024-03-05\"\ntags = [\"Web Dev\"]\n+++\nHello *there*\n"]
                        ["draft.md" "+++\ntitle = \"D\"\ndate = \"2025-03-05\"\ndraft = true\n+++\nx\n"]]
                :pages []
                :templates {"index.html" "{% for p in posts %}{{ p.title }}:{{ p.date_long }}:{{ p.excerpt }}{% endfor %}|{{ site.extra|join('+') }}"
                            "post.html" "{{ post.slug }} {{ post.tags[0].url }} {{ post.content }}"
                            "page.html" "unused"
                            "tag.html" "{{ tag.name }}={{ posts|length }}"
                            "tags.html" "{% for t in tags %}{{ t.slug }}/{{ t.post_count }}{% endfor %}"}})]
    (is (= ["feed.xml" "index.html" "posts/p/index.html" "sitemap.xml" "tags/index.html" "tags/web-dev/index.html"]
           (sort (keys files))))
    (is (= "P:March 5, 2024:<p>Hello <em>there</em></p>\n|x+y" (get files "index.html")))
    (is (= "p /tags/web-dev/ <p>Hello <em>there</em></p>\n" (get files "posts/p/index.html")))
    (is (= "Web Dev=1" (get files "tags/web-dev/index.html")))
    (is (= "web-dev/1" (get files "tags/index.html")))
    (is (str/includes? (get files "sitemap.xml") "<loc>https://e.org/tags/web-dev/</loc>"))))

(deftest empty-site
  (let [files (sitegen/build-site
               {:config "title = \"T\"\nbase_url = \"https://e.org\"\nauthor = \"A\"\nposts_per_page = 5\n"
                :posts [] :pages []
                :templates {"index.html" "{{ pagination.total_pages }} {{ posts|length }} {{ pagination.has_next }}"
                            "post.html" "" "page.html" "" "tag.html" "" "tags.html" "{{ tags|length }}"}})]
    (is (= ["feed.xml" "index.html" "sitemap.xml" "tags/index.html"] (sort (keys files))))
    (is (= "1 0 False" (get files "index.html")))
    (is (= "0" (get files "tags/index.html")))
    (is (str/includes? (get files "feed.xml") "<updated>1970-01-01T00:00:00Z</updated>"))
    (is (str/ends-with? (get files "feed.xml") "  </author>\n</feed>\n"))))

(deftest pagination-layout
  (let [post (fn [i] [(str "p" i ".md") (str "+++\ntitle = \"P" i "\"\ndate = \"2024-01-0" i "\"\n+++\nx\n")])
        files (sitegen/build-site
               {:config "title = \"T\"\nbase_url = \"https://e.org\"\nauthor = \"A\"\nposts_per_page = 2\n"
                :posts (map post (range 1 6)) :pages []
                :templates {"index.html" "{{ pagination.number }}/{{ pagination.total_pages }}:{% for p in posts %}{{ p.slug }} {% endfor %}"
                            "post.html" "{{ post.slug }}" "page.html" "" "tag.html" "" "tags.html" ""}})]
    (is (= "1/3:p5 p4 " (get files "index.html")))
    (is (= "2/3:p3 p2 " (get files "page/2/index.html")))
    (is (= "3/3:p1 " (get files "page/3/index.html")))
    (is (not (contains? files "page/4/index.html")))
    (is (= 2 (count (re-seq #"<entry>" (get files "feed.xml")))) "the feed lists the first posts_per_page posts")))
