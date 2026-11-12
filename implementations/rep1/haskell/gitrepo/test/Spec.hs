{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -Wno-incomplete-uni-patterns #-}

module Main (main) where

import Control.Monad (forM_)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.Char (digitToInt)
import Data.Word (Word8)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath ((</>))
import Test.Hspec
import Test.QuickCheck

import Git
import Git.Delta (applyDelta)
import Git.Inflate
import Git.Pack
import Git.Quote (quotePath)
import Git.SHA1 (sha1Hex)

import TestRepo

fromHex :: String -> BS.ByteString
fromHex (a : b : r) = BS.cons (fromIntegral (digitToInt a * 16 + digitToInt b)) (fromHex r)
fromHex _ = BS.empty

blob :: BS.ByteString -> RawObject
blob = RawObject TBlob

main :: IO ()
main = hspec $ do
  sha1Spec
  inflateSpec
  deltaSpec
  quoteSpec
  objectSpec
  packSpec
  repoSpec

------------------------------------------------------------------------------

sha1Spec :: Spec
sha1Spec = describe "Git.SHA1" $ do
  it "matches the FIPS 180 vectors" $ do
    sha1Hex "" `shouldBe` "da39a3ee5e6b4b0d3255bfef95601890afd80709"
    sha1Hex "abc" `shouldBe` "a9993e364706816aba3e25717850c26c9cd0d89d"
    sha1Hex "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
      `shouldBe` "84983e441c3bd26ebaae4aa1f95129e5e54670f1"
  it "hashes a million 'a's" $
    sha1Hex (BC.replicate 1000000 'a') `shouldBe` "34aa973cd4c4daa4f61eeb2bdbad27316534016f"
  it "hashes messages around the block boundary (55..65 bytes) to distinct digests" $
    length (nubOrd [sha1Hex (BC.replicate n 'x') | n <- [54 .. 66]]) `shouldBe` 13
  it "gives git's id for a blob" $
    hashObject (blob "one file\n") `shouldBe` oidOf "b7814cae2e925fe74c6cd5816462fff515ccb256"

oidOf :: BS.ByteString -> ObjectId
oidOf h = maybe (error "bad hex") id (objectIdFromHex h)

nubOrd :: Ord a => [a] -> [a]
nubOrd = foldr (\x acc -> if x `elem` acc then acc else x : acc) []

------------------------------------------------------------------------------

dynamicText :: BS.ByteString
dynamicText =
  "zeta gamma eta alpha beta beta zeta alpha delta alpha beta eta eta beta delta beta eta alpha beta delta alpha eta alpha delta alpha gamma epsilon eta gamma beta epsilon gamma beta delta zeta beta beta alpha delta theta eta zeta theta theta zeta epsilon delta gamma delta beta epsilon theta zeta theta epsilon beta beta eta gamma zeta gamma theta eta alpha beta zeta zeta zeta theta theta beta beta epsilon theta beta alpha epsilon theta epsilon eta zeta alpha theta zeta gamma beta theta alpha delta epsilon gamma delta eta eta theta beta gamma theta eta epsilon gamma eta epsilon eta zeta eta delta gamma beta gamma gamma delta delta alpha theta gamma epsilon epsilon alpha gamma"

-- Produced by zlib at level 9; the block is dynamic Huffman.
dynamicZ :: BS.ByteString
dynamicZ =
  fromHex
    "78da6d925d0e84200c84afc2d5306bd64d70d7647deae98d4cb55f890f94d29f99a160f35ecbbbae6b2da757dbb6d4329d6e3716c1d7dc72c1b5fa41d93b8e32f63da339fdf6ffb4dfb78420a1791821f5dacd3d8db0fb72e9e8453aca1a31552d645ec0d3e870444f046b88b570831e63b06ca809708919f7ca098e0a2f04bd9896a21c4f1ea9c77c8179bc4c6e7bd411af03017249c6c717fef0057cc7f73800b435f5d7"

inflated :: BS.ByteString -> BS.ByteString
inflated z = either (error . show) inflatedBytes (zlibDecompress z)

inflateSpec :: Spec
inflateSpec = describe "Git.Inflate" $ do
  it "decodes a fixed-Huffman block" $ do
    inflated (fromHex "78dacb48cdc9c957c84027b90070be08bb") `shouldBe` "hello hello hello hello\n"
    inflated (fromHex "78014b4c4a4e4442002df505bf") `shouldBe` "abcabcabcabcabc"
  it "decodes a dynamic-Huffman block" $ inflated dynamicZ `shouldBe` dynamicText
  it "decodes an empty stream and a stored block" $ do
    inflated (fromHex "789c030000000001") `shouldBe` ""
    inflated (fromHex "7801010b00f4ff73746f72656420646174611ab2044c") `shouldBe` "stored data"
  it "reports where the stream ends, ignoring what follows" $ do
    let z = fromHex "78dacb48cdc9c957c84027b90070be08bb"
    fmap inflatedConsumed (zlibDecompress (z <> "garbage")) `shouldBe` Right (BS.length z)
  it "rejects a bad header, a bad check value and a dictionary" $ do
    zlibDecompress (fromHex "7701") `shouldSatisfy` isLeft'
    zlibDecompress (fromHex "7802010000ffff00000001") `shouldSatisfy` isLeft'
    zlibDecompress (fromHex "7820") `shouldSatisfy` isLeft'
  it "rejects truncated and corrupted streams" $ do
    forM_ [0 .. BS.length dynamicZ - 1] $ \n ->
      zlibDecompress (BS.take n dynamicZ) `shouldSatisfy` isLeft'
    let flipped = BS.take 40 dynamicZ <> BS.cons 0xff (BS.drop 41 dynamicZ)
    zlibDecompress flipped `shouldSatisfy` (either (const True) ((/= dynamicText) . inflatedBytes))
  it "rejects an Adler-32 mismatch" $
    zlibDecompress (BS.init dynamicZ <> BS.singleton 0) `shouldSatisfy` isLeft'
  it "computes Adler-32 (Wikipedia example)" $ adler32 "Wikipedia" `shouldBe` 0x11E60398
  it "inflates raw DEFLATE" $
    fmap inflatedBytes (inflateRaw (BS.pack [0x01, 0x03, 0x00, 0xfc, 0xff, 0x61, 0x62, 0x63]))
      `shouldBe` Right "abc"
  it "round-trips stored streams of any size" $ property $ \(bytes :: [Word8]) ->
    let b = BS.pack bytes in inflated (zlibStored b) === b
  it "round-trips multi-block stored streams" $
    let b = BS.pack (take 150000 (cycle [0 .. 250])) in inflated (zlibStored b) `shouldBe` b

isLeft' :: Either a b -> Bool
isLeft' = either (const True) (const False)

------------------------------------------------------------------------------

deltaSpec :: Spec
deltaSpec = describe "Git.Delta" $ do
  let base = "0123456789abcdef"
  it "applies copy and insert instructions" $ do
    -- sizes 16 -> 9; copy 4 bytes at offset 2; insert "XY"; copy 3 bytes at 10
    let d = BS.pack [16, 9, 0x91, 2, 4, 2, 0x58, 0x59, 0x91, 10, 3]
    applyDelta base d `shouldBe` Right "2345XYabc"
  it "treats a copy size of 0 as 0x10000" $ do
    let big = BS.replicate 0x10000 7
    applyDelta big (BS.pack [0x80, 0x80, 0x04, 0x80, 0x80, 0x04, 0x80]) `shouldBe` Right big
  it "rejects bad deltas" $ do
    applyDelta base (BS.pack [16, 4, 0x00]) `shouldSatisfy` isLeft'
    applyDelta base (BS.pack [16, 4, 0x91, 14, 4]) `shouldSatisfy` isLeft'
    applyDelta base (BS.pack [16, 5, 0x91, 0, 4]) `shouldSatisfy` isLeft'
    applyDelta base (BS.pack [16, 2, 0x91, 0, 4]) `shouldSatisfy` isLeft'
    applyDelta base (BS.pack [16, 3, 3, 0x41]) `shouldSatisfy` isLeft'
  it "is the identity for a whole-base copy" $ property $ \(NonEmpty xs) ->
    let b = BS.pack (take 1000 xs)
     in applyDelta b (BS.concat [BS.pack (varintLE (BS.length b)), BS.pack (varintLE (BS.length b)), copyAll (BS.length b)]) === Right b

------------------------------------------------------------------------------

quoteSpec :: Spec
quoteSpec = describe "Git.Quote" $ do
  it "leaves plain names alone" $ quotePath "dir/file name.txt" `shouldBe` "dir/file name.txt"
  it "escapes UTF-8 as octal" $ quotePath "caf\xc3\xa9.txt" `shouldBe` "\"caf\\303\\251.txt\""
  it "escapes quotes, backslashes and control characters" $ do
    quotePath "quote\"and\\slash.txt" `shouldBe` "\"quote\\\"and\\\\slash.txt\""
    quotePath "a\tb\nc\a\x01\x7f" `shouldBe` "\"a\\tb\\nc\\a\\001\\177\""

------------------------------------------------------------------------------

objectSpec :: Spec
objectSpec = describe "Git.Object" $ do
  it "parses a stored form and rejects damaged ones" $ do
    parseStoredForm "blob 9\0one file\n" `shouldBe` Right (blob "one file\n")
    parseStoredForm "blob 8\0one file\n" `shouldSatisfy` isLeft'
    parseStoredForm "blob 9one file\n" `shouldSatisfy` isLeft'
    parseStoredForm "blub 3\0abc" `shouldSatisfy` isLeft'
    parseStoredForm "blob \0" `shouldSatisfy` isLeft'
  it "computes the subject like the spec's example" $ do
    let Right c = parseCommit (BS.concat ["author A <a> 1 +0000\n\n", "\n\nFix the thing   \nand the other\n\nbody\n"])
    commitSubject c `shouldBe` "Fix the thing and the other"
  it "has an empty subject for an empty message" $ do
    let Right c = parseCommit "author A <a> 1 +0000\n"
    commitSubject c `shouldBe` ""
  it "reads idents, headers (last wins) and continuation lines" $ do
    let t = "tree " <> BC.replicate 40 '1'
        p1 = "parent " <> BC.replicate 40 '2'
        p2 = "parent " <> BC.replicate 40 '3'
        Right c =
          parseCommit . BS.intercalate "\n" $
            [ t, p1, p2, "author Ada  Lovelace  <ada@x.org> 1400000000 +0100"
            , "committer Bob <b@x>  +17 +0000", "gpgsig -----BEGIN", " tree " <> BC.replicate 40 '9', " -----END", "", "msg\n" ]
    commitTree c `shouldBe` Just (oidOf (BC.replicate 40 '1'))
    commitParents c `shouldBe` [oidOf (BC.replicate 40 '2'), oidOf (BC.replicate 40 '3')]
    commitAuthor c `shouldBe` Ident "Ada  Lovelace" 1400000000
    commitCommitter c `shouldBe` Ident "Bob" 17
    commitMessage c `shouldBe` "msg\n"
  it "parses trees and classifies entries by mode" $ do
    let raw n = BS.replicate 20 n
        payload = BS.concat ["40000 d\0", raw 1, "100644 f\0", raw 2, "160000 sub\0", raw 3, "120000 l\0", raw 4]
        Right es = parseTree payload
    map entryType es `shouldBe` [TTree, TBlob, TCommit, TBlob]
    map entryName es `shouldBe` ["d", "f", "sub", "l"]
    parseTree "100644 f\0short" `shouldSatisfy` isLeft'
  it "parses tags" $ do
    let Right t = parseTag ("object " <> BC.replicate 40 'a' <> "\ntype commit\ntag v1\n\nmsg\n")
    tagTarget t `shouldBe` oidOf (BC.replicate 40 'a')
    tagName t `shouldBe` "v1"
    parseTag "type commit\n" `shouldSatisfy` isLeft'

------------------------------------------------------------------------------

packSpec :: Spec
packSpec = describe "Git.Pack" $ do
  let b0 = blob (BC.replicate 300 'a')
      b1 = blob (objectPayload b0 <> "more")
      (pk, ix) = buildPack [Whole b0, OfsOf 0 b0 b1]
  it "finds ids through the fanout and binary search" $ do
    let Right index = parseIndex ix
    indexCount index `shouldBe` 2
    forM_ [b0, b1] $ \o -> do
      let Just i = indexLookup index (hashObject o)
      indexIdAt index i `shouldBe` hashObject o
    indexLookup index (oidOf (BC.replicate 40 '0')) `shouldBe` Nothing
  it "reads whole and delta entries" $ do
    checkPackHeader pk `shouldBe` True
    let Right index = parseIndex ix
        Just i0 = indexLookup index (hashObject b0)
        Just o0 = indexOffsetAt index i0
    readPackEntry pk o0 `shouldBe` Right (PackObject TBlob (objectPayload b0))
    readPackEntry pk 5 `shouldSatisfy` isLeft'
  it "matches abbreviated prefixes" $ do
    let Right index = parseIndex ix
        hex = objectIdToHex (hashObject b0)
        Just p = mkHexPrefix (BS.take 7 hex)
    indexPrefixMatches 2 index p `shouldBe` [hashObject b0]
    indexPrefixMatches 2 index (maybe (error "p") id (mkHexPrefix (BS.take 1 hex))) `shouldSatisfy` (hashObject b0 `elem`)
  it "rejects bad indexes" $ do
    parseIndex "nope" `shouldSatisfy` isLeft'
    parseIndex (BS.take 1100 ix) `shouldSatisfy` isLeft'

------------------------------------------------------------------------------

-- A small repository used by the end-to-end tests.
data Fixture = Fixture
  { fxInput :: FilePath
  , fxObjs :: [(String, ObjectId)]
  }

entryBytes :: Int -> BS.ByteString -> ObjectId -> BS.ByteString
entryBytes mode name oid = BS.concat [BC.pack (showOctal mode), " ", name, "\0", objectIdBytes oid]
  where
    showOctal 0 = "0"
    showOctal n = reverse (go n)
    go 0 = ""
    go n = toEnum (48 + n `mod` 8) : go (n `div` 8)

commitObj :: ObjectId -> [ObjectId] -> Int -> BS.ByteString -> RawObject
commitObj tree parents ts msg =
  RawObject TCommit . BS.concat $
    ["tree ", objectIdToHex tree, "\n"]
      ++ concat [["parent ", objectIdToHex p, "\n"] | p <- parents]
      ++ ["author Ada <ada@example.org> ", BC.pack (show ts), " +0000\n"]
      ++ ["committer Ada <ada@example.org> ", BC.pack (show ts), " +0000\n\n", msg]

mkFixture :: FilePath -> IO Fixture
mkFixture input = do
  let repo = input </> "repo"
      loose = writeLoose repo
  hello <- loose (blob "hello\n")
  hello2 <- loose (blob "hello, world\n")
  sub <- loose (blob "sub\n")
  treeSub <- loose (RawObject TTree (entryBytes 0o100644 "inner.txt" sub))
  treeRoot <-
    loose . RawObject TTree . BS.concat $
      [ entryBytes 0o100644 "a.txt" hello
      , entryBytes 0o100644 "caf\xc3\xa9.txt" hello
      , entryBytes 0o40000 "dir" treeSub
      , entryBytes 0o100755 "run" hello
      ]
  treeRoot2 <-
    loose . RawObject TTree . BS.concat $
      [ entryBytes 0o100644 "a.txt" hello2
      , entryBytes 0o100644 "caf\xc3\xa9.txt" hello
      , entryBytes 0o120000 "run" hello
      , entryBytes 0o100644 "z" sub
      ]
  c1 <- loose (commitObj treeRoot [] 1000 "root\n")
  c2 <- loose (commitObj treeRoot2 [c1] 2000 "second\n\nbody\n")
  c3 <- loose (commitObj treeRoot [c1] 1500 "side\n")
  m <- loose (commitObj treeRoot2 [c2, c3] 3000 "merge\n")
  tag <- loose (RawObject TTag (BS.concat ["object ", objectIdToHex c2, "\ntype commit\ntag v1\ntagger Ada <a> 1 +0000\n\nrelease\n"]))
  -- a pack holding a delta chain, with one REF_DELTA based on a loose blob
  let big = blob (BC.replicate 500 'q')
      big2 = blob (objectPayload big <> "!")
      big3 = blob (objectPayload big2 <> "?")
      viaLoose = blob ("hello\n" <> "appended")
      (pk, ix) = buildPack [Whole big, OfsOf 0 big big2, OfsOf 1 big2 big3, RefOf (blob "hello\n") viaLoose]
  createDirectoryIfMissing True (repo </> "objects" </> "pack")
  BS.writeFile (repo </> "objects" </> "pack" </> "pack-test.pack") pk
  BS.writeFile (repo </> "objects" </> "pack" </> "pack-test.idx") ix
  -- an orphan idx that must be ignored
  BS.writeFile (repo </> "objects" </> "pack" </> "pack-orphan.idx") ix
  -- a damaged loose object: the file for "good" holds a different blob
  let goodId = hashObject (blob "good\n")
      goodHex = BC.unpack (objectIdToHex goodId)
  writeFileAt repo ("objects" </> take 2 goodHex </> drop 2 goodHex) (looseFile (blob "evil\n"))
  writeFileAt repo "HEAD" "ref: refs/heads/main\n"
  writeFileAt repo ("refs" </> "heads" </> "main") (objectIdToHex m <> "\n")
  forM_ [("c1", c1), ("c2", c2), ("c3", c3)] $ \(n, c) ->
    writeFileAt repo ("refs" </> "heads" </> n) (objectIdToHex c <> "\n")
  writeFileAt repo ("refs" </> "tags" </> "v1") (objectIdToHex tag <> "\n")
  writeFileAt repo "packed-refs" (BS.concat ["# pack-refs with: peeled\n", objectIdToHex c3, " refs/heads/side\n", objectIdToHex c1, " refs/heads/main\n"])
  writeFileAt repo "config" "[core]\n"
  pure . Fixture input $
    [ ("hello", hello), ("hello2", hello2), ("sub", sub), ("treeSub", treeSub), ("treeRoot", treeRoot), ("treeRoot2", treeRoot2)
    , ("c1", c1), ("c2", c2), ("c3", c3), ("m", m), ("tag", tag), ("good", goodId)
    , ("big", hashObject big), ("big3", hashObject big3), ("viaLoose", hashObject viaLoose) ]

withFixture :: (Fixture -> Repository -> IO a) -> IO a
withFixture act = withTempDir $ \d -> do
  fx <- mkFixture d
  repo <- openRepository (d </> "repo")
  act fx repo

ask :: Repository -> BS.ByteString -> IO BS.ByteString
ask = answer

repoSpec :: Spec
repoSpec = describe "end to end" $ do
  let hexOf :: Fixture -> String -> BS.ByteString
      hexOf fx n = maybe (error n) objectIdToHex (lookup n (fxObjs fx))
  it "rev-parse follows HEAD, branches, tags and suffixes" $ withFixture $ \fx repo -> do
    let h = hexOf fx
    ask repo "rev-parse HEAD" `shouldReturn` h "m" <> "\n"
    ask repo "rev-parse main" `shouldReturn` h "m" <> "\n"
    ask repo "rev-parse refs/heads/main" `shouldReturn` h "m" <> "\n"
    ask repo "rev-parse heads/side" `shouldReturn` h "c3" <> "\n"
    ask repo "rev-parse side" `shouldReturn` h "c3" <> "\n"
    ask repo "rev-parse v1" `shouldReturn` h "tag" <> "\n"
    ask repo "rev-parse v1^{}" `shouldReturn` h "c2" <> "\n"
    ask repo "rev-parse v1^{commit}" `shouldReturn` h "c2" <> "\n"
    ask repo "rev-parse v1^{tree}" `shouldReturn` h "treeRoot2" <> "\n"
    ask repo "rev-parse v1^{blob}" `shouldReturn` "error\n"
    ask repo "rev-parse main^" `shouldReturn` h "c2" <> "\n"
    ask repo "rev-parse main^2" `shouldReturn` h "c3" <> "\n"
    ask repo "rev-parse main^3" `shouldReturn` "error\n"
    ask repo "rev-parse main^0" `shouldReturn` h "m" <> "\n"
    ask repo "rev-parse main~2" `shouldReturn` h "c1" <> "\n"
    ask repo "rev-parse main~3" `shouldReturn` "error\n"
    ask repo "rev-parse main^2~1^{tree}" `shouldReturn` h "treeRoot" <> "\n"
    ask repo "rev-parse main~" `shouldReturn` h "c2" <> "\n"
    ask repo "rev-parse main^^" `shouldReturn` h "c1" <> "\n"
    ask repo "rev-parse v1~1" `shouldReturn` h "c1" <> "\n"
    ask repo "rev-parse ^{}" `shouldReturn` "error\n"
    ask repo "rev-parse main^{bogus}" `shouldReturn` "error\n"
    ask repo "rev-parse config" `shouldReturn` "error\n"
    ask repo "rev-parse  HEAD" `shouldReturn` "error\n"
    ask repo "rev-parse HEAD " `shouldReturn` "error\n"
    ask repo "rev-parse" `shouldReturn` "error\n"
    ask repo "rev-parse HEAD HEAD" `shouldReturn` "error\n"
  it "resolves full and abbreviated ids" $ withFixture $ \fx repo -> do
    let h = hexOf fx
        full = h "c2"
    ask repo ("rev-parse " <> full) `shouldReturn` full <> "\n"
    ask repo ("rev-parse " <> BS.take 8 full) `shouldReturn` full <> "\n"
    ask repo ("rev-parse " <> BC.map toUpper' (BS.take 10 full)) `shouldReturn` full <> "\n"
    ask repo ("rev-parse " <> BS.take 3 full) `shouldReturn` "error\n"
    ask repo ("rev-parse " <> BC.replicate 40 '0') `shouldReturn` "error\n"
    ask repo "rev-parse 0000" `shouldReturn` "error\n"
    ask repo ("rev-parse " <> h "big" <> "^{object}") `shouldReturn` h "big" <> "\n"
  it "answers count-objects" $ withFixture $ \_ repo ->
    ask repo "count-objects" `shouldReturn` "loose: 12\nin-pack: 4\npacks: 1\n"
  it "walks log in committer-date order and honours the limit" $ withFixture $ \fx repo -> do
    let h = hexOf fx
        line k ts s = h k <> " Ada " <> ts <> " " <> s <> "\n"
    ask repo "log main" `shouldReturn` BS.concat
      [ line "m" "3000" "merge", line "c2" "2000" "second", line "c3" "1500" "side", line "c1" "1000" "root" ]
    ask repo "log main 2" `shouldReturn` line "m" "3000" "merge" <> line "c2" "2000" "second"
    ask repo "log main 0" `shouldReturn` ""
    ask repo "log main 99" `shouldReturn` BS.concat [line "m" "3000" "merge", line "c2" "2000" "second", line "c3" "1500" "side", line "c1" "1000" "root"]
    ask repo "log v1" `shouldReturn` line "c2" "2000" "second" <> line "c1" "1000" "root"
    ask repo "log main x" `shouldReturn` "error\n"
    ask repo "log main -1" `shouldReturn` "error\n"
    ask repo "log main " `shouldReturn` "error\n"
    ask repo ("log " <> h "treeRoot") `shouldReturn` "error\n"
  it "lists trees, with paths and quoting" $ withFixture $ \fx repo -> do
    let h = hexOf fx
    ask repo "ls-tree c1" `shouldReturn` BS.concat
      [ "100644 blob ", h "hello", "\ta.txt\n"
      , "100644 blob ", h "hello", "\t\"caf\\303\\251.txt\"\n"
      , "040000 tree ", h "treeSub", "\tdir\n"
      , "100755 blob ", h "hello", "\trun\n" ]
    ask repo "ls-tree c1 dir" `shouldReturn` BS.concat ["100644 blob ", h "sub", "\tinner.txt\n"]
    ask repo "ls-tree main^{tree} dir" `shouldReturn` "error\n"
    ask repo "ls-tree c1 dir/inner.txt" `shouldReturn` "error\n"
    ask repo "ls-tree c1 a.txt" `shouldReturn` "error\n"
    forM_ ["", ".", "..", "dir/", "/dir", "dir//x", "dir/.", "nope"] $ \p ->
      ask repo ("ls-tree c1 " <> p) `shouldReturn` "error\n"
    ask repo ("ls-tree " <> h "hello") `shouldReturn` "error\n"
  it "cat-file verifies, reading loose, packed and delta objects" $ withFixture $ \fx repo -> do
    let h = hexOf fx
    ask repo ("cat-file " <> h "hello") `shouldReturn` "blob 6\nhello\n"
    ask repo ("cat-file " <> h "big3") `shouldReturn` "blob 502\n" <> BC.replicate 500 'q' <> "!?"
    ask repo ("cat-file " <> h "viaLoose") `shouldReturn` "blob 14\nhello\nappended"
    ask repo ("cat-file " <> h "tag") `shouldReturn` BS.concat ["tag 99\n", "object ", h "c2", "\ntype commit\ntag v1\ntagger Ada <a> 1 +0000\n\nrelease\n"]
    ask repo ("cat-file " <> h "good") `shouldReturn` "error\n"
    ask repo ("rev-parse " <> h "good" <> "^{object}") `shouldReturn` h "good" <> "\n"
    ask repo "cat-file" `shouldReturn` "error\n"
  it "diffs trees recursively, in path order, with A/D/M/T" $ withFixture $ \fx repo -> do
    let h = hexOf fx
        z = BC.replicate 40 '0'
    ask repo "diff c1 c2" `shouldReturn` BS.concat
      [ ":100644 100644 ", h "hello", " ", h "hello2", " M\ta.txt\n"
      , ":100644 000000 ", h "sub", " ", z, " D\tdir/inner.txt\n"
      , ":100755 120000 ", h "hello", " ", h "hello", " T\trun\n"
      , ":000000 100644 ", z, " ", h "sub", " A\tz\n" ]
    ask repo "diff c1 c1" `shouldReturn` ""
    ask repo "diff c2 c1" `shouldReturn` BS.concat
      [ ":100644 100644 ", h "hello2", " ", h "hello", " M\ta.txt\n"
      , ":000000 100644 ", z, " ", h "sub", " A\tdir/inner.txt\n"
      , ":120000 100755 ", h "hello", " ", h "hello", " T\trun\n"
      , ":100644 000000 ", h "sub", " ", z, " D\tz\n" ]
    ask repo "diff c1" `shouldReturn` "error\n"
    ask repo ("diff c1 " <> h "hello") `shouldReturn` "error\n"
  it "fails on unknown commands and wrong arities" $ withFixture $ \_ repo -> do
    ask repo "frobnicate" `shouldReturn` "error\n"
    ask repo "count-objects now" `shouldReturn` "error\n"
    ask repo "LOG main" `shouldReturn` "error\n"
  it "runs a batch into numbered files" $ withTempDir $ \d -> do
    _ <- mkFixture (d </> "in")
    BS.writeFile (d </> "in" </> "commands.txt") "count-objects\nrev-parse nope\nrev-parse HEAD"
    runBatch (d </> "in") (d </> "out")
    BS.readFile (d </> "out" </> "001.out") `shouldReturn` "loose: 12\nin-pack: 4\npacks: 1\n"
    BS.readFile (d </> "out" </> "002.out") `shouldReturn` "error\n"
    BS.length <$> BS.readFile (d </> "out" </> "003.out") `shouldReturn` 41
    doesFileExist (d </> "out" </> "004.out") `shouldReturn` False
  it "names output files and splits commands" $ do
    map outputName [1, 99, 1000] `shouldBe` ["001.out", "099.out", "1000.out"]
    splitCommands "a\nb\n" `shouldBe` ["a", "b"]
    splitCommands "a\nb" `shouldBe` ["a", "b"]
    splitCommands "" `shouldBe` []
  it "treats an empty repository as empty" $ withTempDir $ \d -> do
    createDirectoryIfMissing True (d </> "repo")
    repo <- openRepository (d </> "repo")
    ask repo "count-objects" `shouldReturn` "loose: 0\nin-pack: 0\npacks: 0\n"
    ask repo "rev-parse HEAD" `shouldReturn` "error\n"
  where
    toUpper' c = if c >= 'a' && c <= 'f' then toEnum (fromEnum c - 32) else c
