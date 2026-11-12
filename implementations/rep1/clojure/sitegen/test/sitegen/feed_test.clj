(ns sitegen.feed-test
  (:require [clojure.test :refer [deftest is testing]]
            [sitegen.feed :as feed])
  (:import (java.util LinkedHashMap)))

(defn- dict [& kvs]
  (let [m (LinkedHashMap.)]
    (doseq [[k v] (partition 2 kvs)] (.put m k v))
    m))

(deftest escaping
  (is (= "a &amp; b &lt;c&gt; \"d\" 'e'" (feed/escape-text "a & b <c> \"d\" 'e'")))
  (is (= "a &amp;amp; &quot;q&quot; 'e'" (feed/escape-attr "a &amp; \"q\" 'e'")))
  (is (= "&amp;lt;" (feed/escape-text "&lt;")) "ampersands are escaped first, exactly once"))

(deftest atom-feed
  (let [site (dict "title" "A & B" "base_url" "https://x.example" "author" "Me <me>")]
    (testing "without entries"
      (is (= (str "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
                  "<feed xmlns=\"http://www.w3.org/2005/Atom\">\n"
                  "  <title>A &amp; B</title>\n"
                  "  <id>https://x.example/</id>\n"
                  "  <updated>1970-01-01T00:00:00Z</updated>\n"
                  "  <link href=\"https://x.example/\" rel=\"alternate\"/>\n"
                  "  <link href=\"https://x.example/feed.xml\" rel=\"self\"/>\n"
                  "  <author>\n"
                  "    <name>Me &lt;me&gt;</name>\n"
                  "  </author>\n"
                  "</feed>\n")
             (feed/atom-feed site []))))
    (testing "entries: content is escaped and inserted verbatim"
      (let [out (feed/atom-feed site [(dict "title" "T" "permalink" "https://x.example/posts/t/"
                                            "date" "2024-02-01" "content" "<p>x & y</p>\n")])]
        (is (re-find #"<updated>2024-02-01T00:00:00Z</updated>\n  <link" out))
        (is (.contains ^String out (str "  <entry>\n    <title>T</title>\n"
                                        "    <id>https://x.example/posts/t/</id>\n"
                                        "    <updated>2024-02-01T00:00:00Z</updated>\n"
                                        "    <link href=\"https://x.example/posts/t/\" rel=\"alternate\"/>\n"
                                        "    <content type=\"html\">&lt;p&gt;x &amp; y&lt;/p&gt;\n</content>\n"
                                        "  </entry>\n</feed>\n")))))))

(deftest sitemap
  (is (= (str "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
              "<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">\n"
              "  <url>\n    <loc>https://x.example/</loc>\n  </url>\n"
              "  <url>\n    <loc>https://x.example/a&amp;b/</loc>\n    <lastmod>2024-01-01</lastmod>\n  </url>\n"
              "</urlset>\n")
         (feed/sitemap [["https://x.example/" nil] ["https://x.example/a&b/" "2024-01-01"]]))))
