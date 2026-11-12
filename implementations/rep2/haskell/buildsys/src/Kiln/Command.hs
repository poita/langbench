-- | The sixteen built-in commands: their signatures, canonical rendering and
-- execution against a virtual file system.
module Kiln.Command
  ( CmdName (..)
  , CmdArg (..)
  , Command (..)
  , ArgTy (..)
  , CmdSpec (..)
  , lookupCommand
  , cmdSpec
  , allCommands
  , renderCommand
  , shapeError
  , argError
  , CmdOutput (..)
  , runCommand
  ) where

import Control.Monad.State.Strict
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import qualified Data.Map.Strict as M
import Data.List (sort)
import qualified Data.Set as S

import Kiln.Error
import Kiln.Hash
import Kiln.Text
import Kiln.Workspace

-- | The sixteen commands.
data CmdName
  = Write | Copy | Concat | Upper | Lower | Grep | Replace | SortLines
  | ReverseLines | Dedup | Number | Indent | Wrap | CountLines | HashCmd
  | Preprocess
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | A command argument: a string or an integer.
data CmdArg = ArgStr !B.ByteString | ArgInt !Int
  deriving (Eq, Show)

-- | A command with its evaluated arguments.
data Command = Command
  { cmdName :: !CmdName
  , cmdArgs :: [CmdArg]
  }
  deriving (Eq, Show)

data ArgTy = ArgTyStr | ArgTyInt
  deriving (Eq, Show)

-- | Static description of a command.
data CmdSpec = CmdSpec
  { csName :: !B.ByteString
  , csArgs :: [ArgTy]
  , csMinInputs :: !Int
  , csMaxInputs :: !(Maybe Int)
    -- ^ 'Nothing' for "or more"
  , csDepfile :: !Bool
  , csCost :: !Int
  }

allCommands :: [CmdName]
allCommands = [minBound .. maxBound]

-- | Find a command by its KBL name.
lookupCommand :: B.ByteString -> Maybe CmdName
lookupCommand n = M.lookup n byName
  where
    byName = M.fromList [(csName (cmdSpec c), c) | c <- allCommands]

cmdSpec :: CmdName -> CmdSpec
cmdSpec c = case c of
  Write -> CmdSpec "write" [ArgTyStr] 0 (Just 0) False 1
  Copy -> one "copy" [] 1
  Concat -> CmdSpec "concat" [] 1 Nothing False 2
  Upper -> one "upper" [] 2
  Lower -> one "lower" [] 2
  Grep -> one "grep" [ArgTyStr] 3
  Replace -> one "replace" [ArgTyStr, ArgTyStr] 3
  SortLines -> one "sort_lines" [] 4
  ReverseLines -> one "reverse_lines" [] 2
  Dedup -> one "dedup" [] 3
  Number -> one "number" [] 2
  Indent -> one "indent" [ArgTyInt] 2
  Wrap -> one "wrap" [ArgTyStr, ArgTyStr] 1
  CountLines -> CmdSpec "count_lines" [] 1 Nothing False 2
  HashCmd -> CmdSpec "hash" [] 1 Nothing False 3
  Preprocess -> CmdSpec "preprocess" [] 1 (Just 1) True 6
  where
    one n as cost = CmdSpec n as 1 (Just 1) False cost

-- | The canonical rendering, e.g. @write("hello\\n")@.
renderCommand :: Command -> B.ByteString
renderCommand (Command n args) =
  B.concat [csName (cmdSpec n), "(", B.intercalate ", " (map arg args), ")"]
  where
    arg (ArgInt i) = renderInt i
    arg (ArgStr s) = B.concat ["\"", B.concatMap esc s, "\""]
    esc b
      | b == 92 = "\\\\"
      | b == 34 = "\\\""
      | b == 10 = "\\n"
      | b == 9 = "\\t"
      | b == 13 = "\\r"
      | b < 0x20 || b == 0x7f = B.pack [92, 120, hex (b `div` 16), hex (b `mod` 16)]
      | otherwise = B.singleton b
    hex d = if d < 10 then 48 + d else 87 + d

-- | Check a step's input and output counts and its depfile against the
-- command, in the order @E_CMD_SHAPE@ is specified.
shapeError :: CmdName -> Int -> Int -> Bool -> Maybe BuildError
shapeError c fileInputs outputs hasDepfile
  | fileInputs < csMinInputs sp || maybe False (fileInputs >) (csMaxInputs sp) =
      Just (shape ("expected inputs " <> range <> ", got " <> renderInt fileInputs))
  | outputs /= 1 = Just (shape ("expected outputs 1, got " <> renderInt outputs))
  | csDepfile sp && not hasDepfile = Just (shape "depfile required")
  | not (csDepfile sp) && hasDepfile = Just (shape "depfile not allowed")
  | otherwise = Nothing
  where
    sp = cmdSpec c
    shape = ECmdShape (csName sp)
    range = case csMaxInputs sp of
      Just hi -> renderInt (csMinInputs sp) <> "-" <> renderInt hi
      Nothing -> renderInt (csMinInputs sp) <> "-N"

