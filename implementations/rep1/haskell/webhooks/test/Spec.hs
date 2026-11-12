{-# OPTIONS_GHC -Wno-incomplete-uni-patterns #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Builder as B
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy as BL
import Test.Hspec
import Test.QuickCheck hiding (Failure, Success)
import qualified Webhooks.Heap as Heap
import Webhooks

bytes :: Gen ByteString
bytes = BS.pack <$> listOf arbitrary

hex :: ByteString -> ByteString
hex = encodeHex

run :: [ByteString] -> [ByteString]
run ls = BC.lines (BL.toStrict (B.toLazyByteString (processInput (BC.unlines ls))))

secretText :: ByteString
secretText = "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw"

vectorId, vectorTs, vectorBody :: ByteString
vectorId = "msg_p5jXN8AQM9LWM0D4loKWxJek"
vectorTs = "1614265330"
vectorBody = "{\"test\": 2432232314}"

vectorSig :: ByteString
vectorSig = "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE="

main :: IO ()
main = hspec $ do
  describe "SHA256" $ do
    it "hashes the empty string" $
      hex (sha256 "") `shouldBe` "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    it "hashes abc" $
      hex (sha256 "abc") `shouldBe` "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    it "hashes the two-block NIST message" $
      hex (sha256 "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")
        `shouldBe` "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
    it "hashes a million a's" $
      hex (sha256 (BS.replicate 1000000 97))
        `shouldBe` "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
    it "handles every length around the padding boundaries" $
      mapM_ (\n -> BS.length (sha256 (BS.replicate n 0)) `shouldBe` 32) [0 .. 200]
    it "is 55/56/64-byte boundary correct" $ do
      hex (sha256 (BS.replicate 55 97)) `shouldBe` "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318"
      hex (sha256 (BS.replicate 56 97)) `shouldBe` "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a"
      hex (sha256 (BS.replicate 64 97)) `shouldBe` "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb"

  describe "HMAC" $ do
    it "matches RFC 4231 test case 1" $
      hex (hmacSha256 (BS.replicate 20 0x0b) "Hi There")
        `shouldBe` "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"
    it "matches RFC 4231 test case 2" $
      hex (hmacSha256 "Jefe" "what do ya want for nothing?")
        `shouldBe` "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
    it "hashes over-long keys first (RFC 4231 test case 6)" $
      hex (hmacSha256 (BS.replicate 131 0xaa) "Test Using Larger Than Block-Size Key - Hash Key First")
        `shouldBe` "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54"
    it "accepts the empty key and message" $
      hex (hmacSha256 "" "") `shouldBe` "b613679a0814d9ec772f95d778c35fc5ff1697c493715653c6c712144292c5ad"
    it "constantTimeEq agrees with (==)" $
      property $ \a b -> constantTimeEq (BS.pack a) (BS.pack b) == (a == b)

  describe "Base64" $ do
    it "encodes the RFC 4648 vectors" $
      map encodeStandard ["", "f", "fo", "foo", "foob", "fooba", "foobar"]
        `shouldBe` ["", "Zg==", "Zm8=", "Zm9v", "Zm9vYg==", "Zm9vYmE=", "Zm9vYmFy"]
    it "uses the URL-safe alphabet without padding" $ do
      encodeUrlSafe (BS.pack [0xfb, 0xff]) `shouldBe` "-_8"
      encodeStandard (BS.pack [0xfb, 0xff]) `shouldBe` "+/8="
    it "ignores unchecked trailing bits" $ do
      decode "QQ==" `shouldBe` Just "A"
      decode "QR==" `shouldBe` Just "A"
    it "accepts either alphabet, padded or not" $ do
      decode "-_8" `shouldBe` Just (BS.pack [0xfb, 0xff])
      decode "+/8=" `shouldBe` Just (BS.pack [0xfb, 0xff])
      decode "" `shouldBe` Just ""
    it "rejects malformed input" $
      mapM_
        (\s -> (s, decode s) `shouldBe` (s, Nothing))
        ["Q", "QQ=", "QQ=A", "Zm9v=", "Zm9v====", "=", "+-", "a b=", "Zm9v\n", "QUJD=", "QQ===", "Zm8==", "é"]
    it "round-trips both encodings" $
      property $ forAll bytes $ \b ->
        decode (encodeStandard b) == Just b && decode (encodeUrlSafe b) == Just b
    it "pads standard output to a multiple of four" $
      property $ forAll bytes $ \b -> BS.length (encodeStandard b) `mod` 4 == 0

  describe "Hex" $ do
    it "round-trips" $ property $ forAll bytes $ \b -> decodeHex (encodeHex b) == Just b
    it "rejects uppercase and odd lengths" $ do
      decodeHex "AB" `shouldBe` Nothing
      decodeHex "abc" `shouldBe` Nothing
    it "uses - for the empty field and refuses empty text" $ do
      parseHexField "-" `shouldBe` Just ""
      parseHexField "" `shouldBe` Nothing
      renderHexField "" `shouldBe` "-"

  describe "Secret" $ do
    it "strips whsec_ once" $ do
      fmap hex (parseSecret secretText) `shouldBe` Just "31f290f6bf06298aab4f08d43c3f082cf648a362da2da4b0"
      parseSecret "MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw" `shouldBe` parseSecret secretText
    it "accepts optional padding" $
      fmap BS.length (parseSecret (secretText <> "Br")) `shouldBe` Just 25
    it "rejects invalid, empty and over-long secrets" $ do
      parseSecret "whsec_" `shouldBe` Nothing
      parseSecret "!!!" `shouldBe` Nothing
      parseSecret (BC.replicate 513 'A') `shouldBe` Nothing
    it "limits lists to 16 entries" $ do
      fmap length (parseSecrets (BS.intercalate "," (replicate 16 "c2VjcmV0"))) `shouldBe` Just 16
      parseSecrets (BS.intercalate "," (replicate 17 "c2VjcmV0")) `shouldBe` Nothing
      parseSecrets "c2VjcmV0," `shouldBe` Nothing
      parseSecrets "" `shouldBe` Nothing

  describe "Signature" $ do
    let Just keys = parseSecrets secretText
    it "reproduces the published Standard Webhooks vector" $
      signatureHeader keys vectorId vectorTs vectorBody `shouldBe` vectorSig
    it "emits one signature per secret, space separated" $ do
      let Just two = parseSecrets "c2VjcmV0,b3RoZXI"
      length (BC.words (signatureHeader two "i" "1" "")) `shouldBe` 2
    it "verifies the vector" $
      verify keys vectorId vectorTs vectorSig vectorBody 1614265400 `shouldBe` Right (0, 0)
    it "enforces the inclusive tolerance" $ do
      verify keys vectorId vectorTs vectorSig vectorBody 1614265630 `shouldBe` Right (0, 0)
      verify keys vectorId vectorTs vectorSig vectorBody 1614265631 `shouldBe` Left TimestampTooOld
      verify keys vectorId vectorTs vectorSig vectorBody 1614265030 `shouldBe` Right (0, 0)
      verify keys vectorId vectorTs vectorSig vectorBody 1614265029 `shouldBe` Left TimestampTooNew
    it "reports missing signatures before bad timestamps" $
      verify keys vectorId "bad" "" vectorBody 0 `shouldBe` Left MissingSignature
    it "rejects non-canonical timestamps" $
      mapM_
        (\t -> verify keys vectorId t vectorSig vectorBody 0 `shouldBe` Left InvalidTimestamp)
        ["007", "+5", "-0", "1e3", "1000000000000001", "x"]
    it "skips garbage tokens and counts empty ones" $
      verify keys vectorId vectorTs ("garbage  " <> vectorSig) vectorBody 1614265400
        `shouldBe` Right (0, 2)
    it "rejects other versions and a changed body" $ do
      verify keys vectorId vectorTs ("v2" <> BS.drop 2 vectorSig) vectorBody 1614265400 `shouldBe` Left NoMatch
      verify keys vectorId vectorTs vectorSig "{}" 1614265400 `shouldBe` Left NoMatch
    it "prefers the earliest secret, then the earliest token" $ do
      let Just two = parseSecrets "c2VjcmV0,b3RoZXI"
          hdr = signatureHeader two "i" "100" "b"
          [s0, s1] = BC.words hdr
      verify two "i" "100" (BS.intercalate " " [s1, s0]) "b" 100 `shouldBe` Right (0, 1)
    it "round-trips sign/verify" $
      property $ forAll bytes $ \b ->
        verify keys "id" "5" (signatureHeader keys "id" "5" b) b 5 == Right (0, 0)

  describe "Heap" $
    it "pops in ascending order" $
      property $ \xs -> Heap.toAscList (Heap.fromList (xs :: [Int])) == foldr insertSorted [] xs
    
  describe "Simulator" $ do
    let Just k = parseSecrets "c2VjcmV0"
        ep name script = Endpoint name k AllEvents script
        ev name t = Event name t "t" "7b7d"
    it "follows the retry schedule" $ do
      let r = simulate [ep "a" [Status 500]] [ev "e" 1000]
      map attemptTime (resultAttempts r)
        `shouldBe` [1000, 1005, 1305, 3105, 10305, 28305, 64305, 100305]
      map deliveryStatus (resultDeliveries r) `shouldBe` [Failed]
    it "repeats the last script entry" $ do
      let r = simulate [ep "a" [Status 500, Timeout, Status 200]] [ev "e" 0]
      map attemptOutcome (resultAttempts r) `shouldBe` [Failure, TimedOut, Success]
    it "disables an endpoint on 410 and abandons later deliveries" $ do
      let r = simulate [ep "a" [Status 410]] [ev "e1" 0, ev "e2" 10]
      length (resultAttempts r) `shouldBe` 1
      map deliveryStatus (resultDeliveries r) `shouldBe` [Failed, Disabled]
      map deliveryLastTime (resultDeliveries r) `shouldBe` [Just 0, Nothing]
    it "orders by time even when events are declared out of order" $ do
      let r = simulate [ep "a" [Status 200]] [ev "late" 50, ev "early" 5]
      map attemptEvent (resultAttempts r) `shouldBe` ["early", "late"]
    it "only delivers matching types" $ do
      let e = (ep "a" [Status 200]) {endpointFilter = Types ["x"]}
      length (resultDeliveries (simulate [e] [ev "e" 0])) `shouldBe` 0
    it "never makes more than eight attempts" $
      property $ forAll (listOf1 (elements [Status 500, Status 200, Timeout, Status 410])) $ \script ->
        let r = simulate [ep "a" script] [ev "e1" 0, ev "e2" 3]
         in all ((<= 8) . deliveryAttempts) (resultDeliveries r)

  describe "Simulator.Block" $ do
    it "reads a valid block and stops after end" $
      readBlock ["endpoint a c2VjcmV0 * 200", "", "event e 0 t -", "end", "next"]
        `shouldSatisfy` (\(b, rest) -> fmap (\(es, vs) -> (length es, length vs)) b == Just (1, 1) && rest == ["next"])
    it "rejects a block without endpoints, or without end" $ do
      fst (readBlock ["end"]) `shouldBe` Nothing
      fst (readBlock ["endpoint a c2VjcmV0 * 200"]) `shouldBe` Nothing
    it "keeps consuming to end after an error" $
      snd (readBlock ["bogus", "endpoint a c2VjcmV0 * 200", "end", "sha256 -"]) `shouldBe` ["sha256 -"]
    it "rejects endpoints after events and duplicate ids" $ do
      fst (readBlock ["endpoint a c2VjcmV0 * 200", "event e 0 t -", "endpoint b c2VjcmV0 * 200", "end"])
        `shouldBe` Nothing
      fst (readBlock ["endpoint a c2VjcmV0 * 200", "endpoint a c2VjcmV0 * 200", "end"]) `shouldBe` Nothing

  describe "Command" $ do
    it "answers the primitive commands" $
      run ["sha256 -", "hmac - -", "b64enc 666f6f", "b64urlenc fbff", "b64dec 5a6d3976", "b64dec -", "b64enc -"]
        `shouldBe` [ "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
                   , "b613679a0814d9ec772f95d778c35fc5ff1697c493715653c6c712144292c5ad"
                   , "Zm9v", "-_8", "666f6f", "-", "-" ]
    it "signs and verifies the vector" $ do
      let p = hex vectorBody
          h = hex vectorSig
      run [ "sign " <> secretText <> " " <> vectorId <> " " <> vectorTs <> " " <> p
          , "verify " <> secretText <> " " <> vectorId <> " " <> vectorTs <> " 1614265400 " <> h <> " " <> p
          , "verify " <> secretText <> " " <> vectorId <> " " <> vectorTs <> " 1614265631 " <> h <> " " <> p
          , "verify " <> secretText <> " " <> vectorId <> " " <> vectorTs <> " 1614265400 - " <> p
          ]
        `shouldBe` [vectorSig, "ok 0 0", "fail timestamp-too-old", "fail missing-signature"]
    it "prints error for malformed lines and keeps going" $
      run ["sha256 ABCD", "sha256 abc", "frobnicate 1", "sha256  -", " sha256 -", "sha256 - ", "", "   ", "secret !!!"]
        `shouldBe` replicate 6 "error" ++ ["error"]
    it "runs the worked simulation example" $
      run [ "simulate"
          , "endpoint ep_a whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw * 500,timeout,200"
          , "endpoint ep_b whsec_c2VjcmV0,whsec_b3RoZXI user.created 200"
          , "event msg_1 1700000000 user.created 7b7d"
          , "event msg_2 1700000100 repo.pushed 7b7d"
          , "end" ]
        `shouldBe` [ "sim 5 3"
                   , "attempt 1 msg_1 ep_a 1 1700000000 failure 500"
                   , "attempt 2 msg_1 ep_b 1 1700000000 success 200"
                   , "attempt 3 msg_1 ep_a 2 1700000005 timeout -"
                   , "attempt 4 msg_2 ep_a 1 1700000100 success 200"
                   , "attempt 5 msg_1 ep_a 3 1700000305 success 200"
                   , "delivery msg_1 ep_a delivered 3 1700000305 v1,x5lVgj0b/JJJaUYaa1+6I5J/EECcryrPlFN4VrkmI94="
                   , "delivery msg_1 ep_b delivered 1 1700000000 v1,A5oIrJxXPB/PkULSoVu0e4khvPiqpF9vljmhkSKg0FI= v1,+y5T5nCYgPC5Y9oXnau3uEIax3TN0x8LoF05LBfU83s="
                   , "delivery msg_2 ep_a delivered 1 1700000100 v1,Cu35wCUZTS4YnAIA1waQmIXPFLh46qYAWpcHufrxa9U=" ]
    it "treats 'simulate now' as a plain error and does not open a block" $
      run ["simulate now", "end", "sha256 -"]
        `shouldBe` ["error", "error", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"]
    it "reports a bad block as one error and resumes" $
      run ["simulate", "bogus", "end", "sha256 -"]
        `shouldBe` ["error", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"]
    it "never throws on arbitrary lines" $
      property $ \ls -> length (run (map (BS.filter (/= 10) . BS.pack) ls)) >= 0

insertSorted :: Int -> [Int] -> [Int]
insertSorted x [] = [x]
insertSorted x (y : ys)
  | x <= y = x : y : ys
  | otherwise = y : insertSorted x ys
