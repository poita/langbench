-- | The batch input/output format used by the command-line tool.
--
-- The input is @N@, then for each of @N@ patterns: the pattern line, a
-- count @M@, and @M@ subject lines.  Lines are taken verbatim (no trimming).
-- The output has one line per subject: @no@, or
-- @match START END@ followed by @|S,E@ (or @|-@ if unset) for each group.
module Regex.Batch
  ( BatchError (..)
  , Output (..)
  , processBatch
  , runBatch
  , batchToBuilder
  , renderMatch
  ) where

import qualified Data.ByteString as B
import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Char8 as BC
import System.IO (Handle)

import Regex

-- | Why a batch could not be processed.
data BatchError
  = MalformedInput String      -- ^ the input does not follow the format
  | BadPattern Int String ParseError
    -- ^ pattern number (1-based), its text, and the syntax error
  deriving (Eq, Show)

-- | A lazily produced result: output lines in order, ending in either
-- success or an error.  Output for subjects before an error is still valid.
data Output
  = Done
  | Line BB.Builder Output       -- ^ one result line, including its newline
  | Failed BatchError

-- | Render one result as a line (without the newline).
renderMatch :: Maybe Match -> BB.Builder
renderMatch Nothing = BB.string7 "no"
renderMatch (Just (Match s e gs)) =
  BB.string7 "match " <> BB.intDec s <> BB.char7 ' ' <> BB.intDec e <> foldMap grp gs
  where
    grp Nothing       = BB.string7 "|-"
    grp (Just (a, b)) = BB.char7 '|' <> BB.intDec a <> BB.char7 ',' <> BB.intDec b

-- | Process a whole batch.  The result is produced lazily, so a consumer
-- that writes each line as it arrives runs in constant extra space.
processBatch :: B.ByteString -> Output
processBatch input = case nextLine 0 of
  Nothing -> Failed (MalformedInput "empty input")
  Just (l, off) -> case count l of
    Just n  -> goPatterns 1 n off
    Nothing -> Failed (MalformedInput "first line is not a pattern count")
  where
    len = B.length input

    count l = case BC.readInt l of
      Just (n, r) | B.null r, n >= 0 -> Just n
      _ -> Nothing

    -- the line starting at @off@, and the offset after its newline
    nextLine :: Int -> Maybe (B.ByteString, Int)
    nextLine off
      | off >= len = Nothing
      | otherwise =
          let rest = B.drop off input
          in case B.elemIndex 10 rest of
               Just k  -> Just (B.take k rest, off + k + 1)
               Nothing -> Just (rest, len)

    goPatterns :: Int -> Int -> Int -> Output
    goPatterns i n off
      | i > n = Done
      | otherwise = case nextLine off of
          Nothing -> Failed (MalformedInput ("missing pattern " ++ show i))
          Just (pat, off1) -> case nextLine off1 of
            Nothing -> Failed (MalformedInput ("missing subject count for pattern " ++ show i))
            Just (cnt, off2) -> case count cnt of
              Nothing -> Failed (MalformedInput ("bad subject count for pattern " ++ show i))
              Just m -> case compile (BC.unpack pat) of
                Left err -> Failed (BadPattern i (BC.unpack pat) err)
                Right re -> subjects re m off2 (goPatterns (i + 1) n)

    subjects :: Regex -> Int -> Int -> (Int -> Output) -> Output
    subjects _ 0 off next = next off
    subjects re k off next = case nextLine off of
      Nothing -> Failed (MalformedInput "missing subject line")
      Just (subj, off') ->
        Line (renderMatch (search re subj) <> BB.char7 '\n')
             (subjects re (k - 1 :: Int) off' next)

-- | Collect the results that were produced, and the error if there was one.
batchToBuilder :: Output -> (BB.Builder, Maybe BatchError)
batchToBuilder Done = (mempty, Nothing)
batchToBuilder (Failed e) = (mempty, Just e)
batchToBuilder (Line b rest) = let (bs, e) = batchToBuilder rest in (b <> bs, e)

-- | Process a batch, writing each line to the handle as it is computed.
runBatch :: B.ByteString -> Handle -> IO (Either BatchError ())
runBatch input out = go (processBatch input)
  where
    go Done = pure (Right ())
    go (Failed e) = pure (Left e)
    go (Line b rest) = BB.hPutBuilder out b >> go rest