-- | Command-specific argument checks (@E_ARG cmd …@).
argError :: Command -> Maybe BuildError
argError (Command c args) = case (c, args) of
  (Replace, ArgStr f : _) | B.null f -> Just (EArg "cmd" "replace" "empty pattern")
  (Indent, [ArgInt n]) | n < 0 -> Just (EArg "cmd" "indent" "negative")
  _ -> Nothing

-- | What a successful command produces.
data CmdOutput = CmdOutput
  { coContent :: B.ByteString
    -- ^ the content of the declared output
  , coDepfile :: Maybe B.ByteString
    -- ^ the content of the depfile, for @preprocess@
  , coDiscovered :: [Path]
    -- ^ the discovered dependencies, sorted
  }

-- | Run a command. @inputs@ are the file inputs in declared order with their
-- content; @snapshot@ is the workspace as it stood when the command started
-- (@preprocess@ reads the files it needs from it). Errors are execution
-- errors.
runCommand :: Command -> [(Path, File)] -> Workspace -> Either BuildError CmdOutput
runCommand (Command name args) inputs snapshot = case name of
  Write -> plain (strArg 0)
  Copy -> plain input
  Concat -> plain (B.concat (map (fileContent . snd) inputs))
  Upper -> plain (B.map (\b -> if b >= 97 && b <= 122 then b - 32 else b) input)
  Lower -> plain (B.map (\b -> if b >= 65 && b <= 90 then b + 32 else b) input)
  Grep -> plain (unlinesBS (filter (B.isInfixOf (strArg 0)) ls))
  Replace -> plain (replaceAll (strArg 0) (strArg 1) input)
  SortLines -> plain (unlinesBS (sort ls))
  ReverseLines -> plain (unlinesBS (reverse ls))
  Dedup -> plain (unlinesBS (dedupe ls))
  Number -> plain (unlinesBS [renderInt i <> ": " <> l | (i, l) <- zip [1 ..] ls])
  Indent -> plain (unlinesBS (map (B.append (BC.replicate (intArg 0) ' ')) ls))
  Wrap -> plain (B.concat [strArg 0, input, strArg 1])
  CountLines ->
    let counts = [(p, length (fileLines (fileContent f))) | (p, f) <- inputs]
        total = sum (map snd counts)
     in plain (unlinesBS ([renderInt k <> " " <> p | (p, k) <- counts] ++ [renderInt total <> " total"]))
  HashCmd -> plain (unlinesBS [renderHash (fileHash f) <> " " <> p | (p, f) <- inputs])
  Preprocess -> preprocess
  where
    plain c = Right (CmdOutput c Nothing [])
    input = case inputs of (_, f) : _ -> fileContent f; [] -> B.empty
    ls = fileLines input
    strArg i = case drop i args of ArgStr s : _ -> s; _ -> B.empty
    intArg i = case drop i args of ArgInt n : _ -> n; _ -> 0
    dedupe = go S.empty
      where
        go _ [] = []
        go seen (x : xs)
          | S.member x seen = go seen xs
          | otherwise = x : go (S.insert x seen) xs
    preprocess = case inputs of
      [] -> Right (CmdOutput B.empty Nothing [])
      (p, f) : _ -> do
        (out, found) <- runStateT (expand [p] p (fileContent f)) S.empty
        let discovered = S.toAscList found
            dep = unlinesBS ("kiln-deps 1" : ["need " <> d | d <- discovered])
        Right (CmdOutput (unlinesBS (out [])) (Just dep) discovered)
    -- Returns the emitted lines as a difference list.
    expand :: [Path] -> Path -> B.ByteString -> StateT (S.Set Path) (Either BuildError) ([B.ByteString] -> [B.ByteString])
    expand stack self content = go (fileLines content) id
      where
        go [] acc = pure acc
        go (l : rest) acc = case B.stripPrefix "@need " l of
          Just q | not (B.null q) -> do
            lift (when' (not (isWorkspacePath q)) (ENeedPath q))
            target <- lift (maybe (Left (ENeedMissing q self)) Right (lookupFile q snapshot))
            lift (when' (q `elem` stack) (ENeedCycle q))
            modify' (S.insert q)
            sub <- expand (q : stack) q (fileContent target)
            go rest (acc . sub)
          _ -> go rest (acc . (l :))
    when' cond e = if cond then Left e else Right ()
