-- | The document walk: property inheritance, transforms, @use@ resolution,
-- shapes, painting and group opacity (SPEC §5, §6, §7.1, §8).
module Graphics.SVG.Raster.Render
  ( renderDocument
  , Style (..)
  , initialStyle
  , computeStyle
  , viewportTransform
  ) where

import Control.Monad (when)
import Control.Monad.ST (ST)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)

import Graphics.SVG.Raster.Canvas
import Graphics.SVG.Raster.Color (RGB (..))
import Graphics.SVG.Raster.Geometry
import Graphics.SVG.Raster.Parse
import Graphics.SVG.Raster.Path
import Graphics.SVG.Raster.Stroke
import Graphics.SVG.Raster.Xml

-- | The inherited painting properties of an element (SPEC §6). @currentColor@
-- is already resolved; 'Nothing' for a paint means @none@.
data Style = Style
  { stFill :: Maybe RGB
  , stFillOpacity :: Double
  , stFillRule :: FillRule
  , stStroke :: Maybe RGB
  , stStrokeWidth :: Double
  , stLineCap :: LineCap
  , stLineJoin :: LineJoin
  , stMiterLimit :: Double
  , stStrokeOpacity :: Double
  , stColor :: RGB
  }
  deriving (Show)

-- | Initial values of the inherited properties.
initialStyle :: Style
initialStyle =
  Style
    { stFill = Just (RGB 0 0 0)
    , stFillOpacity = 1
    , stFillRule = NonZero
    , stStroke = Nothing
    , stStrokeWidth = 1
    , stLineCap = CapButt
    , stLineJoin = JoinMiter
    , stMiterLimit = 4
    , stStrokeOpacity = 1
    , stColor = RGB 0 0 0
    }

-- | The value of a property on an element: the @style@ declaration if there
-- is one, else the presentation attribute.
property :: Element -> String -> Maybe String
property el name = case Map.lookup name (styleOf el) of
  Just v -> Just v
  Nothing -> case attr name el of
    Just v | not (null (trim v)) -> Just (trim v)
    _ -> Nothing

styleOf :: Element -> Map String String
styleOf el = maybe Map.empty parseStyle (attr "style" el)

-- | Compute an element's inherited properties from its parent's.
computeStyle :: Style -> Element -> Style
computeStyle parent el =
  Style
    { stFill = paint "fill" (stFill parent) (Just (RGB 0 0 0))
    , stFillOpacity = opacityProp "fill-opacity" (stFillOpacity parent)
    , stFillRule = enum "fill-rule" (stFillRule parent) NonZero [("nonzero", NonZero), ("evenodd", EvenOdd)]
    , stStroke = paint "stroke" (stStroke parent) Nothing
    , stStrokeWidth = number "stroke-width" (stStrokeWidth parent) 1
    , stLineCap = enum "stroke-linecap" (stLineCap parent) CapButt [("butt", CapButt), ("round", CapRound), ("square", CapSquare)]
    , stLineJoin = enum "stroke-linejoin" (stLineJoin parent) JoinMiter [("miter", JoinMiter), ("round", JoinRound), ("bevel", JoinBevel)]
    , stMiterLimit = number "stroke-miterlimit" (stMiterLimit parent) 4
    , stStrokeOpacity = opacityProp "stroke-opacity" (stStrokeOpacity parent)
    , stColor = color
    }
  where
    color = case property el "color" of
      Nothing -> stColor parent
      Just v -> case parsePaint v of
        Just (PaintColor c) -> c
        Just PaintCurrentColor -> stColor parent
        _ -> RGB 0 0 0
    paint name inherited initial = case property el name of
      Nothing -> inherited
      Just v -> case parsePaint v of
        Just PaintNone -> Nothing
        Just PaintCurrentColor -> Just color
        Just (PaintColor c) -> Just c
        Nothing -> initial
    opacityProp name inherited = case property el name of
      Nothing -> inherited
      Just v -> fromMaybe 1 (parseOpacity v)
    number name inherited initial = case property el name of
      Nothing -> inherited
      Just v -> fromMaybe initial (parseLength v)
    enum name inherited initial table = case property el name of
      Nothing -> inherited
      Just v -> fromMaybe initial (lookup v table)

-- | The user-to-device transformation of the document element for an output
-- of the given pixel size (SPEC §7.1).
viewportTransform :: Int -> Int -> Element -> Affine
viewportTransform w h root = Affine sx 0 0 sy (-vx * sx) (-vy * sy)
  where
    (vx, vy, vw, vh) = case attr "viewBox" root >>= viewBox of
      Just r -> r
      Nothing -> case (attr "width" root >>= parseLength, attr "height" root >>= parseLength) of
        (Just ww, Just hh) | ww > 0 && hh > 0 -> (0, 0, ww, hh)
        _ -> (0, 0, fromIntegral w, fromIntegral h)
    viewBox s = case parseNumberList s of
      (a : b : c : d : _) | c > 0 && d > 0 -> Just (a, b, c, d)
      _ -> Nothing
    sx = fromIntegral w / vw
    sy = fromIntegral h / vh

