(ns sitegen.model
  "The content model: ordering of posts and pages, tag collection, slugs,
  dates, URLs, pagination, and the dict-shaped objects that templates see.

  `build` turns parsed content into a model in which every post, page and tag
  object, and every link to one, is built exactly once and shared wherever it
  appears.  Template-facing objects are insertion-ordered `LinkedHashMap`s
  with the members listed in the specification."
  (:require [clojure.string :as str]
            [sitegen.markdown :as markdown]
            [sitegen.util :as util])
  (:import (java.util ArrayList HashMap LinkedHashMap List)))

(set! *warn-on-reflection* true)

(defn dict
  "An insertion-ordered dict from alternating keys and values."
  ^LinkedHashMap [& kvs]
  (let [m (LinkedHashMap.)]
    (loop [kvs (seq kvs)]
      (when kvs
        (.put m (first kvs) (second kvs))
        (recur (nnext kvs))))
    m))

;; ---------------------------------------------------------------------------
;; Slugs, dates, URLs

(defn tag-slug
  "The slug of a tag name: ASCII letters lower-cased, every other character
  outside a-z0-9 replaced by `-`, runs of `-` collapsed, and leading and
  trailing `-` removed."
  ^String [^String name]
  (let [sb (StringBuilder.)]
    (loop [i 0 pending-dash? false]
      (when (< i (.length name))
        (let [cp (.codePointAt name i)
              c (cond (<= (int \A) cp (int \Z)) (+ cp 32) :else cp)
              w (Character/charCount cp)]
          (if (or (<= (int \a) c (int \z)) (<= (int \0) c (int \9)))
            (do (when (and pending-dash? (pos? (.length sb))) (.append sb \-))
                (.appendCodePoint sb (int c))
                (recur (+ i w) false))
            (recur (+ i w) true)))))
    (.toString sb)))

(def ^:private month-names
  ["January" "February" "March" "April" "May" "June" "July" "August"
   "September" "October" "November" "December"])

(defn date-long
  "Renders `YYYY-MM-DD` as `<Month> <D>, <YYYY>`, e.g. `March 5, 2024`."
  [^String date]
  (let [year (.substring date 0 4)
        month (Long/parseLong (.substring date 5 7))
        day (Long/parseLong (.substring date 8 10))]
    (str (nth month-names (dec month)) " " day ", " year)))

(defn index-url
  "The URL of index page `n` (1-based)."
  [n]
  (if (== (long n) 1) "/" (str "/page/" n "/")))

(defn total-pages
  "The number of index pages for `n-posts` posts at `per-page` per page."
  [n-posts per-page]
  (max 1 (long (Math/ceil (/ (double n-posts) (double per-page))))))

;; ---------------------------------------------------------------------------
;; Ordering

(defn canonical-order
  "Sorts post maps (with `:date` and `:slug`) newest first, ties by slug
  ascending in code point order."
  [posts]
  (sort (fn [a b]
          (let [c (compare (:date b) (:date a))]
            (if (zero? c)
              (util/compare-code-points (:slug a) (:slug b))
              c)))
        posts))

(defn page-order
  "Sorts page maps by slug ascending in code point order."
  [pages]
  (sort (fn [a b] (util/compare-code-points (:slug a) (:slug b))) pages))

;; ---------------------------------------------------------------------------
;; Model construction

(defn- collect-tags
  "Collects, in O(K + T log T), the existing tags of the ordered `posts`:
  returns a vector of [name [post-index ...]] sorted by tag slug."
  [posts]
  (let [by-name (HashMap.)]
    (loop [i 0 ps (seq posts)]
      (when ps
        (doseq [t (:tags (first ps))]
          (let [^ArrayList l (or (.get by-name t)
                                 (let [l (ArrayList.)] (.put by-name t l) l))]
            (.add l i)))
        (recur (inc i) (next ps))))
    (->> (for [^java.util.Map$Entry e (.entrySet by-name)]
           [(.getKey e) (vec (.getValue e)) (tag-slug (.getKey e))])
         (sort (fn [[_ _ a] [_ _ b]] (util/compare-code-points a b)))
         (mapv (fn [[name idxs slug]] [name idxs slug])))))

