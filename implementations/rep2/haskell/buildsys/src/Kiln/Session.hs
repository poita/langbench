-- | Session scripts: parsing @session.txt@, running it and producing the log.
module Kiln.Session
  ( SessionStep (..)
  , parseSession
  , runSession
  ) where

import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import Data.List (mapAccumL)

import Kiln.Build
import Kiln.Error
import Kiln.Scheduler
import Kiln.Text (renderInt)
import Kiln.Workspace

-- | One step of a session script.
data SessionStep
  = SBuild [B.ByteString] !Int
  | SCreate Path B.ByteString
  | SEdit Path B.ByteString
  | SDelete Path
  | STouch Path
  | SClean
  deriving (Eq, Show)

-- | Parse @session.txt@. The input is assumed to be well formed.
parseSession :: B.ByteString -> [SessionStep]
parseSession = go . B.split 10
  where
    isWs b = b == 32 || b == 9
    go [] = []
    go (l : ls)
      | B.all isWs l = go ls
      | B.take 1 (B.dropWhile isWs l) == "#" = go ls
      | otherwise =
          let ws = words' l
           in case ws of
                ("build" : rest) -> sBuild rest : go ls
                [kind, path] | kind == "create" || kind == "edit" ->
                  let (body, after) = break (== "---") ls
                      content = B.concat [b <> "\n" | b <- body]
                      step = if kind == "create" then SCreate else SEdit
                   in step path content : go (drop 1 after)
                ["delete", p] -> SDelete p : go ls
                ["touch", p] -> STouch p : go ls
                ["clean"] -> SClean : go ls
                _ -> go ls -- not well formed; ignored
    words' = filter (not . B.null) . B.splitWith isWs
    sBuild rest
      | n >= 2 && rest !! (n - 2) == "-j" =
          SBuild (take (n - 2) rest) (maybe 1 fst (BC.readInt (last rest)))
      | otherwise = SBuild rest 1
      where
        n = length rest

-- | Run a session against a workspace, returning the log text and the final
-- workspace.
runSession :: Workspace -> [SessionStep] -> (B.ByteString, Workspace)
runSession ws steps = (B.concat (concat logs), final)
  where
    (final, logs) = mapAccumL one ws (zip [1 :: Int ..] steps)
    one w (n, st) =
      let (hdr, body, w') = runStep w st
       in (w', ["step " <> renderInt n <> ": " <> hdr <> "\n"] ++ map (\l -> "  " <> l <> "\n") body)

-- | The header line, the indented lines (event lines then the result), and
-- the new workspace.
runStep :: Workspace -> SessionStep -> (B.ByteString, [B.ByteString], Workspace)
runStep ws st = case st of
  SBuild targets j ->
    let out = build ws (BuildRequest targets j)
        hdr =
          B.intercalate " " (["build"] ++ (if null targets then ["(default)"] else targets) ++ ["-j", renderInt j])
        result = case boResult out of
          Left e -> "error " <> renderError e
          Right s -> "ok ran=" <> renderInt (bsRan s) <> " hit=" <> renderInt (bsHit s) <> " time=" <> renderInt (bsTime s)
     in (hdr, map renderEvent (boEvents out) ++ [result], boWorkspace out)
  SCreate p c -> ("create " <> p, ["ok size=" <> renderInt (B.length c)], insertContent p c ws)
  SEdit p c -> ("edit " <> p, ["ok size=" <> renderInt (B.length c)], insertContent p c ws)
  SDelete p -> ("delete " <> p, ["ok"], deleteFile p ws)
  STouch p -> ("touch " <> p, ["ok"], ws)
  SClean ->
    let doomed = [p | p <- paths ws, isGenerated p || p == stateFilePath]
        ws' = filterPaths (\p -> not (isGenerated p || p == stateFilePath)) ws
     in ("clean", ["remove " <> p | p <- doomed] ++ ["ok removed=" <> renderInt (length doomed)], ws')

renderEvent :: Event -> B.ByteString
renderEvent e = case evKind e of
  Hit -> B.intercalate " " ["hit", renderInt (evStart e), evTarget e]
  Ran -> exec "run"
  Failed -> exec "fail"
  Cancelled -> exec "cancel"
  where
    exec w =
      B.intercalate " "
        [w, renderInt (evStart e), renderInt (evEnd e), "w" <> renderInt (evWorker e), evTarget e, evCommand e]