data Env = Env
  { envIds :: Map String Element
  , envW :: Int
  , envH :: Int
  }

-- | Index every element by its @id@; the first in document order wins.
collectIds :: Element -> Map String Element
collectIds root = go root Map.empty
  where
    go el m =
      let m' = case attr "id" el of
            Just i | not (Map.member i m) -> Map.insert i el m
            _ -> m
       in foldl (flip go) m' (elChildren el)

-- | Render a parsed document onto a canvas.
renderDocument :: Canvas s -> Element -> ST s ()
renderDocument cv root =
  renderElement env cv 0 (viewportTransform w h root) initialStyle root
  where
    w = canvasWidth cv
    h = canvasHeight cv
    env = Env (collectIds root) w h

maxDepth :: Int
maxDepth = 64

renderElement :: Env -> Canvas s -> Int -> Affine -> Style -> Element -> ST s ()
renderElement env cv depth parentCtm parentStyle el
  | depth > maxDepth = pure ()
  | not (rendered (elName el)) = pure ()
  | property el "display" == Just "none" = pure ()
  | opacity <= 0 = pure ()
  | opacity >= 1 = body cv
  | otherwise = do
      layer <- newCanvas (envW env) (envH env)
      body layer
      compositeLayer cv layer opacity
  where
    rendered name
      | name == "svg" = depth == 0
      | otherwise = name `elem` ["g", "use", "path", "rect", "circle", "ellipse", "line", "polyline", "polygon"]
    opacity = maybe 1 (fromMaybe 1 . parseOpacity) (property el "opacity")
    style = computeStyle parentStyle el
    ctm
      | depth == 0 = parentCtm
      | otherwise = maybe parentCtm (compose parentCtm . parseTransform) (attr "transform" el)
    num name def = fromMaybe def (attr name el >>= parseLength)
    body target = case elName el of
      "svg" -> children target ctm
      "g" -> children target ctm
      "use" -> case attr "href" el of
        Just ('#' : ident) | Just ref <- Map.lookup ident (envIds env) ->
          renderElement env target (depth + 1) (compose ctm (translation (num "x" 0) (num "y" 0))) style ref
        _ -> pure ()
      "path" -> paintShape target ctm style (maybe [] parsePathData (attr "d" el))
      "rect" ->
        paintShape target ctm style $
          rectPath (num "x" 0) (num "y" 0) (num "width" 0) (num "height" 0)
            (attr "rx" el >>= parseLength) (attr "ry" el >>= parseLength)
      "circle" ->
        let r = num "r" 0 in paintShape target ctm style (ellipsePath (num "cx" 0) (num "cy" 0) r r)
      "ellipse" -> paintShape target ctm style (ellipsePath (num "cx" 0) (num "cy" 0) (num "rx" 0) (num "ry" 0))
      "line" -> paintShape target ctm style (linePath (num "x1" 0) (num "y1" 0) (num "x2" 0) (num "y2" 0))
      "polyline" -> paintShape target ctm style (polyPath False (maybe [] parseNumberList (attr "points" el)))
      "polygon" -> paintShape target ctm style (polyPath True (maybe [] parseNumberList (attr "points" el)))
      _ -> pure ()
    children target c = mapM_ (renderElement env target (depth + 1) c style) (elChildren el)

-- | Fill and then stroke a path (SPEC §8.1, §8.2).
paintShape :: Canvas s -> Affine -> Style -> Path -> ST s ()
paintShape cv ctm style path = do
  case stFill style of
    Just c | stFillOpacity style > 0 ->
      fillPolygons cv (stFillRule style) (unit c) (stFillOpacity style)
        [map (applyAffine ctm) (spPoints sp) | sp <- flattenPath ctm path]
    _ -> pure ()
  let scale = maxScale ctm
  case stStroke style of
    Just c
      | stStrokeWidth style > 0 && stStrokeOpacity style > 0 && scale > 0 -> do
          let ss =
                StrokeStyle
                  { ssWidth = stStrokeWidth style
                  , ssCap = stLineCap style
                  , ssJoin = stLineJoin style
                  , ssMiterLimit = stMiterLimit style
                  , ssTolerance = flattenTolerance / scale
                  }
              pieces = strokePieces ss (flattenPath ctm path)
          when (not (null pieces)) $
            fillPolygons cv NonZero (unit c) (stStrokeOpacity style) (map (map (applyAffine ctm)) pieces)
    _ -> pure ()
  where
    unit (RGB r g b) = (fromIntegral r / 255, fromIntegral g / 255, fromIntegral b / 255)
