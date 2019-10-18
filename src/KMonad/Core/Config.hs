{-# LANGUAGE DeriveAnyClass #-}
{-|
Module      : KMonad.Core.Config
Description : The types and utilities for dealing with configurations.
Copyright   : (c) David Janssen, 2019
License     : MIT

Maintainer  : janssen.dhj@gmail.com
Stability   : experimental
Portability : non-portable (MPTC with FD, FFI to Linux-only c-code)

The 'Config' object contains all the configuration settings for KMonad to fully
initialize, run, and shutdown again. It is possible to create your own KMonad
executable by specifying your own 'Config' record in a haskell source file and
running it with 'KMonad.Api.App.startAppIO'.

Alternatively, KMonad comes with a set of parsers that define a simple
mini-language for specifying keymap configurations. If you want to run KMonad
but don't want to have a full Haskell toolchain installed, it is possible to
simply run the binary on a configuration file.

The code in this module specifies the basic types of 'Config', and contains
all the code required to translate a raw 'ConfigToken' generated by a parse of a
configuration file into a valid 'Config' record.

-}
module KMonad.Core.Config
  ( -- * The basic types and lenses for 'Config' data
    -- $types
    Config(..)
  , ButtonMap
  , LayerMap
  , input, output, mappings, entry

    -- * Interpretation errors and MonadError context
    -- $errors
  , ConfigError
  , AsConfigError(..)
  , CanComp

    -- * Interpreting a 'ConfigToken'
    -- $interpret
  , interpret

    -- * Config IO
    -- $io
  , loadConfig
  , loadConfigToken
  )
where

import Control.Exception
import Control.Lens
import Control.Monad.Except
import Control.Monad.ST
import Data.Containers.ListUtils (nubOrd)
import Data.Foldable (toList)
import Data.Hashable
import Data.List ((\\))
import Data.Maybe
import Data.STRef

import KMonad.Core.KeyCode
import KMonad.Core.Matrix
import KMonad.Core.Parser.Token
import KMonad.Core.Parser.Utility
import KMonad.Core.Parser.Parsers.Config

import qualified Data.HashMap.Strict  as M
import qualified Data.Set             as S
import qualified Data.Text.Encoding   as T
import qualified Data.ByteString      as B


--------------------------------------------------------------------------------
-- $errors
--
-- Define all the things that can go wrong with reading a configuration

-- | The type of errors thrown by interpreting configurations
data ConfigError
  = NoSourceLayer
  | MultipleSourceLayer
  | NoButtonLayer
  | NoInputSource
  | MultipleInputSource
  | NoOutputSink
  | MultipleOutputSink
  | DuplicateAlias      Symbol
  | DuplicateInSource
  | ParseErrorFound     PError
  | AnchorNotFound      KeyCode Name
  | AlignmentError      Coor    ButtonSymbol Name
  | AliasNotFound       Symbol  Name
  | LayerNotFound       [Name]
  deriving Exception

instance Show ConfigError where
  show NoSourceLayer
    = "No SRC layer was provided"
  show MultipleSourceLayer
    = "Encountered multiple definitions of SRC layer"
  show NoButtonLayer
    = "No button layers defined"
  show NoInputSource
    = "No INPUT source provided"
  show MultipleInputSource
    = "Multiple INPUT source encountered"
  show NoOutputSink
    = "No OUTPUT sink provided"
  show MultipleOutputSink
    = "Multiple OUTPUT sinks encountered"
  show (DuplicateAlias k)
    = "Encountered multiple definitions for alias: " <> show k
  show DuplicateInSource
    = "Duplicate encountered in SRC layer"
  show (ParseErrorFound e)
    = show e
  show (AnchorNotFound k l)
    = concat
      [ "Cannot find anchor "
      , show k
      , " for layer "
      , show l
      ]
  show (AlignmentError c b l)
    = concat
      [ "Alignment Error: <"
      , show b
      , ">@"
      , show (c^._Wrapped')
      , " in layer: "
      , show l
      , " has no corresponding source entry."
      ]
  show (AliasNotFound s l)
    = concat
      [ "Alias "
      , show s
      , " not found in layer: "
      , show l
      ]
  show (LayerNotFound ks)
    = "Layer(s) not found: " <> show ks

-- | Classy Prisms used to speak generally about 'ConfigError's
makeClassyPrisms ''ConfigError

instance AsConfigError IOException where
  _ConfigError = prism' throw (const Nothing)

-- | The constraints required for a 'Monad' to deal with interpreting
-- configuration files as valid 'Config' data.
type CanComp e m = (MonadError e m, AsConfigError e)


--------------------------------------------------------------------------------
-- $types

-- | A correspondence between 'KeyCode's and 'ButtonToken's. The 'ButtonToken's
-- are later converted to concrete actions.
type ButtonMap = [(KeyCode, ButtonToken)]

-- | A correspondence between 'Name's and 'ButtonMap's.
type LayerMap = [(Name, ButtonMap)]

-- | The record containing all configuration options required to run KMonad
data Config = Config
  { _mappings :: LayerMap    -- ^ The 'LayerMap' describing the actual mapping
  , _input    :: InputToken  -- ^ A token describing how to get keys from the OS
  , _output   :: OutputToken -- ^ A token describing how to send keys to the OS
  , _entry    :: Name     -- ^ The 'Name' that should be loaded at start
  } deriving Show
makeClassy ''Config


--------------------------------------------------------------------------------
-- $interpret

-- | A collection of aliases
type Aliases = M.HashMap Symbol ButtonToken

-- | Turn a 'ConfigToken' into an actual 'Config'.
interpret :: CanComp e m => ConfigToken -> m Config
interpret (ConfigToken srcs lyrs alss is os)
  | null srcs        = throwError $ _NoSourceLayer       # ()
  | length srcs > 1  = throwError $ _MultipleSourceLayer # ()
  | null lyrs        = throwError $ _NoButtonLayer       # ()
  | null is          = throwError $ _NoInputSource       # ()
  | length is   > 1  = throwError $ _MultipleInputSource # ()
  | null os          = throwError $ _NoOutputSink        # ()
  | length os   > 1  = throwError $ _MultipleOutputSink  # ()
  | otherwise = do

      -- Turn aliases into a hashmap, checking for duplicates
      as <- case mkUniqMap $ map (\(AliasDef k v) -> (k, v)) alss of
              Left k   -> throwError $ _DuplicateAlias # k
              Right as -> pure as

      -- Extract source-layer from token, checking for duplicates
      let src = normalize . (\(SourceToken s) -> s) . head $ srcs
      when (length src /= (S.size . S.fromList . toList $ src)) $
        throwError $ _DuplicateInSource # ()

      -- extract maps from all the provided layers
      ls <- mapM (\l -> (l^.layerName,) <$> extractMap src as l) lyrs

      -- Extract layer names from aliases and button maps, checking for
      -- non-existent names
      let layerNames = nubOrd . concatMap getLayerName
            $ M.elems as ++ concatMap (map snd . snd) ls
          unknownNames = layerNames \\ map (^.layerName) lyrs
      unless (null unknownNames) $
        throwError $ _LayerNotFound # unknownNames

      pure $ Config
        { _mappings = ls
        , _input    = is !! 0
        , _output   = os !! 0
        , _entry    = (last $ lyrs) ^. layerName
        }

-- | Extract named layers of a given button token
getLayerName :: ButtonToken -> [Name]
getLayerName bToken =
  case bToken of
    BLayerAdd n     -> [n]
    BLayerRem n     -> [n]
    BLayerToggle n  -> [n]
    BTapHold _ b b' -> getLayerName b ++ getLayerName b'
    BTapNext b b'   -> getLayerName b ++ getLayerName b'
    BModded _ b     -> getLayerName b
    BMultiTap msb   -> concatMap (getLayerName . snd) msb
    _               -> []

-- | Coregister a matrix of buttons to the source matrix
extractMap :: CanComp e m
  => Matrix KeyCode -- ^ The SRC matrix to coregister to
  -> Aliases        -- ^ A collection of alias-definitions
  -> LayerToken     -- ^ The layertoken
  -> m ButtonMap
extractMap src as lt = do
      -- Adjust the margins of the provided matrix
      bm <- case adjustMargins (lt^.anchor) src (lt^.buttons) of
              Left  c -> throwError $ _AnchorNotFound # (c, lt^.layerName)
              Right m -> pure m
      
      -- Coregister the buttons to the source layer
      cr <- case overlay src bm of
              Left coor -> throwError $ _AlignmentError # (coor, fromJust $ bm^.at coor, lt^.layerName)
              Right c   -> pure c

      -- Dereference any aliases
      case mapM (\(c, s) -> fmap (fmap (c,)) $ derefAlias as s) cr of
        Right as' -> pure $ catMaybes as'
        Left  s   -> throwError $ _AliasNotFound # (s, lt^.layerName)

-- | Normalize matrix coordinates to remove margins and potentially anchor
adjustMargins
  :: Maybe KeyCode             -- ^ The anchor from the layer
  -> Matrix KeyCode            -- ^ The SRC matrix to coregister to
  -> Matrix a                  -- ^ The matrix of items to register
  -> Either KeyCode (Matrix a) -- ^ Either the keycode of the anchor that wasn't found or the shifted matrix
adjustMargins Nothing  _   m = Right $ normalize m
adjustMargins (Just a) src m = case anchorTo a src $ normalize m of
                                 Nothing -> Left  a
                                 Just m' -> Right m'

-- | Turn all button symbols into button tokens by dereferencing any button aliases
derefAlias
  :: Aliases                           -- ^ A collection of alias definitions
  -> ButtonSymbol                      -- ^ The symbol to dereference
  -> Either Symbol (Maybe ButtonToken) -- ^ Either a symbol-lookup that failed or a button-token
derefAlias _  (BSToken b) = Right . Just $ b
derefAlias _  Transparent = Right Nothing
derefAlias as (BSAlias (AliasRef s)) = case M.lookup s as of
  Nothing -> Left  s
  x       -> Right x

-- | Create a HashMap from a list of keys and values only if there are no
-- duplicate. If a duplicate is encountered, return it as a Left value.
mkUniqMap :: (Ord k, Hashable k)
  => [(k, v)] -> Either k (M.HashMap k v)
mkUniqMap xs = runST $ f xs =<< newSTRef M.empty
  where
    f []          mRef = Right <$> readSTRef mRef
    f ((k, v):xs') mRef = do
      m <- readSTRef mRef
      if M.member k m
        then return . Left $ k
        else modifySTRef' mRef (M.insert k v) >> f xs' mRef


--------------------------------------------------------------------------------
-- $io

-- | Load a configuration file and return a 'Config'
loadConfig :: (MonadIO m, CanComp e m) => FilePath -> m Config
loadConfig = loadConfigToken >=> interpret

-- | Load a configuration file and return a 'ConfigToken'
loadConfigToken :: MonadIO m => FilePath -> m ConfigToken
loadConfigToken pth = do
  bst <- liftIO $ B.readFile pth 
  pure . parseE configP . T.decodeUtf8 $ bst
  
