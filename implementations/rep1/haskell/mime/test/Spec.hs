module Main (main) where

import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.Char (ord)
import Data.Word (Word8)
import System.Directory (createDirectoryIfMissing, getTemporaryDirectory, removeDirectoryRecursive)
import System.FilePath ((</>))
import Test.Hspec
import Test.QuickCheck hiding ((.&.))

import Mime
import Mime.Bytes
import Mime.Charset
import Mime.Date
import Mime.Header (fieldValue)
import Mime.Params
import Mime.Part (isLeaf)
import Mime.Render (esc)
import Mime.Transfer

bs :: String -> B.ByteString
bs = BC.pack

addr :: String -> [(String, String)]
addr v = [(addrDisplay a, addrSpec a) | a <- parseAddressList v]

-- | A tiny base64 encoder used only to check the decoder.
b64Encode :: [Word8] -> String
b64Encode [] = []
b64Encode xs = case splitAt 3 xs of
  (g, r) ->
    let [a, b, c] = map fromIntegral (g ++ replicate (3 - length g) 0) :: [Int]
        n = (a `shiftL` 16) .|. (b `shiftL` 8) .|. c
        ch i = alphabet !! ((n `shiftR` i) .&. 63)
        out = [ch 18, ch 12, ch 6, ch 0]
     in take (length g + 1) out ++ replicate (3 - length g) '=' ++ b64Encode r
  where
    alphabet = ['A' .. 'Z'] ++ ['a' .. 'z'] ++ ['0' .. '9'] ++ "+/"

worked :: B.ByteString
worked = bs $ concat
  [ "Subject: =?utf-8?Q?Caf=C3=A9?= report\n"
  , "From: Ann Example <ann@example.com>\n"
  , "To: bob@example.org, Carl <carl@example.org>\n"
  , "Date: Mon, 1 Sep 2025 12:30:00 +0200\n"
  , "MIME-Version: 1.0\n"
  , "Content-Type: multipart/mixed; boundary=\"X\"\n"
  , "\n"
  , "ignore me\n"
  , "--X\n"
  , "Content-Type: text/plain; charset=iso-8859-1\n"
  , "\n"
  , "caf\xE9\n"
  , "--X\n"
  , "Content-Type: application/octet-stream\n"
  , "Content-Disposition: attachment; filename=\"a.bin\"\n"
  , "Content-Transfer-Encoding: base64\n"
  , "\n"
  , "AAECAw==\n"
  , "--X--\n"
  ]

