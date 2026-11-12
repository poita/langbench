(ns sitegen.model-test
  (:require [clojure.test :refer [deftest is testing]]
            [sitegen.model :as model])
  (:import (java.util LinkedHashMap)))

(defn- config [& {:as extra}]
  (let [m (LinkedHashMap.)]
    (.put m "title" "Site")
    (.put m "base_url" "https://x.example")
    (.put m "author" "Me")
    (.put m "posts_per_page" 2)
    (doseq [[k v] extra] (.put m k v))
    m))

(defn- post [slug date & {:keys [tags draft body] :or {tags [] draft false body "Body\n"}}]
  {:title (str "Post " slug) :date date :slug slug :tags tags :draft draft :body body})

(defn- page [slug & {:keys [draft] :or {draft false}}]
  {:title (str "Page " slug) :slug slug :draft draft :body (str "Page " slug "\n")})

(deftest slugs
  (is (= "web-development" (model/tag-slug "Web Development")))
  (is (= "c" (model/tag-slug "C++")))
  (is (= "rust-2024" (model/tag-slug "Rust 2024")))
  (is (= "a-b" (model/tag-slug "--a___b--")))
  (is (= "" (model/tag-slug "!!!")))
  (is (= "caf" (model/tag-slug "Café")) "non-ASCII letters become separators"))

(deftest dates
  (is (= "March 5, 2024" (model/date-long "2024-03-05")))
  (is (= "December 25, 1999" (model/date-long "1999-12-25")))
  (is (= "January 31, 0999" (model/date-long "0999-01-31"))))

(deftest urls-and-pages
  (is (= "/" (model/index-url 1)))
  (is (= "/page/12/" (model/index-url 12)))
  (is (= [1 1 1 2 3] (map #(model/total-pages %1 %2) [0 1 5 6 11] [2 2 5 5 5]) ) ))

(deftest ordering
  (testing "newest first, ties by slug"
    (is (= ["a" "b" "c"] (map :slug (model/canonical-order [(post "a" "2024-01-01") (post "c" "2023-01-01") (post "b" "2024-01-01")])))
        "sorted by date descending, ties by slug")
    (is (= ["z" "a"] (map :slug (model/canonical-order [(post "a" "2020-01-01") (post "z" "2024-01-01")]))))
    (is (= ["a" "b"] (map :slug (model/canonical-order [(post "b" "2024-01-01") (post "a" "2024-01-01")])))))
  (testing "pages by slug"
    (is (= ["a" "b"] (map :slug (model/page-order [(page "b") (page "a")]))))))

(deftest build-model
  (let [m (model/build (config)
                       [(post "old" "2020-01-01" :tags ["Beta" "alpha"])
                        (post "new" "2024-01-01" :tags ["alpha"])
                        (post "mid" "2022-05-05" :tags ["Beta"])
                        (post "hidden" "2025-01-01" :tags ["Secret"] :draft true)]
                       [(page "zeta") (page "about") (page "wip" :draft true)])]
    (testing "drafts are excluded everywhere"
      (is (= ["new" "mid" "old"] (map #(get % "slug") (:posts m))))
      (is (= ["about" "zeta"] (map #(get % "slug") (:pages m))))
      (is (= ["alpha" "beta"] (map #(get % "slug") (:tags m))) "tags exist only through published posts"))
    (testing "tag links carry the site-wide post count"
      (is (= [["Alpha" 2] ["Beta" 2]] [["Alpha" 2] ["Beta" 2]]))
      (is (= [["alpha" 2] ["Beta" 2]] (map (fn [t] [(get t "name") (get t "post_count")]) (:tag-links m)))))
    (testing "post objects"
      (let [mid (second (:posts m))]
        (is (= ["title" "slug" "url" "permalink" "date" "date_long" "tags" "content" "excerpt" "older" "newer"]
               (vec (keys mid))))
        (is (= "/posts/mid/" (get mid "url")))
        (is (= "https://x.example/posts/mid/" (get mid "permalink")))
        (is (= "May 5, 2022" (get mid "date_long")))
        (is (= "<p>Body</p>\n" (get mid "content")))
        (is (= "old" (get (get mid "older") "slug")))
        (is (= "new" (get (get mid "newer") "slug")))
        (is (nil? (get (get (first (:posts m)) "newer") "slug")) "the newest post has no newer neighbour")))
    (testing "objects are shared, not copied"
      (let [old (last (:posts m))
            beta-from-post (first (filter #(= "Beta" (get % "name")) (get old "tags")))
            beta-link (first (filter #(= "Beta" (get % "name")) (:tag-links m)))
            beta-tag (second (:tags m))]
        (is (identical? beta-from-post beta-link))
        (is (identical? (get old "older") nil))
        (is (identical? old (last (get beta-tag "posts"))))
        (is (= "old" (get (get (second (:posts m)) "older") "slug")))))
    (testing "tag objects"
      (let [beta (second (:tags m))]
        (is (= ["name" "slug" "url" "post_count" "posts"] (vec (keys beta))))
        (is (= ["mid" "old"] (map #(get % "slug") (get beta "posts"))))))))

(deftest excerpts
  (let [excerpt (fn [body] (get (first (:posts (model/build (config) [(post "a" "2024-01-01" :body body)] []))) "excerpt"))]
    (is (= "<p>First\nblock</p>\n" (excerpt "\n  \nFirst\nblock\n\nSecond\n")))
    (is (= "<h1>Title</h1>\n" (excerpt "# Title\n\nPara")))
    (is (= "" (excerpt "  \n\t\n")))
    (is (= "" (excerpt "")))
    (is (= "<pre><code>a\n</code></pre>\n" (excerpt "```\na\n\nb\n```\n")) "cut at the first blank line: the fence is closed by the converter")))

(deftest pagination
  (let [p (model/pagination 2 3 11)]
    (is (= ["number" "total_pages" "total_posts" "has_prev" "has_next" "prev_url" "next_url" "links"] (vec (keys p))))
    (is (= [2 3 11 true true "/" "/page/3/"] (map #(get p %) ["number" "total_pages" "total_posts" "has_prev" "has_next" "prev_url" "next_url"])))
    (is (= [[1 "/" false] [2 "/page/2/" true] [3 "/page/3/" false]]
           (map (fn [l] [(get l "number") (get l "url") (get l "current")]) (get p "links")))))
  (let [p (model/pagination 1 1 0)]
    (is (= [false false nil nil] (map #(get p %) ["has_prev" "has_next" "prev_url" "next_url"])))))
