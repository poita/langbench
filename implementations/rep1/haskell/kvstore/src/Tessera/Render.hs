{-# LANGUAGE OverloadedStrings #-}

-- | Result blocks of @results.txt@ (SPEC §19).
module Tessera.Render
  ( renderBlock
  ) where

import qualified Data.ByteString.Builder as B
import Tessera.Error (ErrorKind, errorName)
import Tessera.Exec (Reply (..))
import Tessera.Path (pathText)
import Tessera.Query (planText)
import Tessera.Store (IndexInfo (..), PutOutcome (..), Stat (..))
import Tessera.Value (renderBuilder, renderString)

-- | The block for command line @k@ (1-based), ending in a newline.
renderBlock :: Int -> Either ErrorKind Reply -> B.Builder
renderBlock k result = B.char7 '[' <> B.intDec k <> "] " <> body
  where
    line b = b <> B.char7 '\n'
    payload b = line ("  " <> b)
    int = B.intDec
    body = case result of
      Left e -> line ("error " <> B.string7 (errorName e))
      Right r -> case r of
        RBegin -> line "ok begin"
        RCommit t f -> line ("ok commit " <> int t <> " frames " <> int f)
        RRollback -> line "ok rollback"
        RCheckpoint n -> line ("ok checkpoint pages " <> int n)
        RPut Created -> line "ok put created"
        RPut Replaced -> line "ok put replaced"
        RGet v -> line "ok get value" <> payload (renderBuilder v)
        RDelete -> line "ok delete removed"
        RUpdate -> line "ok update updated"
        RUnset -> line "ok unset updated"
        RScan items ->
          line ("ok scan " <> int (length items))
            <> mconcat [payload (maybe key (\v -> key <> " = " <> renderBuilder v) mv) | (k', mv) <- items, let key = renderString k']
        RFind plan items ->
          line ("ok find " <> int (length items) <> " plan " <> B.byteString (planText plan))
            <> mconcat [payload (renderString k' <> " = " <> renderBuilder v) | (k', v) <- items]
        RCreateIndex p n -> line ("ok create index " <> B.byteString (pathText p) <> " entries " <> int n)
        RDropIndex p n -> line ("ok drop index " <> B.byteString (pathText p) <> " pages " <> int n)
        RIndexes ixs ->
          line ("ok indexes " <> int (length ixs))
            <> mconcat
              [ payload (int s <> " " <> B.byteString p <> " root " <> int r <> " entries " <> int e)
              | IndexInfo s p r e <- ixs
              ]
        RStat s ->
          line "ok stat"
            <> payload ("pages " <> int (statPages s))
            <> payload ("free " <> int (statFree s))
            <> payload ("freehead " <> int (statFreeHead s))
            <> payload ("docs " <> int (statDocs s))
            <> payload ("root " <> int (statRoot s))
            <> payload ("height " <> int (statHeight s))
            <> payload ("commits " <> int (statCommits s))
            <> payload ("indexes " <> int (statIndexes s))
            <> payload ("wal " <> int (statWal s))
