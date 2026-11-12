-- |
-- Module      : Mime
-- Description : MIME email parsing and mailbox dumping.
--
-- A hand-written parser for RFC 5322 / RFC 2045-2047 / RFC 2231 messages.
-- The usual entry points are:
--
-- * 'readMailbox' to obtain the raw messages of an mbox file or a directory of
--   @.eml@ files;
-- * 'parseMessage' to parse the bytes of one message;
-- * 'renderMessage' / 'renderSummary' to produce the text dump, or
--   'dumpMailbox' to do the whole job and write the output tree.
--
-- > import qualified Data.ByteString.Char8 as B
-- > import Mime
-- >
-- > main :: IO ()
-- > main = do
-- >   let m = parseMessage (B.pack "Subject: hi\n\nHello\n")
-- >   putStr (renderMessage 1 "example" m)
module Mime
  ( -- * Mailboxes
    Source (..)
  , readMailbox
  , splitMbox
    -- * Messages
  , Message (..)
  , parseMessage
  , messageParts
  , Part (..)
  , PartBody (..)
  , Field (..)
    -- * Header values
  , Address (..)
  , parseAddressList
  , ParsedDate (..)
  , parseDate
  , decodeUnstructured
    -- * Output
  , renderMessage
  , renderSummary
  , renderSummaryLine
  , dumpMailbox
  , dumpSources
  ) where

import qualified Data.ByteString as B
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))

import Mime.Address
import Mime.Charset (encodeUtf8)
import Mime.Date
import Mime.EncodedWord (decodeUnstructured)
import Mime.Header
import Mime.Mailbox
import Mime.Message
import Mime.Part
import Mime.Render

-- | Read the mailbox at the first path and write the dump into the directory
-- named by the second.
dumpMailbox :: FilePath -> FilePath -> IO ()
dumpMailbox input out = readMailbox input >>= dumpSources out

-- | Write @summary.txt@, @messages/NNNN.txt@ and @parts/NNNN/PPP.bin@ for the
-- given messages below the output directory.
dumpSources :: FilePath -> [Source] -> IO ()
dumpSources out sources = do
  createDirectoryIfMissing True (out </> "messages")
  results <- mapM one (zip [1 ..] sources)
  B.writeFile (out </> "summary.txt") (encodeUtf8 (renderSummary results))
  where
    one (no, Source sid raw) = do
      let m = parseMessage raw
      B.writeFile (out </> "messages" </> pad4 no ++ ".txt") (encodeUtf8 (renderMessage no sid m))
      mapM_ (writeAttachment no) (msgAttachments m)
      pure (renderSummaryLine no sid m)
    writeAttachment no p = case partBody p of
      Leaf content _ -> do
        let path = out </> attachmentPath no p
        createDirectoryIfMissing True (out </> "parts" </> pad4 no)
        B.writeFile path content
      _ -> pure ()
    pad4 n = let s = show n in replicate (4 - length s) '0' ++ s

