{-# LANGUAGE OverloadedStrings #-}

-- | Recursive-descent parser for the command language (SPEC §6, §17.1).
--
-- Errors are reported in source order, as SPEC §18.2 requires: each token is
-- resolved at the moment the parser consumes it.
module Tessera.Parser
  ( parseCommand
  , parseValue
  , parsePred
  ) where

import qualified Data.ByteString as BS
import qualified Data.Map.Strict as Map
import Control.Monad (unless, when)
import Tessera.Command
import Tessera.Constants
import Tessera.Error (ErrorKind (..))
import Tessera.Lexer
import Tessera.Path (Path, mkPath)
import Tessera.Query
import Tessera.Value (Value (..))

newtype P a = P {runP :: [Token] -> Either ErrorKind (a, [Token])}

instance Functor P where
  fmap f (P g) = P $ \ts -> case g ts of
    Left e -> Left e
    Right (a, r) -> Right (f a, r)

instance Applicative P where
  pure a = P $ \ts -> Right (a, ts)
  P f <*> P g = P $ \ts -> case f ts of
    Left e -> Left e
    Right (h, r) -> case g r of
      Left e -> Left e
      Right (a, r') -> Right (h a, r')

instance Monad P where
  P g >>= f = P $ \ts -> case g ts of
    Left e -> Left e
    Right (a, r) -> runP (f a) r

failWith :: ErrorKind -> P a
failWith e = P $ \_ -> Left e

peekN :: Int -> P [Token]
peekN n = P $ \ts -> Right (take n ts, ts)

peekTok :: P (Maybe Token)
peekTok = P $ \ts -> Right (case ts of t : _ -> Just t; [] -> Nothing, ts)

advance :: P ()
advance = P $ \ts -> Right ((), drop 1 ts)

nextTok :: P Token
nextTok = P $ \ts -> case ts of
  t : r -> Right (t, r)
  [] -> Left Syntax

expectPunct :: Char -> P ()
expectPunct c = do
  t <- nextTok
  unless (t == TPunct c) (failWith Syntax)

-- | A string token, resolved.
stringArg :: P BS.ByteString
stringArg = do
  t <- nextTok
  case t of
    TString (Just s) -> pure s
    TString Nothing -> failWith BadUtf8
    _ -> failWith Syntax

-- | A key argument: a string of 1 to 128 bytes.
keyArg :: P BS.ByteString
keyArg = do
  s <- stringArg
  when (BS.null s || BS.length s > maxKey) (failWith BadKey)
  pure s

-- | A field path, checking the limits as each segment is consumed.
pathArg :: P Path
pathArg = do
  first <- wordTok
  checkLimits [first]
  more [first]
  where
    wordTok = do
      t <- nextTok
      case t of
        TWord w -> pure w
        _ -> failWith Syntax
    checkLimits revSegs = do
      let segs = reverse revSegs
      when (length segs > maxPathSegments) (failWith BadPath)
      when (BS.length (BS.intercalate "." segs) > maxPath) (failWith BadPath)
    more revSegs = do
      mt <- peekTok
      case mt of
        Just (TPunct '.') -> do
          advance
          w <- wordTok
          let revSegs' = w : revSegs
          checkLimits revSegs'
          more revSegs'
        _ -> either failWith pure (mkPath (reverse revSegs))

-- | A value at the given nesting level (SPEC §6.3).
valueAt :: Int -> P Value
valueAt lvl = do
  when (lvl > maxDepth) (failWith Depth)
  t <- nextTok
  case t of
    TWord "null" -> pure VNull
    TWord "true" -> pure (VBool True)
    TWord "false" -> pure (VBool False)
    TInt n -> intValue n
    TString (Just s) -> pure (VString s)
    TString Nothing -> failWith BadUtf8
    TPunct '[' -> listBody lvl
    TPunct '{' -> objectBody lvl
    _ -> failWith Syntax

intValue :: Integer -> P Value
intValue n
  | n < -9223372036854775808 || n > 9223372036854775807 = failWith IntRange
  | otherwise = pure (VInt (fromInteger n))

listBody :: Int -> P Value
listBody lvl = do
  mt <- peekTok
  case mt of
    Just (TPunct ']') -> advance >> pure (VList [])
    _ -> do
      x <- valueAt (lvl + 1)
      go [x]
  where
    go acc = do
      t <- nextTok
      case t of
        TPunct ',' -> do
          x <- valueAt (lvl + 1)
          go (x : acc)
        TPunct ']' -> pure (VList (reverse acc))
        _ -> failWith Syntax

objectBody :: Int -> P Value
objectBody lvl = do
  mt <- peekTok
  case mt of
    Just (TPunct '}') -> advance >> pure (VObject Map.empty)
    _ -> go Map.empty
  where
    go acc = do
      t <- nextTok
      name <- case t of
        TString (Just s) -> pure s
        TString Nothing -> failWith BadUtf8
        TWord w -> pure w
        _ -> failWith Syntax
      when (Map.member name acc) (failWith DupField)
      expectPunct ':'
      x <- valueAt (lvl + 1)
      let acc' = Map.insert name x acc
      t' <- nextTok
      case t' of
        TPunct ',' -> go acc'
        TPunct '}' -> pure (VObject acc')
        _ -> failWith Syntax

-- | A @limit@ argument (SPEC §6.5).
limitArg :: P Int
limitArg = do
  t <- nextTok
  case t of
    TInt n
      | n < -9223372036854775808 || n > 9223372036854775807 -> failWith IntRange
      | n < 0 || n > fromIntegral maxLimit -> failWith Syntax
      | otherwise -> pure (fromInteger n)
    _ -> failWith Syntax

predicate :: P Pred
predicate = disj
  where
    disj = conj >>= goOr
    goOr l = do
      mt <- peekTok
      case mt of
        Just (TWord "or") -> advance >> conj >>= goOr . POr l
        _ -> pure l
    conj = term >>= goAnd
    goAnd l = do
      mt <- peekTok
      case mt of
        Just (TWord "and") -> advance >> term >>= goAnd . PAnd l
        _ -> pure l
    term = do
      ts <- peekN 2
      case ts of
        TPunct '(' : _ -> do
          advance
          p <- predicate
          expectPunct ')'
          pure p
        [TWord "not", TPunct '('] -> do
          advance >> advance
          p <- predicate
          expectPunct ')'
          pure (PNot p)
        [TWord "exists", TWord _] -> advance >> PExists <$> pathArg
        [TWord "missing", TWord _] -> advance >> PMissing <$> pathArg
        TWord _ : _ -> do
          path <- pathArg
          op <- cmpOp
          PCmp path op <$> valueAt 1
        _ -> failWith Syntax
    cmpOp = do
      t <- nextTok
      case t of
        TOp o -> pure o
        _ -> failWith Syntax

scanOptions :: P ScanOptions
scanOptions = go defaultScanOptions (False, False, False, False, False)
  where
    go o seen@(sf, st, sl, sr, sk) = do
      mt <- peekTok
      case mt of
        Just (TWord "from") -> do
          when sf (failWith Syntax)
          advance
          s <- stringArg
          go o {scanFrom = Just s} (True, st, sl, sr, sk)
        Just (TWord "to") -> do
          when st (failWith Syntax)
          advance
          s <- stringArg
          go o {scanTo = Just s} (sf, True, sl, sr, sk)
        Just (TWord "limit") -> do
          when sl (failWith Syntax)
          advance
          n <- limitArg
          go o {scanLimit = Just n} (sf, st, True, sr, sk)
        Just (TWord "reverse") -> do
          when sr (failWith Syntax)
          advance
          go o {scanReverse = True} (sf, st, sl, True, sk)
        Just (TWord "keys") -> do
          when sk (failWith Syntax)
          advance
          go o {scanKeysOnly = True} (sf, st, sl, sr, True)
        _ -> const (pure o) seen

command :: BS.ByteString -> P Command
command w = case w of
  "begin" -> pure Begin
  "commit" -> pure Commit
  "rollback" -> pure Rollback
  "checkpoint" -> pure Checkpoint
  "stat" -> pure Stat
  "indexes" -> pure Indexes
  "put" -> Put <$> keyArg <*> valueAt 1
  "get" -> Get <$> keyArg
  "delete" -> Delete <$> keyArg
  "update" -> Update <$> keyArg <*> pathArg <*> valueAt 1
  "unset" -> Unset <$> keyArg <*> pathArg
  "scan" -> Scan <$> scanOptions
  "find" -> do
    p <- predicate
    mt <- peekTok
    case mt of
      Just (TWord "limit") -> advance >> Find p . Just <$> limitArg
      _ -> pure (Find p Nothing)
  "create" -> indexWord >> CreateIndex <$> pathArg
  "drop" -> indexWord >> DropIndex <$> pathArg
  _ -> failWith UnknownCommand
  where
    indexWord = do
      t <- nextTok
      unless (t == TWord "index") (failWith Syntax)

-- | Lex and parse one command line.
parseCommand :: BS.ByteString -> Either ErrorKind Command
parseCommand line = do
  toks <- lexLine line
  case toks of
    TWord w : rest -> do
      (c, left) <- runP (command w) rest
      unless (null left) (Left Syntax)
      Right c
    _ -> Left Syntax

-- | Parse a standalone value literal such as @{name:"ada",age:36}@.
parseValue :: BS.ByteString -> Either ErrorKind Value
parseValue = parseWhole (valueAt 1)

-- | Parse a standalone predicate such as @age > 30 and name == "x"@.
parsePred :: BS.ByteString -> Either ErrorKind Pred
parsePred = parseWhole predicate

parseWhole :: P a -> BS.ByteString -> Either ErrorKind a
parseWhole p line = do
  toks <- lexLine line
  (a, left) <- runP p toks
  unless (null left) (Left Syntax)
  Right a