main :: IO ()
main = hspec $ do
  describe "Mime.Charset" $ do
    it "decodes cp1252 specials" $ decode "windows-1252" (B.pack [0x92]) `shouldBe` "\8217"
    it "falls back to cp1252 for unknown names" $ decode "" (B.pack [0x80]) `shouldBe` "\8364"
    it "decodes ASCII high bytes as U+FFFD" $ decode "ascii" (B.pack [0x41, 0xE9]) `shouldBe` "A\xFFFD"
    it "applies the maximal subpart rule" $ do
      decodeUtf8 (B.pack [0xE2, 0x28, 0xA1]) `shouldBe` "\xFFFD(\xFFFD"
      decodeUtf8 (B.pack [0xF0, 0x9F]) `shouldBe` "\xFFFD"
      decodeUtf8 (B.pack [0xED, 0xA0, 0x80]) `shouldBe` "\xFFFD\xFFFD\xFFFD"
    it "round-trips valid text" $ property $ \s ->
      let t = filter (\c -> ord c < 0xD800 || ord c > 0xDFFF) s
       in decodeUtf8 (encodeUtf8 t) === t

  describe "Mime.Transfer" $ do
    it "decodes quoted-printable" $ do
      decodeQuotedPrintable (bs "a=20b") `shouldBe` bs "a b"
      decodeQuotedPrintable (bs "a=\nb") `shouldBe` bs "ab"
      decodeQuotedPrintable (bs "a=3Db") `shouldBe` bs "a=b"
      decodeQuotedPrintable (bs "a=Zb") `shouldBe` bs "a=Zb"
      decodeQuotedPrintable (bs "a=3\n") `shouldBe` bs "a=3\n"
      decodeQuotedPrintable (bs "abc=") `shouldBe` bs "abc"
      decodeQuotedPrintable (bs "=0D=0A") `shouldBe` bs "\r\n"
    it "decodes base64, ignoring junk and a dangling character" $ do
      decodeBase64 (bs "AAECAw==") `shouldBe` B.pack [0, 1, 2, 3]
      decodeBase64 (bs "AA\nEC Aw") `shouldBe` B.pack [0, 1, 2, 3]
      decodeBase64 (bs "QUJDR") `shouldBe` bs "ABC"
    it "round-trips base64" $ property $ \ws ->
      decodeBase64 (bs (b64Encode ws)) === B.pack ws
    it "leaves unknown encodings alone" $ decodeBody "x-foo" (bs "a=20") `shouldBe` bs "a=20"

  describe "Mime.Bytes" $ do
    it "computes Adler-32" $ do
      adler32Hex B.empty `shouldBe` "00000001"
      adler32Hex (B.pack [0x63, 0x61, 0x66, 0xE9]) `shouldBe` "04680214"
    it "normalises CRLF only" $ normalizeNewlines (bs "a\r\nb\rc\n") `shouldBe` bs "a\nb\rc\n"

  describe "RFC 2047" $ do
    let cases =
          [ ("=?utf-8?Q?caf=C3=A9?=", "café")
          , ("=?utf-8?Q?a?=   =?utf-8?Q?b?=", "ab")
          , ("x =?utf-8?Q?a?= y", "x a y")
          , ("=?utf-8?Q?a?=b", "ab")
          , ("=?iso-8859-1?Q?caf=E9?=", "café")
          , ("=?windows-1252?Q?smart=92quote?=", "smart’quote")
          , ("=?utf-8?B?SsO2cmc=?=", "Jörg")
          , ("=?utf-8*en?Q?hi?=", "hi")
          , ("=?utf-8?X?hi?=", "=?utf-8?X?hi?=")
          , ("  plain    spaced   text  ", "plain    spaced   text")
          , ("=?utf-8?Q?a?= \t =?utf-8?Q?b?= \t c", "ab \t c")
          ]
    mapM_ (\(i, o) -> it (show i) $ decodeUnstructured i `shouldBe` o) cases

  describe "Mime.Params" $ do
    let fn v = paramLookup "filename" (parseStructured ("attachment; " ++ v))
    it "handles plain, quoted and unquoted values" $ do
      fn "filename=\"report.pdf\"" `shouldBe` Just "report.pdf"
      fn "filename=two words.bin" `shouldBe` Just "two words.bin"
      fn "filename=\"a\\\\\"; x=1" `shouldBe` Just "a\\"
    it "handles RFC 2231" $ do
      fn "filename*=utf-8''a%C3%A9.txt" `shouldBe` Just "aé.txt"
      fn "filename*0=\"long\"; filename*1=\"name.txt\"" `shouldBe` Just "longname.txt"
      fn "filename*0*=utf-8''a%C3%A9; filename*1=\".txt\"" `shouldBe` Just "aé.txt"
      fn "filename=\"=?utf-8?Q?a=C3=A9.txt?=\"" `shouldBe` Just "aé.txt"
      fn "filename*=''caf%E9.txt" `shouldBe` Just "caf\xFFFD.txt"
      fn "filename*0=a; filename*2=c; filename*10=j" `shouldBe` Just "acj"

  describe "Mime.Address" $ do
    it "parses the specification examples" $ do
      addr "Real Name <user@example.com>" `shouldBe` [("Real Name", "user@example.com")]
      addr "user@example.com (Real Name)" `shouldBe` [("", "user@example.com")]
      addr "\"Doe, John\" <jd@x.com>" `shouldBe` [("Doe, John", "jd@x.com")]
      addr "a@b.com, (c) d@e.com" `shouldBe` [("", "a@b.com"), ("", "d@e.com")]
      addr "Undisclosed recipients:;" `shouldBe` []
      addr "grp: a@b.com, c@d.com;" `shouldBe` [("", "a@b.com"), ("", "c@d.com")]
      addr "=?utf-8?B?SsO2cmc=?= <j@x.de>" `shouldBe` [("Jörg", "j@x.de")]
      addr "foo (c (nested)) <a@b>" `shouldBe` [("foo", "a@b")]
      addr "ed <a@[10.0.0.1]>" `shouldBe` [("ed", "a@[10.0.0.1]")]
      addr "broken <a@@b>" `shouldBe` [("", "broken<a@@b>")]
      addr "Symantec Email Proxy" `shouldBe` [("", "SymantecEmailProxy")]
      addr "\"=?utf-8?Q?x?=\" <a@b>" `shouldBe` [("=?utf-8?Q?x?=", "a@b")]
      addr "a <b <c@d.com> , e@f.com>, g@h.com"
        `shouldBe` [("", "a<b<c@d.com>,e@f.com>"), ("", "g@h.com")]
      addr "John (the third) Public <jqp@x.com>" `shouldBe` [("John   Public", "jqp@x.com")]

  describe "Mime.Date" $ do
    let epochOf = fmap dateEpoch . parseDate
    it "parses the specification examples" $ do
      epochOf "Sun, 29 Feb 2004 22:03:22 -0800" `shouldBe` Just 1078121002
      epochOf "3 Jan 70 00:00:00 GMT" `shouldBe` Just 172800
      epochOf "Tue, 1 Jan 2036 00:00:60 +0000" `shouldBe` Just 2082758460
      epochOf "Mon, 3 Mar 1969 12:00 (GMT) -0500" `shouldBe` Just (-26204400)
      epochOf "1 Jan 2000 00:00:00 +2359" `shouldBe` Just 946598460
      epochOf "not a date" `shouldBe` Nothing
      epochOf "30 Feb 2001 00:00 +0000" `shouldBe` Nothing
    it "formats" $ do
      formatUtc (-26204400) `shouldBe` "1969-03-03T17:00:00Z"
      formatOffset 6039 `shouldBe` "+10039"
      formatOffset 0 `shouldBe` "+0000"
    it "round-trips civil dates" $ property $ \(Positive d) ->
      let n = toInteger (d `mod` 3000000 :: Int) - 1000000
          (y, m, dd) = civilFromDays n
       in daysFromCivil (fromInteger y) m dd === n

  describe "Mime.Render" $
    it "escapes" $ esc "a\\b\n\"\x01\x7f\x85é" `shouldBe` "a\\\\b\\n\\\"\\x01\\x7f\\x85é"

  describe "mailboxes" $ do
    it "splits mbox files on From lines after blank lines" $
      splitMbox (bs "junk\n\nFrom a\nx\n\nFrom b\ny\nFrom c\n\n\nFrom d\nz\n")
        `shouldBe` [bs "x\n", bs "y\nFrom c\n\n", bs "z\n"]
    it "has no messages without a separator" $ splitMbox (bs "hello\n") `shouldBe` []

  describe "messages" $ do
    it "stops the header block at a non-field line" $ do
      let m = parseMessage (bs "Subject: x\nFrom nobody Mon\nbody\n")
      map fieldValue (msgHeaders m) `shouldBe` ["x"]
    it "parses the worked example" $ do
      let m = parseMessage worked
      msgSize m `shouldBe` 427
      map partIndex (messageParts m) `shouldBe` [0, 1, 2]
      fmap partIndex (msgTextBody m) `shouldBe` Just 1
      map partIndex (msgAttachments m) `shouldBe` [2]
      case partBody (msgRoot m) of
        Multipart b pre epi kids -> do
          b `shouldBe` "X"
          pre `shouldBe` 9
          epi `shouldBe` Just 0
          length kids `shouldBe` 2
        _ -> expectationFailure "expected a multipart"
    it "treats digest children as message/rfc822 by default" $ do
      let m = parseMessage (bs "Content-Type: multipart/digest; boundary=b\n\n--b\n\nSubject: s\n\nhi\n--b--\n")
      map partType (messageParts m) `shouldBe` ["multipart", "message", "text"]
      all (not . isLeaf) (take 2 (messageParts m)) `shouldBe` True
    it "dumps to disk" $ do
      tmp <- getTemporaryDirectory
      let out = tmp </> "mime-parser-spec-out"
      createDirectoryIfMissing True out
      dumpSources out [Source "mbox:1" worked]
      summary <- readFile (out </> "summary.txt")
      summary `shouldBe`
        "messages 1\n0001 source=\"mbox:1\" bytes=427 parts=3 attachments=1 text=1 html=-\n"
      att <- B.readFile (out </> "parts" </> "0001" </> "002.bin")
      att `shouldBe` B.pack [0, 1, 2, 3]
      dump <- readFile (out </> "messages" </> "0001.txt")
      lines dump `shouldContain` ["  1 text/plain charset=iso-8859-1 cte=7bit size=4 adler32=04680214 role=text"]
      lines dump `shouldContain` ["| café"]
      removeDirectoryRecursive out

