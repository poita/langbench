-- | Session scripts: parsing @session.txt@, running its steps against a
-- workspace and producing @log.txt@.
module Kiln.Session
  ( SessionStep (..)
  , parseSession
  , runSession
  , renderEvent
  ) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Builder as B
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy as BL

import Kiln.Build
import Kiln.Error (renderError)
import Kiln.Scheduler
import Kiln.Workspace (Workspace)
import qualified Kiln.Workspace as Workspace

-- | One step of a session script.
data SessionStep
  = Build [BS.ByteString] Int
    -- ^ targets as written, worker count
  | Create BS.ByteString BS.ByteString
    -- ^ path, content
  | Edit BS.ByteString BS.ByteString
  | Delete BS.ByteString
  | Touch BS.ByteString
  | Clean
  deriving (Eq, Show)

isBlankOrTab :: BS.ByteString -> Bool
isBlankOrTab = BS.all (\c -> c == 0x20 || c == 0x09)

stripBlanks :: BS.ByteString -> BS.ByteString
stripBlanks = BS.dropWhileEnd isBt . BS.dropWhile isBt
  where
    isBt c = c == 0x20 || c == 0x09

wordsOf :: BS.ByteString -> [BS.ByteString]
wordsOf = filter (not . BS.null) . BS.splitWith (\c -> c == 0x20 || c == 0x09)

-- | Parse a session script.  Lines that do not form a step are skipped.
parseSession :: BS.ByteString -> [SessionStep]
parseSession = go . BS.split 0x0a
  where
    go [] = []
    go (l : ls)
      | isBlankOrTab l || BS.take 1 (stripBlanks l) == "#" = go ls
      | otherwise = case wordsOf (stripBlanks l) of
          ("build" : args) -> build args : go ls
          [kw, path] | kw == "create" || kw == "edit" ->
            let (body, rest) = break (== "---") ls
                content = BS.concat (concatMap (\x -> [x, "\n"]) body)
             in (if kw == "create" then Create path content else Edit path content) : go (drop 1 rest)
          ["delete", path] -> Delete path : go ls
          ["touch", path] -> Touch path : go ls
          ["clean"] -> Clean : go ls
          _ -> go ls
    build args
      | n >= 2 && args !! (n - 2) == "-j" = Build (take (n - 2) args) (readInt (last args))
      | otherwise = Build args 1
      where
        n = length args
    readInt = maybe 1 fst . BC.readInt

-- | Render one build event as a log line (without the newline).
renderEvent :: Event -> BS.ByteString
renderEvent e = case evKind e of
  Hit -> BS.intercalate " " ["  hit", num (evStart e), evTarget e]
  Run -> exec "  run"
  Fail -> exec "  fail"
  Cancel -> exec "  cancel"
  where
    num = BC.pack . show
    exec tag =
      BS.intercalate
        " "
        [tag, num (evStart e), num (evEnd e), "w" <> num (evWorker e), evTarget e, evCommand e]

-- | Run a session against a workspace; returns the final workspace and the log.
runSession :: Workspace -> [SessionStep] -> IO (Workspace, BL.ByteString)
runSession ws0 steps = do
  (ws, chunks) <- go ws0 (1 :: Int) steps []
  pure (ws, B.toLazyByteString (mconcat (reverse chunks)))
  where
    go ws _ [] acc = pure (ws, acc)
    go ws n (s : rest) acc = do
      (ws', ls) <- runStep ws s
      let header = BC.pack ("step " ++ show n ++ ": ") <> describe s
          block = B.byteString (BS.concat [BS.concat [l, "\n"] | l <- header : ls])
      go ws' (n + 1) rest (block : acc)

    describe s = case s of
      Build ts j ->
        "build " <> (if null ts then "(default)" else BS.intercalate " " ts) <> " -j " <> BC.pack (show j)
      Create p _ -> "create " <> p
      Edit p _ -> "edit " <> p
      Delete p -> "delete " <> p
      Touch p -> "touch " <> p
      Clean -> "clean"

    runStep ws s = case s of
      Build ts j -> do
        r <- runBuild ws ts j
        let result = case brOutcome r of
              Left e -> "  error " <> renderError e
              Right st ->
                BC.pack ("  ok ran=" ++ show (statRan st) ++ " hit=" ++ show (statHit st) ++ " time=" ++ show (statTime st))
        pure (brWorkspace r, map renderEvent (brEvents r) ++ [result])
      Create p c -> write ws p c
      Edit p c -> write ws p c
      Delete p -> pure (Workspace.delete p ws, ["  ok"])
      Touch p -> pure (Workspace.touch p ws, ["  ok"])
      Clean ->
        let (removed, ws') = Workspace.removeGenerated ws
         in pure (ws', ["  remove " <> p | p <- removed] ++ [BC.pack ("  ok removed=" ++ show (length removed))])

    write ws p c =
      pure (Workspace.insert p c ws, [BC.pack ("  ok size=" ++ show (BS.length c))])