(defn- excerpt-source
  "The first block of a body: its leading blank lines skipped, then the
  maximal run of non-blank lines joined with LF."
  ^String [^String body]
  (let [lines (.split body "\n" -1)
        blank? (fn [^String l] (every? #(or (= % \space) (= % \tab)) l))
        rest-lines (drop-while blank? lines)]
    (str/join "\n" (take-while (complement blank?) rest-lines))))

(defn build
  "Builds the model for `config` (the parsed site.toml, a LinkedHashMap) and
  the content maps `posts` and `pages` as returned by `sitegen.content`.
  Drafts are excluded.  Returns a map with the keys

  `:site`       the config dict
  `:base-url`   `base_url`
  `:per-page`   `posts_per_page`
  `:posts`      vector of post dicts in canonical order
  `:pages`      vector of page dicts in page order
  `:tags`       vector of full tag dicts in slug order
  `:tag-links`  vector of tag-link dicts in slug order
  `:page-links` vector of page-link dicts in page order"
  [^java.util.Map config posts pages]
  (let [base-url (str (.get config "base_url"))
        per-page (long (.get config "posts_per_page"))
        posts (vec (canonical-order (remove :draft posts)))
        pages (vec (page-order (remove :draft pages)))
        tag-entries (collect-tags posts)
        tag-links (mapv (fn [[name idxs slug]]
                          (dict "name" name "slug" slug "url" (str "/tags/" slug "/")
                                "post_count" (long (count idxs))))
                        tag-entries)
        link-by-name (into {} (map (fn [[name _ _] link] [name link]) tag-entries tag-links))
        post-links (mapv (fn [p]
                           (let [url (str "/posts/" (:slug p) "/")]
                             (dict "title" (:title p) "slug" (:slug p) "url" url
                                   "permalink" (str base-url url) "date" (:date p)
                                   "date_long" (date-long (:date p)))))
                         posts)
        n (count posts)
        post-dicts (vec
                    (pmap (fn [i p]
                            (let [^LinkedHashMap link (post-links i)]
                              (dict "title" (:title p) "slug" (:slug p)
                                    "url" (.get link "url") "permalink" (.get link "permalink")
                                    "date" (:date p) "date_long" (.get link "date_long")
                                    "tags" (mapv link-by-name (:tags p))
                                    "content" (markdown/->html (:body p))
                                    "excerpt" (markdown/->html (excerpt-source (:body p)))
                                    "older" (when (< (inc i) n) (post-links (inc i)))
                                    "newer" (when (pos? i) (post-links (dec i))))))
                          (range) posts))
        page-dicts (vec
                    (pmap (fn [p]
                            (let [url (str "/" (:slug p) "/")]
                              (dict "title" (:title p) "slug" (:slug p) "url" url
                                    "permalink" (str base-url url)
                                    "content" (markdown/->html (:body p)))))
                          pages))
        tag-dicts (mapv (fn [[name idxs slug] ^LinkedHashMap link]
                          (dict "name" name "slug" slug "url" (.get link "url")
                                "post_count" (.get link "post_count")
                                "posts" (mapv post-dicts idxs)))
                        tag-entries tag-links)]
    {:site config
     :base-url base-url
     :per-page per-page
     :posts post-dicts
     :pages page-dicts
     :tags tag-dicts
     :tag-links tag-links
     :page-links (mapv (fn [^LinkedHashMap p]
                         (dict "title" (.get p "title") "slug" (.get p "slug") "url" (.get p "url")))
                       page-dicts)}))

(defn pagination
  "The pagination dict for index page `number` of `total` pages over
  `total-posts` posts."
  [number total total-posts]
  (dict "number" (long number)
        "total_pages" (long total)
        "total_posts" (long total-posts)
        "has_prev" (> number 1)
        "has_next" (< number total)
        "prev_url" (when (> number 1) (index-url (dec number)))
        "next_url" (when (< number total) (index-url (inc number)))
        "links" (mapv (fn [k] (dict "number" (long k) "url" (index-url k) "current" (== k number)))
                      (range 1 (inc total)))))
