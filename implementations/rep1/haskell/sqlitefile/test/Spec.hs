module Main (main) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as B
import Data.Int (Int64)
import SqliteFile
import SqliteFile.DDL
import SqliteFile.Format (formatReal)
import SqliteFile.Query
import SqliteFile.Value
import SqliteFile.Varint (getVarint)
import Test.Hspec
import Test.QuickCheck
import TestDb

query :: Session -> String -> IO String
query s q = either (const "error") B.unpack <$> runQuery s (B.pack q)

main :: IO ()
main = hspec $ do
  describe "formatReal" $ do
    let cases =
          [ (1.0, "1.0"), (0.1, "0.1"), (-3.25, "-3.25"), (1 / 3, "0.333333333333333")
          , (1e300, "1.0e+300"), (2.5e-10, "2.5e-10"), (1.5e16, "1.5e+16")
          , (1e14, "100000000000000.0"), (1e15, "1.0e+15"), (0.0001, "0.0001")
          , (1e-5, "1.0e-05"), (0.0, "0.0"), (-0.0, "0.0") ]
    mapM_ (\(d, s) -> it (show d) (formatReal d `shouldBe` B.pack s)) cases
    it "round-trips through 15 digits for short decimals" $
      property $ \(n :: Int) (k :: Int) ->
        let v = fromIntegral (n `mod` 100000) / (10 ^^ (k `mod` 6)) :: Double
         in (read (B.unpack (formatReal v)) :: Double) === v

  describe "varints" $ do
    it "decodes multi-byte values" $
      getVarint (BS.pack [0x81, 0x00]) 0 `shouldBe` (128, 2)
    it "decodes nine-byte negatives" $
      getVarint (BS.replicate 9 0xff) 0 `shouldBe` (-1, 9)
    it "round-trips encodeVarint" $
      property $ \(v :: Int64) -> fst (getVarint (encodeVarint v) 0) === v

  describe "affinity" $ do
    it "applies the rules in order" $ do
      affinityOf (B.pack "POINT") `shouldBe` AffInteger
      affinityOf (B.pack "STRING") `shouldBe` AffNumeric
      affinityOf (B.pack "CHARFLOAT") `shouldBe` AffText
      affinityOf (B.pack "BLOBREAL") `shouldBe` AffBlob
      affinityOf B.empty `shouldBe` AffBlob
      affinityOf (B.pack "DOUBLE") `shouldBe` AffReal
    it "converts numeric text for numeric columns" $ do
      applyAffinity AffInteger (VText (B.pack " 5 ")) `shouldBe` VInt 5
      applyAffinity AffReal (VText (B.pack ".5")) `shouldBe` VReal 0.5
      applyAffinity AffNumeric (VText (B.pack "9223372036854775807")) `shouldBe` VInt maxBound
      applyAffinity AffInteger (VText (B.pack "0x10")) `shouldBe` VText (B.pack "0x10")
      applyAffinity AffText (VReal 1) `shouldBe` VText (B.pack "1.0")
      applyAffinity AffBlob (VInt 1) `shouldBe` VInt 1

  describe "compareValues" $ do
    it "orders storage classes" $
      compareValues VNull (VInt 0) `shouldBe` LT
    it "orders numbers before text before blobs" $ do
      compareValues (VInt 99) (VText B.empty) `shouldBe` LT
      compareValues (VText (B.pack "z")) (VBlob B.empty) `shouldBe` LT
    it "compares large integers exactly" $
      compareValues (VInt maxBound) (VInt (maxBound - 1)) `shouldBe` GT
    it "is antisymmetric on ints and reals" $
      property $ \(a :: Int64) (b :: Double) ->
        compareValues (VInt a) (VReal b) === compare EQ (compareValues (VReal b) (VInt a))

  describe "DDL parsing" $ do
    it "finds a column-level rowid alias" $
      fmap tdRowidAlias (parseCreateTable (B.pack "CREATE TABLE t(a TEXT, id INTEGER PRIMARY KEY, b)"))
        `shouldBe` Just (Just 1)
    it "treats PRIMARY KEY DESC at column level as no alias" $
      fmap tdRowidAlias (parseCreateTable (B.pack "CREATE TABLE t(x INTEGER PRIMARY KEY DESC)"))
        `shouldBe` Just Nothing
    it "treats a table-level PRIMARY KEY(x DESC) as an alias" $
      fmap tdRowidAlias (parseCreateTable (B.pack "CREATE TABLE t(x INTEGER, PRIMARY KEY(x DESC))"))
        `shouldBe` Just (Just 0)
    it "does not alias INT PRIMARY KEY" $
      fmap tdRowidAlias (parseCreateTable (B.pack "CREATE TABLE t(x INT PRIMARY KEY)"))
        `shouldBe` Just Nothing
    it "keeps parenthesised types intact and quoted names" $
      fmap (map cdName . tdColumns) (parseCreateTable (B.pack "CREATE TABLE \"t\"([a b] NUMERIC(10,2), `c``d` TEXT DEFAULT 'x,y')"))
        `shouldBe` Just [B.pack "a b", B.pack "c`d"]
    it "parses CREATE INDEX" $
      parseCreateIndex (B.pack "CREATE UNIQUE INDEX IF NOT EXISTS main.i ON t (a COLLATE BINARY DESC, \"b\")")
        `shouldBe` Just (IndexDef (B.pack "i") (B.pack "t") [B.pack "a", B.pack "b"])

  describe "query parser" $ do
    let ok s = parseCommand (B.pack s) `shouldSatisfy` (/= Nothing)
        bad s = parseCommand (B.pack s) `shouldBe` Nothing
    it "accepts flexible spacing" $ do
      ok "SELECT*FROM t"
      ok "SELECT a,b FROM t WHERE a>=1"
      ok "select  a ,  b  from  t  where  a  is  not  null  order  by  a  desc  limit  3"
      ok "SELECT a FROM t WHERE a=-1.5e3 AND b=X'0aFF' AND c='it''s'"
    it "rejects malformed queries" $ do
      bad "SELECTa FROM t"
      bad "SELECT a FROM t ORDERBY a"
      bad "SELECT a FROM t LIMIT3"
      bad "SELECT a FROM t LIMIT -1"
      bad "SELECT a FROM t WHERE a == 1"
      bad "SELECT a FROM t WHERE a <> 1"
      bad "SELECT a FROM t WHERE a = .5"
      bad "SELECT a FROM t WHERE a = 1e"
      bad "SELECT a FROM t WHERE a = X'0'"
      bad "SELECT a FROM t ORDER BY a ASC DESC"
      bad ".SCHEMA t"
      bad ".schema 9x"
      bad ".tables x"
    it "parses a full select" $
      parseCommand (B.pack "SELECT a FROM t WHERE b IS NULL ORDER BY a DESC LIMIT 2")
        `shouldBe` Just
          ( SelectCmd
              (Select (Columns [B.pack "a"]) (B.pack "t") [Cond (B.pack "b") OpIs VNull] (Just (B.pack "a", Desc)) (Just 2))
          )

  describe "queries on a built database" $ do
    session <- runIO $ do
      r <- openSession fixtureDb
      either (\e -> fail (show e)) pure r
    it ".tables" $ query session ".tables" `shouldReturn` "blobs\ndeep\npeople\n"
    it ".schema" $
      query session ".schema people"
        `shouldReturn` "CREATE TABLE people(id INTEGER PRIMARY KEY, name TEXT, age INTEGER, height REAL);\nCREATE INDEX people_age ON people(age);\n"
    it "COUNT walks interior pages" $ do
      query session "COUNT deep" `shouldReturn` "6\n"
      query session "COUNT people" `shouldReturn` "4\n"
    it "SELECT * substitutes the rowid alias and widens reals" $
      query session "SELECT * FROM people"
        `shouldReturn` "1\tAda\t36\t1.65\n2\tGrace\t45\t2.0\n3\tAlan\tNULL\t1.8\n6\t\t45\t0.0\n"
    it "filters, orders and limits" $ do
      query session "SELECT name FROM people WHERE age > 40" `shouldReturn` "Grace\n\n"
      query session "SELECT name FROM people ORDER BY age DESC LIMIT 2" `shouldReturn` "Grace\n\n"
      query session "SELECT rowid,name FROM people WHERE age IS NULL" `shouldReturn` "3\tAlan\n"
    it "reads a two-level table B-tree in order" $
      query session "SELECT v FROM deep" `shouldReturn` "row1\nrow2\nrow3\nrow4\nrow5\nrow6\n"
    it "reassembles overflow payloads" $ do
      out <- query session "SELECT data FROM blobs"
      length out `shouldBe` 2000 + 1
    it "INDEX returns matching rows through the index" $ do
      query session "INDEX people_age 45" `shouldReturn` "2\tGrace\t45\t2.0\n6\t\t45\t0.0\n"
      query session "INDEX people_age '36'" `shouldReturn` "1\tAda\t36\t1.65\n"
      query session "INDEX people_age NULL" `shouldReturn` ""
    it "reports errors" $ do
      query session "SELECT nope FROM people" `shouldReturn` "error"
      query session "SELECT * FROM sqlite_schema" `shouldReturn` "error"
      query session "INDEX people 1" `shouldReturn` "error"
      query session "COUNT nosuch" `shouldReturn` "error"
    it "reports a bad column even on an empty result" $
      query session "SELECT nope FROM people WHERE age = 12345" `shouldReturn` "error"
