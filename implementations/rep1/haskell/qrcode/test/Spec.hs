module Main (main) where

import Data.Bits (shiftL, testBit, (.|.))
import qualified Data.ByteString as B
import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy.Char8 as BL
import Data.Either (isLeft)
import Test.Hspec
import Test.QuickCheck

import Codec.QRCode
import Codec.QRCode.Codewords
import Codec.QRCode.Matrix (formatBits, versionBits)
import Codec.QRCode.Query
import Codec.QRCode.ReedSolomon
import Codec.QRCode.Segment
import Codec.QRCode.Tables

-- | Encode and render the CLI block for one query line.
runLine :: String -> String
runLine = either error (BL.unpack . BB.toLazyByteString) . processLine . BC.pack

example1 :: [String]
example1 =
  [ "version 1 mask 0"
  , "#######...#.#.#######"
  , "#.....#.###...#.....#"
  , "#.###.#...#.#.#.###.#"
  , "#.###.#...#.#.#.###.#"
  , "#.###.#.#.###.#.###.#"
  , "#.....#..###..#.....#"
  , "#######.#.#.#.#######"
  , "....................."
  , "#.#.#.#..#..#...#..#."
  , ".####...#..#....#...#"
  , "...#######.#..#.##..."
  , "####.#.##..###.#.###."
  , ".#..####.#.#..###.#.#"
  , "........#.#...#...#.#"
  , "#######.....#..#.##.."
  , "#.....#..##...##.#..."
  , "#.###.#.##..#.#######"
  , "#.###.#...##.#.#...#."
  , "#.###.#.####.###.#..#"
  , "#.....#....###...#.##"
  , "#######.##.#.###....#"
  , ""
  ]

-- | Read the format information from the first copy around the top-left
-- finder and from the second copy; returns (bits1, bits2).
readFormat :: QRCode -> (Int, Int)
readFormat qr = (pack first, pack second)
  where
    n = qrSize qr
    d x y = moduleAt qr x y
    pack = foldr (\b acc -> (acc `shiftL` 1) .|. fromEnum b) 0
    first =
      [d 8 i | i <- [0 .. 5]] ++ [d 8 7, d 8 8, d 7 8] ++ [d (14 - i) 8 | i <- [9 .. 14]]
    second = [d (n - 1 - i) 8 | i <- [0 .. 7]] ++ [d 8 (n - 15 + i) | i <- [8 .. 14]]

example3 :: [String]
example3 =
  [ "version 1 mask 5"
  , "#######.####..#######"
  , "#.....#..##.#.#.....#"
  , "#.###.#.#.#...#.###.#"
  , "#.###.#..#....#.###.#"
  , "#.###.#.#.#...#.###.#"
  , "#.....#..##...#.....#"
  , "#######.#.#.#.#######"
  , "........#.#.........."
  , ".....##...#.#.#.#.#.#"
  , ".#####.......#..#.#.#"
  , ".####.#####..#..##.##"
  , ".##.##.#..#.#...#...."
  , "#..#.###.#....#..#.#."
  , "........#.####......#"
  , "#######..##..###.###."
  , "#.....#.#..##.##.##.."
  , "#.###.#.....##..#..#."
  , "#.###.#..##.##..##..."
  , "#.###.#.........#####"
  , "#.....#...#.#.#..##.."
  , "#######...#.#.#.#..#."
  , ""
  ]

genEcl :: Gen Ecl
genEcl = elements [L, M, Q, H]

genPayload :: Gen B.ByteString
genPayload = do
  kind <- elements [0, 1, 2 :: Int]
  len <- choose (1, 200)
  let alphabet = case kind of
        0 -> ['0' .. '9']
        1 -> ['0' .. '9'] ++ ['A' .. 'Z'] ++ " $%*+-./:"
        _ -> ['\x20' .. '\x7e'] ++ ['\xe9', '\x4e2d']
  BC.pack . map (\c -> if c > '\xff' then '?' else c) <$> vectorOf len (elements alphabet)

genMask :: Gen MaskChoice
genMask = oneof [pure AutoMask, FixedMask <$> choose (0, 7)]

