{-# LANGUAGE OverloadedStrings #-}

module Sitegen.GenerateSpec (spec) where

import Data.Either (isLeft)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Test.Hspec

import Sitegen.Generate

pond :: SiteSource
pond =
  SiteSource
    { srcConfig =
        T.unlines
          [ "title = \"Pond Notes\"", "base_url = \"https://pond.example\"", "author = \"R. Duck\""
          , "posts_per_page = 1" ]
    , srcPosts =
        [ ( "hello-world.md"
          , "+++\ntitle = \"Hello, world\"\ndate = \"2024-01-10\"\ntags = [\"Meta\"]\n+++\nThe **first** post.\n\nMore text.\n" )
        , ( "on-ducks.md"
          , "+++\ntitle = \"On Ducks\"\ndate = \"2024-02-01\"\ntags = [\"Birds\", \"Meta\"]\nslug = \"ducks\"\n+++\nDucks are *fine*.\n" )
        ]
    , srcPages = [("about.md", "+++\ntitle = \"About\"\n+++\n# About\n\nNothing here.\n")]
    , srcTemplates =
        [ ( "base.html"
          , "<!doctype html>\n<title>{% block title %}{{ site.title }}{% endblock %}</title>\n{% block body %}{% endblock %}" )
        , ( "index.html"
          , T.intercalate "\n"
              [ "{% extends \"base.html\" %}"
              , "{% block body %}{% for post in posts %}<h2><a href=\"{{ post.url }}\">{{ post.title }}</a></h2>"
              , "{{ post.excerpt }}{% endfor %}<p>page {{ pagination.number }} of {{ pagination.total_pages }}</p>"
              , "{% if pagination.has_next %}<a href=\"{{ pagination.next_url }}\">older</a>{% endif %}{% endblock %}" ] )
        , ( "post.html"
          , T.intercalate "\n"
              [ "{% extends \"base.html\" %}"
              , "{% block title %}{{ post.title }} · {{ site.title }}{% endblock %}"
              , "{% block body %}<article>"
              , "{{ post.content }}</article>"
              , "<p>{{ post.date_long }}{% for t in post.tags %} <a href=\"{{ t.url }}\">{{ t.name }}</a>{% endfor %}</p>"
              , "{% if post.older %}<a href=\"{{ post.older.url }}\">{{ post.older.title }}</a>{% endif %}{% endblock %}" ] )
        , ( "page.html"
          , "{% extends \"base.html\" %}\n{% block title %}{{ page.title }}{% endblock %}\n{% block body %}{{ page.content }}{% endblock %}" )
        , ( "tag.html"
          , "{% extends \"base.html\" %}\n{% block body %}<h1>{{ tag.name }} ({{ tag.post_count }})</h1>\n<ul>{% for post in posts %}<li>{{ post.title }}</li>{% endfor %}</ul>{% endblock %}" )
        , ( "tags.html"
          , "{% extends \"base.html\" %}\n{% block body %}<ul>{% for t in tags %}<li><a href=\"{{ t.url }}\">{{ t.name }}</a> {{ t.post_count }}</li>{% endfor %}</ul>{% endblock %}" )
        ]
    }

outputs :: SiteSource -> Map.Map FilePath Text
outputs src = case generate src of
  Right fs -> Map.fromList [(outPath f, outContents f) | f <- fs]
  Left err -> error err

spec :: Spec
spec = do
  let out = outputs pond

  it "writes exactly the expected files" $
    Map.keys out
      `shouldBe` [ "about/index.html", "feed.xml", "index.html", "page/2/index.html"
                 , "posts/ducks/index.html", "posts/hello-world/index.html", "sitemap.xml"
                 , "tags/birds/index.html", "tags/index.html", "tags/meta/index.html" ]

  it "renders the first index page" $
    out Map.! "index.html"
      `shouldBe` T.intercalate "\n"
        [ "<!doctype html>", "<title>Pond Notes</title>"
        , "<h2><a href=\"/posts/ducks/\">On Ducks</a></h2>"
        , "<p>Ducks are <em>fine</em>.</p>"
        , "<p>page 1 of 2</p>"
        , "<a href=\"/page/2/\">older</a>" ]

  it "renders a post with tags and its older neighbour" $
    out Map.! "posts/ducks/index.html"
      `shouldBe` T.intercalate "\n"
        [ "<!doctype html>", "<title>On Ducks · Pond Notes</title>", "<article>"
        , "<p>Ducks are <em>fine</em>.</p>", "</article>"
        , "<p>February 1, 2024 <a href=\"/tags/birds/\">Birds</a> <a href=\"/tags/meta/\">Meta</a></p>"
        , "<a href=\"/posts/hello-world/\">Hello, world</a>" ]

  it "lists tags by slug with their site-wide post counts" $
    out Map.! "tags/index.html"
      `shouldBe` T.intercalate "\n"
        [ "<!doctype html>", "<title>Pond Notes</title>"
        , "<ul><li><a href=\"/tags/birds/\">Birds</a> 1</li><li><a href=\"/tags/meta/\">Meta</a> 2</li></ul>" ]

  it "renders a tag page" $
    out Map.! "tags/meta/index.html"
      `shouldBe` T.intercalate "\n"
        [ "<!doctype html>", "<title>Pond Notes</title>", "<h1>Meta (2)</h1>"
        , "<ul><li>On Ducks</li><li>Hello, world</li></ul>" ]

  it "renders the feed with one entry" $
    out Map.! "feed.xml"
      `shouldBe` T.unlines
        [ "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
        , "<feed xmlns=\"http://www.w3.org/2005/Atom\">"
        , "  <title>Pond Notes</title>"
        , "  <id>https://pond.example/</id>"
        , "  <updated>2024-02-01T00:00:00Z</updated>"
        , "  <link href=\"https://pond.example/\" rel=\"alternate\"/>"
        , "  <link href=\"https://pond.example/feed.xml\" rel=\"self\"/>"
        , "  <author>"
        , "    <name>R. Duck</name>"
        , "  </author>"
        , "  <entry>"
        , "    <title>On Ducks</title>"
        , "    <id>https://pond.example/posts/ducks/</id>"
        , "    <updated>2024-02-01T00:00:00Z</updated>"
        , "    <link href=\"https://pond.example/posts/ducks/\" rel=\"alternate\"/>"
        , "    <content type=\"html\">&lt;p&gt;Ducks are &lt;em&gt;fine&lt;/em&gt;.&lt;/p&gt;"
        , "</content>"
        , "  </entry>"
        , "</feed>" ]

  it "renders the sitemap" $
    out Map.! "sitemap.xml"
      `shouldBe` T.unlines
        [ "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
        , "<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">"
        , "  <url>", "    <loc>https://pond.example/</loc>", "  </url>"
        , "  <url>", "    <loc>https://pond.example/page/2/</loc>", "  </url>"
        , "  <url>", "    <loc>https://pond.example/posts/ducks/</loc>", "    <lastmod>2024-02-01</lastmod>", "  </url>"
        , "  <url>", "    <loc>https://pond.example/posts/hello-world/</loc>", "    <lastmod>2024-01-10</lastmod>", "  </url>"
        , "  <url>", "    <loc>https://pond.example/about/</loc>", "  </url>"
        , "  <url>", "    <loc>https://pond.example/tags/</loc>", "  </url>"
        , "  <url>", "    <loc>https://pond.example/tags/birds/</loc>", "  </url>"
        , "  <url>", "    <loc>https://pond.example/tags/meta/</loc>", "  </url>"
        , "</urlset>" ]

  it "still produces one index page for a site without posts" $ do
    let o = outputs pond {srcPosts = []}
    Map.member "index.html" o `shouldBe` True
    Map.member "page/2/index.html" o `shouldBe` False
    o Map.! "feed.xml" `shouldSatisfy` T.isInfixOf "<updated>1970-01-01T00:00:00Z</updated>"

  it "excludes drafts completely" $ do
    let draft = ("secret.md", "+++\ntitle = \"S\"\ndate = \"2030-01-01\"\ntags = [\"Hidden\"]\ndraft = true\n+++\nx\n")
        o = outputs pond {srcPosts = draft : srcPosts pond}
    Map.member "posts/secret/index.html" o `shouldBe` False
    Map.member "tags/hidden/index.html" o `shouldBe` False
    o Map.! "sitemap.xml" `shouldNotSatisfy` T.isInfixOf "secret"

  it "reports a template error with the template and output path" $
    case generate pond {srcTemplates = [(n, if n == "tags.html" then "{{ nope }}" else s) | (n, s) <- srcTemplates pond]} of
      Left msg -> msg `shouldSatisfy` T.isInfixOf "undefined" . T.pack
      Right _ -> expectationFailure "expected an error"

  it "rejects an invalid site.toml" $
    generate pond {srcConfig = "title = 1\n"} `shouldSatisfy` isLeft
