-- | The sixteen built-in commands: their static description (arguments,
-- input/output shape, default cost), canonical rendering, and execution
-- against a workspace snapshot.
module Kiln.Command
  ( CmdKind (..)
  , CmdArg (..)
  , ArgTy (..)
  , Command (..)
  , CmdResult (..)
  , allCommands
  , lookupCommand
  , cmdName
  , cmdParams
  , cmdInputRange
  , cmdUsesDepfile
  , cmdDefaultCost
  , renderCommand
  , runCommand
  , linesOf
  , unlinesBS
  , replaceAll
  ) where

import Control.Monad (foldM, unless)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.Int (Int64)
import Data.List (sort)
import qualified Data.Set as Set
import Data.Word (Word8)
import Numeric (showHex)

import Kiln.Error
import Kiln.Hash (Hash, hashHex)
import Kiln.Path (isWorkspacePath)
import Kiln.Workspace (File (..), Workspace, lookupFile)

data CmdKind
  = CmdWrite | CmdCopy | CmdConcat | CmdUpper | CmdLower | CmdGrep
  | CmdReplace | CmdSortLines | CmdReverseLines | CmdDedup | CmdNumber
  | CmdIndent | CmdWrap | CmdCountLines | CmdHash | CmdPreprocess
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | A command argument value.
data CmdArg = CStr !BS.ByteString | CInt !Int64
  deriving (Eq, Show)

-- | The type of a command parameter.
data ArgTy = TyStr | TyInt
  deriving (Eq, Show)

-- | A command together with its evaluated arguments.
data Command = Command
  { cmdKind :: !CmdKind
  , cmdArgs :: [CmdArg]
  }
  deriving (Eq, Show)

-- | What a successful command execution produced.
data CmdResult = CmdResult
  { resultFiles :: [(BS.ByteString, BS.ByteString)]
    -- ^ every output (path, content), in full-output-list order
  , resultDeps :: [(BS.ByteString, Hash)]
    -- ^ discovered dependencies with the hash of the content read, sorted
  }

allCommands :: [CmdKind]
allCommands = [minBound .. maxBound]

cmdName :: CmdKind -> BS.ByteString
cmdName k = case k of
  CmdWrite -> "write"
  CmdCopy -> "copy"
  CmdConcat -> "concat"
  CmdUpper -> "upper"
  CmdLower -> "lower"
  CmdGrep -> "grep"
  CmdReplace -> "replace"
  CmdSortLines -> "sort_lines"
  CmdReverseLines -> "reverse_lines"
  CmdDedup -> "dedup"
  CmdNumber -> "number"
  CmdIndent -> "indent"
  CmdWrap -> "wrap"
  CmdCountLines -> "count_lines"
  CmdHash -> "hash"
  CmdPreprocess -> "preprocess"

lookupCommand :: BS.ByteString -> Maybe CmdKind
lookupCommand n = lookup n [(cmdName k, k) | k <- allCommands]

cmdParams :: CmdKind -> [ArgTy]
cmdParams k = case k of
  CmdWrite -> [TyStr]
  CmdGrep -> [TyStr]
  CmdReplace -> [TyStr, TyStr]
  CmdIndent -> [TyInt]
  CmdWrap -> [TyStr, TyStr]
  _ -> []

-- | Allowed number of file inputs: @(lo, Just hi)@ or @(lo, Nothing)@ for "or more".
cmdInputRange :: CmdKind -> (Int, Maybe Int)
cmdInputRange k = case k of
  CmdWrite -> (0, Just 0)
  CmdConcat -> (1, Nothing)
  CmdCountLines -> (1, Nothing)
  CmdHash -> (1, Nothing)
  _ -> (1, Just 1)

cmdUsesDepfile :: CmdKind -> Bool
cmdUsesDepfile = (== CmdPreprocess)

cmdDefaultCost :: CmdKind -> Int
cmdDefaultCost k = case k of
  CmdWrite -> 1
  CmdCopy -> 1
  CmdConcat -> 2
  CmdUpper -> 2
  CmdLower -> 2
  CmdGrep -> 3
  CmdReplace -> 3
  CmdSortLines -> 4
  CmdReverseLines -> 2
  CmdDedup -> 3
  CmdNumber -> 2
  CmdIndent -> 2
  CmdWrap -> 1
  CmdCountLines -> 2
  CmdHash -> 3
  CmdPreprocess -> 6

-- | The canonical command string, e.g. @write("hi\\n")@.
renderCommand :: Command -> BS.ByteString
renderCommand (Command k args) =
  cmdName k <> "(" <> BS.intercalate ", " (map arg args) <> ")"
  where
    arg (CInt n) = BC.pack (show n)
    arg (CStr s) = "\"" <> BS.concatMap esc s <> "\""
    esc :: Word8 -> BS.ByteString
    esc 0x5c = "\\\\"
    esc 0x22 = "\\\""
    esc 0x0a = "\\n"
    esc 0x09 = "\\t"
    esc 0x0d = "\\r"
    esc b
      | b < 0x20 || b == 0x7f = "\\x" <> BC.pack (pad (showHex b ""))
      | otherwise = BS.singleton b
    pad h = replicate (2 - length h) '0' ++ h

