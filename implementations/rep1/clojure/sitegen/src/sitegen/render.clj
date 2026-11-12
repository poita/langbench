(ns sitegen.render
  "Renders a built model into the files of the site: the index pages, posts,
  pages, tag pages, `feed.xml` and `sitemap.xml`.  The result is an in-memory
  map from output path (relative, `/`-separated) to file text."
  (:require [sitegen.feed :as feed]
            [sitegen.model :as model :refer [dict]]
            [sitegen.template :as template])
  (:import (java.util LinkedHashMap)))

(set! *warn-on-reflection* true)

(defn- context
  "A root scope holding the shared variables plus `extra` (alternating names
  and values)."
  ^LinkedHashMap [shared & extra]
  (let [m (LinkedHashMap. ^java.util.Map shared)]
    (loop [kvs (seq extra)]
      (when kvs
        (.put m (first kvs) (second kvs))
        (recur (nnext kvs))))
    m))

(defn render-files
  "Renders every generated file of the site described by `model` using the
  templates in `env` (see `sitegen.template/make-env`).  Returns a map from
  relative output path to file text."
  [model env]
  (let [{:keys [site base-url per-page posts pages tags tag-links page-links]} model
        shared (dict "site" site "tags" tag-links "pages" page-links)
        render #(template/render env %1 %2)
        n-posts (count posts)
        n-index (model/total-pages n-posts per-page)
        index-files
        (for [k (range 1 (inc n-index))]
          (let [from (* (dec k) per-page)
                slice (subvec posts (min from n-posts) (min (+ from per-page) n-posts))]
            [(if (== k 1) "index.html" (str "page/" k "/index.html"))
             (render "index.html" (context shared
                                           "posts" slice
                                           "pagination" (model/pagination k n-index n-posts)))]))
        post-files
        (for [^java.util.Map p posts]
          [(str "posts/" (.get p "slug") "/index.html")
           (render "post.html" (context shared "post" p))])
        page-files
        (for [^java.util.Map p pages]
          [(str (.get p "slug") "/index.html")
           (render "page.html" (context shared "page" p))])
        tag-files
        (cons ["tags/index.html" (render "tags.html" (context shared))]
              (for [^java.util.Map t tags]
                [(str "tags/" (.get t "slug") "/index.html")
                 (render "tag.html" (context shared "tag" t "posts" (.get t "posts")))]))
        feed-xml (feed/atom-feed site (take per-page posts))
        sitemap-xml (feed/sitemap
                     (concat (for [k (range 1 (inc n-index))] [(str base-url (model/index-url k)) nil])
                             (for [^java.util.Map p posts] [(.get p "permalink") (.get p "date")])
                             (for [^java.util.Map p pages] [(.get p "permalink") nil])
                             [[(str base-url "/tags/") nil]]
                             (for [^java.util.Map t tags] [(str base-url (.get t "url")) nil])))]
    (into {"feed.xml" feed-xml "sitemap.xml" sitemap-xml}
          (concat index-files post-files page-files tag-files))))
