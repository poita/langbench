module XmlSpec (spec) where

import qualified Data.Map.Strict as Map
import Test.Hspec

import Graphics.SVG.Raster.Xml

spec :: Spec
spec = do
  it "parses nested elements and attributes" $ do
    let Just el = parseXml "<svg a=\"1\" b='2'><g><rect/></g><circle r = \"3\" /></svg>"
    elName el `shouldBe` "svg"
    attr "a" el `shouldBe` Just "1"
    attr "b" el `shouldBe` Just "2"
    map elName (elChildren el) `shouldBe` ["g", "circle"]
    attr "r" (elChildren el !! 1) `shouldBe` Just "3"

  it "skips the prolog, comments, doctype and CDATA" $ do
    let doc =
          "<?xml version=\"1.0\"?>\n<!-- <fake/> -->\n\
          \<!DOCTYPE svg [ <!ENTITY x \"<y>\"> ]>\n\
          \<svg><![CDATA[ <not-an-element/> ]]><!-- c --><g/></svg>"
        Just el = parseXml doc
    elName el `shouldBe` "svg"
    map elName (elChildren el) `shouldBe` ["g"]

  it "ignores '>' inside quoted attribute values" $ do
    let Just el = parseXml "<svg><path d=\"a>b\" fill='x\"y'/><g/></svg>"
    map elName (elChildren el) `shouldBe` ["path", "g"]
    attr "d" (head (elChildren el)) `shouldBe` Just "a>b"
    attr "fill" (head (elChildren el)) `shouldBe` Just "x\"y"

  it "strips namespace prefixes" $ do
    let Just el = parseXml "<svg:svg xmlns:svg=\"u\"><svg:use xlink:href=\"#a\"/></svg:svg>"
    elName el `shouldBe` "svg"
    attr "href" (head (elChildren el)) `shouldBe` Just "#a"

  it "lets the last duplicate attribute win" $ do
    let Just el = parseXml "<svg a=\"1\" a=\"2\" x:a=\"3\"/>"
    Map.lookup "a" (elAttrs el) `shouldBe` Just "3"

  it "decodes entities in attribute values" $
    decodeEntities "&amp;&lt;&gt;&quot;&apos;&#65;&#x42;&bogus;&#xZZ;"
      `shouldBe` "&<>\"'AB&bogus;&#xZZ;"

  it "returns Nothing without an element" $ do
    parseXml "" `shouldBe` Nothing
    parseXml "<!-- only a comment -->" `shouldBe` Nothing

  it "ignores character data" $ do
    let Just el = parseXml "<svg>hello <g/> world</svg>"
    map elName (elChildren el) `shouldBe` ["g"]