-- | The lines of a byte string (see the specification's "Lines of a file").
linesOf :: BS.ByteString -> [BS.ByteString]
linesOf c
  | BS.null c = []
  | otherwise = case BS.split 0x0a c of
      ps | not (null ps), BS.null (last ps) -> init ps
         | otherwise -> ps

-- | Concatenate lines, each followed by a newline.
unlinesBS :: [BS.ByteString] -> BS.ByteString
unlinesBS = BS.concat . concatMap (\l -> [l, "\n"])

-- | Replace every non-overlapping occurrence of @from@ (left to right).
-- @from@ must be non-empty.
replaceAll :: BS.ByteString -> BS.ByteString -> BS.ByteString -> BS.ByteString
replaceAll from to s = BS.concat (go s)
  where
    go t = case BS.breakSubstring from t of
      (pre, rest)
        | BS.null rest -> [pre]
        | otherwise -> pre : to : go (BS.drop (BS.length from) rest)

-- | Execute a command against a workspace snapshot.  @inputs@ are the step's
-- file inputs, @outputs@ its full output list (declared outputs, then the
-- depfile if any).
runCommand :: Workspace -> Command -> [BS.ByteString] -> [BS.ByteString] -> Either KilnError CmdResult
runCommand ws (Command kind args) inputs outputs = case kind of
  CmdPreprocess -> case (inputs, outputs) of
    ([p], [o, d]) -> do
      (body, found) <- preprocess ws p
      let depText = BS.concat (["kiln-deps 1\n"] ++ [BS.concat ["need ", q, "\n"] | q <- found])
          deps = [(q, maybe (hashOfMissing) fileHash (lookupFile q ws)) | q <- found]
      pure (CmdResult [(o, body), (d, depText)] deps)
    _ -> Left (EInternal "preprocess step shape")
  _ -> pure (CmdResult [(o, content) | o <- take 1 outputs] [])
  where
    hashOfMissing = 0
    contents = [maybe BS.empty fileContent (lookupFile p ws) | p <- inputs]
    firstInput = case contents of c : _ -> c; [] -> BS.empty
    strArg i = case drop i args of CStr s : _ -> s; _ -> BS.empty
    content = case kind of
      CmdWrite -> strArg 0
      CmdCopy -> firstInput
      CmdConcat -> BS.concat contents
      CmdUpper -> BS.map upperByte firstInput
      CmdLower -> BS.map lowerByte firstInput
      CmdGrep -> unlinesBS [l | l <- linesOf firstInput, strArg 0 `BS.isInfixOf` l]
      CmdReplace -> replaceAll (strArg 0) (strArg 1) firstInput
      CmdSortLines -> unlinesBS (sortBS (linesOf firstInput))
      CmdReverseLines -> unlinesBS (reverse (linesOf firstInput))
      CmdDedup -> unlinesBS (dedupLines (linesOf firstInput))
      CmdNumber -> unlinesBS [BC.pack (show i) <> ": " <> l | (i, l) <- zip [1 :: Int ..] (linesOf firstInput)]
      CmdIndent ->
        let n = case args of CInt k : _ -> fromIntegral k; _ -> 0
         in unlinesBS [BS.replicate n 0x20 <> l | l <- linesOf firstInput]
      CmdWrap -> strArg 0 <> firstInput <> strArg 1
      CmdCountLines ->
        let counts = [length (linesOf c) | c <- contents]
         in unlinesBS
              ( [BC.pack (show k) <> " " <> p | (k, p) <- zip counts inputs]
                  ++ [BC.pack (show (sum counts)) <> " total"]
              )
      CmdHash ->
        unlinesBS
          [ hashHex (maybe 0 fileHash (lookupFile p ws)) <> " " <> p
          | p <- inputs
          ]
      CmdPreprocess -> BS.empty

upperByte, lowerByte :: Word8 -> Word8
upperByte b = if b >= 0x61 && b <= 0x7a then b - 32 else b
lowerByte b = if b >= 0x41 && b <= 0x5a then b + 32 else b

sortBS :: [BS.ByteString] -> [BS.ByteString]
sortBS = sort

dedupLines :: [BS.ByteString] -> [BS.ByteString]
dedupLines = go Set.empty
  where
    go _ [] = []
    go seen (l : ls)
      | Set.member l seen = go seen ls
      | otherwise = l : go (Set.insert l seen) ls

-- | Expand @\@need@ directives; returns the expansion and the sorted,
-- deduplicated set of discovered paths.
preprocess :: Workspace -> BS.ByteString -> Either KilnError (BS.ByteString, [BS.ByteString])
preprocess ws primary = do
  (found, out) <- expand [] primary (Set.empty, [])
  pure (unlinesBS (reverse out), Set.toAscList found)
  where
    expand stack p acc = do
      let stack' = p : stack
          content = maybe BS.empty fileContent (lookupFile p ws)
      foldM (line stack' p) acc (linesOf content)
    line stack p (found, out) l = case needTarget l of
      Nothing -> Right (found, l : out)
      Just q -> do
        unless (isWorkspacePath q) (Left (ENeedPath q))
        case lookupFile q ws of
          Nothing -> Left (ENeedMissing q p)
          Just _ -> pure ()
        unless (q `notElem` stack) (Left (ENeedCycle q))
        expand stack q (Set.insert q found, out)
    needTarget l
      | "@need " `BS.isPrefixOf` l && BS.length l > 6 = Just (BS.drop 6 l)
      | otherwise = Nothing
