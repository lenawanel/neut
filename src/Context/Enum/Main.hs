module Context.Enum.Main
  ( new,
  )
where

import Context.Enum
import qualified Context.Throw as Throw
import Control.Monad
import qualified Data.HashMap.Lazy as Map
import Data.IORef
import qualified Data.Text as T
import Entity.EnumInfo hiding (new)
import Entity.Global
import qualified Entity.Hint as Hint

new :: Throw.Context -> IO Axis
new axis = do
  enumEnvRef <- newIORef $ Map.fromList defaultEnumEnv
  revEnumEnvRef <- newIORef $ Map.fromList $ transpose defaultEnumEnv
  return
    Axis
      { register = _register axis enumEnvRef revEnumEnvRef,
        lookupType = _lookupType enumEnvRef,
        lookupValue = _lookupValue revEnumEnvRef
      }

type EnumEnv = Map.HashMap T.Text [EnumItem]

type RevEnumEnv = Map.HashMap T.Text (T.Text, Integer)

_register ::
  Throw.Context ->
  IORef EnumEnv ->
  IORef RevEnumEnv ->
  Hint.Hint ->
  EnumTypeName ->
  [EnumItem] ->
  IO ()
_register axis enumEnvRef revEnumEnvRef hint typeName enumItemList = do
  enumEnv <- readIORef enumEnvRef
  when (Map.member typeName enumEnv) $ do
    Throw.raiseError axis hint $ "the enum `" <> typeName <> "` is already defined"
  modifyIORef' enumEnvRef $ Map.insert typeName enumItemList
  let (labels, discriminants) = unzip enumItemList
  let rev = Map.fromList $ zip labels (zip (repeat typeName) discriminants)
  modifyIORef' revEnumEnvRef $ Map.union rev

_lookupType :: IORef EnumEnv -> EnumTypeName -> IO (Maybe [EnumItem])
_lookupType enumEnvRef typeName = do
  enumEnv <- readIORef enumEnvRef
  return $ Map.lookup typeName enumEnv

_lookupValue :: IORef RevEnumEnv -> EnumValueName -> IO (Maybe (EnumTypeName, Discriminant))
_lookupValue revEnumEnvRef valueName = do
  revEnumEnv <- readIORef revEnumEnvRef
  return $ Map.lookup valueName revEnumEnv

transpose :: [(T.Text, [(T.Text, Integer)])] -> [(T.Text, (T.Text, Integer))]
transpose =
  concatMap transpose'

transpose' :: (T.Text, [(T.Text, Integer)]) -> [(T.Text, (T.Text, Integer))]
transpose' (typeName, enumItemList) = do
  let (labels, discriminants) = unzip enumItemList
  zip labels (zip (repeat typeName) discriminants)

defaultEnumEnv :: [(EnumTypeName, [EnumItem])]
defaultEnumEnv =
  [ (constBottom, []),
    (constTop, [(constTopUnit, 0)]),
    (constBool, [(constBoolFalse, 0), (constBoolTrue, 1)])
  ]
