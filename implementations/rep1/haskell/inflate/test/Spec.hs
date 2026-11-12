module Main (main) where

import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import Test.Hspec
import Test.QuickCheck

import Codec.Compression.Inflate
import Codec.Compression.Inflate.Hex (decodeHex, encodeHex)
import Encoder

-- | Inflate a hex-encoded stream and hex-encode the result.
run :: String -> Either InflateError String
run h = case decodeHex (BC.pack h) of
  Nothing -> error "bad hex in test"
  Just raw -> BC.unpack . encodeHex <$> inflate raw

ok :: String -> String -> Expectation
ok input expected = run input `shouldBe` Right expected

bad :: String -> InflateError -> Expectation
bad input err = run input `shouldBe` Left err

main :: IO ()
main = hspec $ do
  describe "Hex" $ do
    it "round-trips every byte" $
      decodeHex (encodeHex (B.pack [0 .. 255])) `shouldBe` Just (B.pack [0 .. 255])
    it "encodes lowercase" $ encodeHex (B.pack [0xab, 0x01]) `shouldBe` BC.pack "ab01"
    it "accepts upper case" $ decodeHex (BC.pack "AB") `shouldBe` Just (B.pack [0xab])
    it "rejects odd length and non-hex" $ do
      decodeHex (BC.pack "abc") `shouldBe` Nothing
      decodeHex (BC.pack "zz") `shouldBe` Nothing

  describe "valid streams" $ do
    it "fixed block with only end-of-block" $ ok "0300" ""
    it "stored block" $ ok "010100feff41" "41"
    it "fixed block with a back-reference" $ ok "4b4c4a862000" "616263616263616263"
    it "dynamic block without distance codes" $
      ok "05c0c8090010b7db3501a349ca0785fdd3da79d6d746bf79f4d3cb07" "6e6f206d617463686573206865726521"
    it "dynamic block with a single distance code" $
      ok "4dc2310d0000008330ad807f0f7b97147b03" "616263616263616263616263616263"
    it "dynamic block holding only end-of-block" $ ok "05c0810800000000207feb03" ""
    it "code-length repeat 16 across the literal/distance boundary" $
      ok "25470501000000f93f5a6b4005e51423d136" "fdfefffffffffffffffffffffffffffffffffdffffffffffffff"
    it "code-length repeats 17 and 18" $
      ok "05c0310d000000c2b0fa9f5e7ea2d101" "008bf500008b"
    it "repeat 16 after a zero run" $
      ok "0580b509000000801c42ffbf5830ac01" "00070800070808"
    it "ignores nonzero padding after the final block" $ ok "03f8" ""

  describe "malformed streams" $ do
    it "empty stream" $ bad "" UnexpectedEnd
    it "no final block" $ bad "0100" UnexpectedEnd
    it "block type 3" $ bad "07" InvalidBlockType
    it "stored length mismatch" $ bad "010100fdff41" StoredLengthMismatch
    it "truncated stored data" $ bad "010500faff4142" UnexpectedEnd
    it "trailing byte" $ bad "030000" TrailingData
    it "distance before any output" $ bad "030200" DistanceTooFar
    it "distance too far" $ bad "4b044200" DistanceTooFar
    it "code-length code over-subscribed" $
      bad "05c0030400000000100000000000000000000000000000000000000000000000000000000000000000010000" InvalidCodeLengthCode
    it "repeat 16 with no previous length" $ bad "05c0050900000000a0f0ff6741" RepeatWithoutPrevious
    it "repeat overflowing the lengths" $ bad "05c081000000000090ff7f0000" RepeatOverflow
    it "missing end-of-block code" $
      bad "05c0010400000000100000000000000000000000000300000000000000000000000000000000000000000000" MissingEndOfBlock
    it "incomplete distance code" $
      bad "0dc1010400000080200000000000000000000000000100000000000000000000000000000000000000df58" InvalidDistanceCode
    it "length code without distance codes" $ bad "0dc0810c0000008030d6fb4bd470" NoDistanceCodes
    it "wrong bit for a single distance code" $ bad "0dc081000000008020d6fc253e3c" InvalidHuffmanCode
    it "wrong bit for a single literal/length code" $ bad "05c0810800000000207feb0b" InvalidHuffmanCode
    it "never consumes bits past the end" $
      mapM_ (\n -> run (take n "4b4c4a862000") `shouldNotBe` Right "616263616263616263") [0, 2 .. 10]

  describe "properties" $ do
    it "stored blocks decode to their payload" $ property $ \ws ->
      let payload = B.pack (take 60000 ws)
      in inflate (storedBlock True payload) === Right payload
    it "fixed-Huffman token streams decode to the expanded tokens" $
      forAll (genTokens 300) $ \toks ->
        inflate (bitsToBytes (fixedBlock True toks)) === Right (expand toks)
    it "multiple fixed blocks share one history" $
      forAll (genTokens 100) $ \a -> forAll (genTokensAfter (B.length (expand a)) 100) $ \b ->
        let stream = bitsToBytes (fixedBlock False a ++ fixedBlock True b)
        in inflate stream === Right (expand (a ++ b))
    it "any extra byte after a valid stream is rejected" $
      forAll (genTokens 50) $ \toks -> \extra ->
        inflate (bitsToBytes (fixedBlock True toks) `B.snoc` extra) === Left TrailingData
    it "truncating a valid stream never succeeds" $
      forAll (genTokens 50) $ \toks ->
        let s = bitsToBytes (fixedBlock True toks)
        in B.length s > 1 ==> inflate (B.init s) =/= Right (expand toks)

-- | Random tokens that only reference bytes that already exist.
genTokens :: Int -> Gen [Token]
genTokens = genTokensAfter 0

genTokensAfter :: Int -> Int -> Gen [Token]
genTokensAfter start size = do
  n <- choose (0, size)
  go n start
  where
    go 0 _ = return []
    go k have = do
      useMatch <- if have == 0 then return False else frequency [(1, return True), (2, return False)]
      if useMatch
        then do
          d <- frequency [(3, choose (1, min have 8)), (1, choose (1, min have 32768))]
          l <- frequency [(3, choose (3, 20)), (1, choose (3, 258))]
          (Match l d :) <$> go (k - 1 :: Int) (have + l)
        else do
          b <- arbitrary
          (Lit b :) <$> go (k - 1) (have + 1)
