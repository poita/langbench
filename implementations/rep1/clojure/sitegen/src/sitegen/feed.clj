(ns sitegen.feed
  "Generation of `feed.xml` (Atom 1.0) and `sitemap.xml`.")

(set! *warn-on-reflection* true)

(defn escape-text
  "XML text escaping: `&`, `<` and `>`."
  ^String [^String s]
  (-> s (.replace "&" "&amp;") (.replace "<" "&lt;") (.replace ">" "&gt;")))

(defn escape-attr
  "XML attribute escaping: text escaping plus `\"`."
  ^String [^String s]
  (.replace (escape-text s) "\"" "&quot;"))

(defn atom-feed
  "The Atom feed for `site` (a map with `title`, `base_url` and `author`) and
  `entries`, the post dicts to list (already in canonical order and limited
  to the feed size)."
  ^String [^java.util.Map site entries]
  (let [base-url (str (.get site "base_url"))
        updated (if-let [^java.util.Map p (first entries)]
                  (str (.get p "date") "T00:00:00Z")
                  "1970-01-01T00:00:00Z")
        sb (StringBuilder.)
        line (fn [indent s] (.append sb (apply str (repeat (* 2 (long indent)) \space))) (.append sb ^String s) (.append sb \newline))]
    (line 0 "<?xml version=\"1.0\" encoding=\"utf-8\"?>")
    (line 0 "<feed xmlns=\"http://www.w3.org/2005/Atom\">")
    (line 1 (str "<title>" (escape-text (str (.get site "title"))) "</title>"))
    (line 1 (str "<id>" (escape-text (str base-url "/")) "</id>"))
    (line 1 (str "<updated>" updated "</updated>"))
    (line 1 (str "<link href=\"" (escape-attr (str base-url "/")) "\" rel=\"alternate\"/>"))
    (line 1 (str "<link href=\"" (escape-attr (str base-url "/feed.xml")) "\" rel=\"self\"/>"))
    (line 1 "<author>")
    (line 2 (str "<name>" (escape-text (str (.get site "author"))) "</name>"))
    (line 1 "</author>")
    (doseq [^java.util.Map p entries]
      (line 1 "<entry>")
      (line 2 (str "<title>" (escape-text (.get p "title")) "</title>"))
      (line 2 (str "<id>" (escape-text (.get p "permalink")) "</id>"))
      (line 2 (str "<updated>" (.get p "date") "T00:00:00Z</updated>"))
      (line 2 (str "<link href=\"" (escape-attr (.get p "permalink")) "\" rel=\"alternate\"/>"))
      (line 2 (str "<content type=\"html\">" (escape-text (.get p "content")) "</content>"))
      (line 1 "</entry>"))
    (line 0 "</feed>")
    (.toString sb)))

(defn sitemap
  "The sitemap for the given entries, each `[absolute-url lastmod-or-nil]`,
  in the order given."
  ^String [entries]
  (let [sb (StringBuilder.)]
    (.append sb "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n")
    (.append sb "<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">\n")
    (doseq [[url lastmod] entries]
      (.append sb "  <url>\n")
      (.append sb (str "    <loc>" (escape-text url) "</loc>\n"))
      (when lastmod (.append sb (str "    <lastmod>" lastmod "</lastmod>\n")))
      (.append sb "  </url>\n"))
    (.append sb "</urlset>\n")
    (.toString sb)))