main :: IO ()
main = hspec $ do
  describe "Tables" $ do
    it "data codewords at the extremes" $ do
      map (`dataCodewords` 1) [L, M, Q, H] `shouldBe` [19, 16, 13, 9]
      dataCodewords L 40 `shouldBe` 2956
      dataCodewords H 40 `shouldBe` 1276
    it "total codewords match the standard" $ do
      map totalCodewords [1, 2, 7, 40] `shouldBe` [26, 44, 196, 3706]
    it "byte capacity at version 40" $ do
      capacityBytes L `shouldBe` 2953
      capacityBytes H `shouldBe` 1273
    it "alignment positions" $ do
      alignmentPositions 1 `shouldBe` []
      alignmentPositions 7 `shouldBe` [6, 22, 38]
      alignmentPositions 40 `shouldBe` [6, 30, 58, 86, 114, 142, 170]

  describe "ReedSolomon" $ do
    it "powers of two" $ do
      map gfExp [0, 1, 8, 255] `shouldBe` [1, 2, 0x1D, 1]
    it "multiplication is commutative, associative and has identity 1" $
      property $ \a b c ->
        gfMul a b == gfMul b a
          && gfMul (gfMul a b) c == gfMul a (gfMul b c)
          && gfMul a 1 == a
    it "generator of degree 7" $
      generatorPoly 7 `shouldBe` [127, 122, 154, 164, 11, 68, 117]
    it "matches the HELLO WORLD example" $
      remainder 10 (generatorPoly 10) [32, 91, 11, 120, 209, 114, 220, 77, 67, 64, 236, 17, 236, 17, 236, 17]
        `shouldBe` [196, 35, 39, 119, 235, 215, 231, 226, 93, 23]

  describe "Segment" $ do
    it "selects modes" $ do
      selectMode (BC.pack "0123") `shouldBe` Numeric
      selectMode (BC.pack "HELLO WORLD $%*+-./:") `shouldBe` Alphanumeric
      selectMode (BC.pack "hello") `shouldBe` Byte
      selectMode (BC.pack "12a") `shouldBe` Byte
    it "closed-form bit lengths" $ do
      map (dataBitLength Numeric) [1, 2, 3, 4] `shouldBe` [4, 7, 10, 14]
      map (dataBitLength Alphanumeric) [1, 2, 3] `shouldBe` [6, 11, 17]
      dataBitLength Byte 5 `shouldBe` 40
    it "closed-form length equals the encoded fields' length" $
      property $ forAll genPayload $ \s ->
        let m = selectMode s
         in sum (map snd (segmentFields m 5 s)) === streamBitLength m 5 (B.length s)
    it "chooses the smallest version" $ do
      chooseVersion L Numeric 41 `shouldBe` Just 1
      chooseVersion L Numeric 42 `shouldBe` Just 2
      chooseVersion H Byte 1273 `shouldBe` Just 40
      chooseVersion H Byte 1274 `shouldBe` Nothing
    it "HELLO WORLD data codewords" $
      padDataCodewords M 1 (segmentFields Alphanumeric 1 (BC.pack "HELLO WORLD"))
        `shouldBe` [32, 91, 11, 120, 209, 114, 220, 77, 67, 64, 236, 17, 236, 17, 236, 17]

  describe "Codewords" $ do
    it "packs bits MSB first" $
      packBits [(1, 4), (0xFF, 8), (1, 1)] `shouldBe` [0x1F, 0xF8]
    it "final sequence has the version's total codeword count" $
      property $ forAll genEcl $ \ecl -> forAll (choose (1, 40)) $ \v ->
        length (buildCodewords ecl v (replicate (dataCodewords ecl v) 0))
          === totalCodewords v

  describe "format and version information" $ do
    it "known format words" $ do
      formatBits M 0 `shouldBe` 0x5412
      formatBits L 0 `shouldBe` 0x77C4
    it "known version words" $ do
      versionBits 7 `shouldBe` 0x07C94
      versionBits 40 `shouldBe` 0x28C69

  describe "encode" $ do
    it "renders example 1 exactly" $
      runLine "M 0 HELLO WORLD" `shouldBe` unlines example1
    it "penalties of HELLO WORLD for masks 0..7" $ do
      let scores = [penaltyScore qr | m <- [0 .. 7], Right qr <- [encode M (FixedMask m) (BC.pack "HELLO WORLD")]]
      scores `shouldBe` [311, 406, 442, 463, 367, 528, 395, 445]
    it "auto picks the lowest penalty (mask 0 for HELLO WORLD)" $
      fmap qrMask (encode M AutoMask (BC.pack "HELLO WORLD")) `shouldBe` Right 0
    it "numeric auto example (SPEC example 2)" $
      fmap (\q -> (qrVersion q, qrMask q)) (encode L AutoMask (BC.pack "01234567")) `shouldBe` Right (1, 3)
    it "UTF-8 bytes render exactly (SPEC example 3)" $
      runLine "H 5 h\195\169llo" `shouldBe` unlines example3
    it "reports data that is too long" $ do
      encode H AutoMask (BC.replicate 1274 'a') `shouldSatisfy` isLeft
      encode L AutoMask (BC.replicate 7090 '1') `shouldSatisfy` isLeft
    it "reports invalid masks" $
      encode L (FixedMask 8) (BC.pack "A") `shouldBe` Left (InvalidMask 8)
    it "fills version 40 at maximum capacity" $
      fmap qrVersion (encode L AutoMask (BC.replicate 7089 '9')) `shouldBe` Right 40
    it "encodeText encodes UTF-8" $
      fmap qrVersion (encodeText M AutoMask (read "\"h\\233llo\"")) `shouldBe` Right 1
    it "has the right size, finder patterns and format copies" $
      property $ forAll genEcl $ \ecl -> forAll genPayload $ \s -> forAll genMask $ \mc ->
        case encode ecl mc s of
          Left e -> counterexample (show e) False
          Right qr ->
            let n = qrSize qr
                (f1, f2) = readFormat qr
                fb = formatBits ecl (qrMask qr)
                finder ox oy =
                  and [moduleAt qr (ox + 3) (oy + 3), not (moduleAt qr (ox + 1) (oy + 1)), moduleAt qr ox oy]
             in conjoin
                  [ n === 4 * qrVersion qr + 17
                  , counterexample "finders" (finder 0 0 && finder (n - 7) 0 && finder 0 (n - 7))
                  , counterexample "format" (f1 == fb && f2 == fb)
                  , counterexample "dark module" (moduleAt qr 8 (n - 8))
                  , counterexample "version info"
                      (qrVersion qr < 7 || and [moduleAt qr (n - 11 + i `mod` 3) (i `div` 3) == testBit (versionBits (qrVersion qr)) i | i <- [0 .. 17]])
                  , case mc of
                      FixedMask k -> qrMask qr === k
                      AutoMask -> property True
                  ]
    it "auto never does worse than any fixed mask" $
      property $ forAll genEcl $ \ecl -> forAll genPayload $ \s ->
        let Right a = encode ecl AutoMask s
            fixed = [penaltyScore q | k <- [0 .. 7], Right q <- [encode ecl (FixedMask k) s]]
         in penaltyScore a === minimum fixed

  describe "Query" $ do
    it "parses lines" $ do
      parseQuery (BC.pack "Q auto hello world") `shouldBe` Right (Query Q AutoMask (BC.pack "hello world"))
      parseQuery (BC.pack "L 7 x") `shouldBe` Right (Query L (FixedMask 7) (BC.pack "x"))
    it "rejects malformed lines" $ do
      parseQuery (BC.pack "X 0 a") `shouldSatisfy` isLeft
      parseQuery (BC.pack "L 9 a") `shouldSatisfy` isLeft
      parseQuery (BC.pack "L 0") `shouldSatisfy` isLeft
    it "emits one block per line, final newline optional" $ do
      let out s = length (processInput (BC.pack s))
      out "L 0 A\nM auto 12" `shouldBe` 2
      out "L 0 A\nM auto 12\n" `shouldBe` 2
