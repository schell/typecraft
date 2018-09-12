{-# LANGUAGE AllowAmbiguousTypes        #-}
{-# LANGUAGE ConstraintKinds            #-}
{-# LANGUAGE DeriveFoldable             #-}
{-# LANGUAGE DeriveFunctor              #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE DeriveTraversable          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE StrictData                 #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE UndecidableInstances       #-}

module Types
  ( module Types
  , await
  , resume
  , Await (..)
  , Key (..)
  , Schema
  ) where

import qualified Algorithm.Search.JumpPoint as JP
import           Control.Lens (makeLenses, makePrisms)
import           Control.Monad.Coroutine
import           Control.Monad.Coroutine.SuspensionFunctors
import           Control.Monad.Trans.Reader (ReaderT)
import           Data.Ecstasy
import           Data.IORef (IORef)
import qualified Data.IntMap.Strict as IM
import qualified Data.Map.Strict as M
import           Data.Spriter.Types
import qualified Data.Text as T
import           Data.Typeable
import           Game.Sequoia
import           Game.Sequoia.Keyboard
import           Game.Sequoia.Window (MouseButton (..))
import           QuadTree.QuadTree (QuadTree)


type NavMesh = JP.JumpGrid


data Map = Map
  { mapGeometry  :: !(Int -> Int -> Maybe Form)
  , mapDoodads   :: !(Int -> Int -> Maybe Form)
  , mapNavMesh   :: !(NavMesh)
  , mapWidth     :: {-# UNPACK #-} !(Int)
  , mapHeight    :: {-# UNPACK #-} !(Int)
  , mapSetup     :: Game ()
  }


data Mouse = Mouse
  { mDown    :: !(MouseButton -> Bool)
  , mUp      :: !(MouseButton -> Bool)
  , mPress   :: !(MouseButton -> Bool)
  , mUnpress :: !(MouseButton -> Bool)
  , mPos     :: {-# UNPACK #-} !V2
  }

data Keyboard = Keyboard
  { kPress   :: !(Key -> Bool)
  , kUnpress :: !(Key -> Bool)
  , kPresses :: ![Key]
  , kDown    :: !(Key -> Bool)
  , kUp      :: !(Key -> Bool)
  }


data LocalState = LocalState
  { _lsSelBox       :: !(Maybe V2)
  , _lsPlayer       :: {-# UNPACK #-} !Player
  , _lsTasks        :: !(IM.IntMap (Task ()))
  , _lsNewTasks     :: ![(Int, Task ())]
  , _lsTaskId       :: {-# UNPACK #-} !Int
  , _lsDynamic      :: !(QuadTree Ent Double)
  , _lsMap          :: {-# UNPACK #-} !Map
  , _lsNavMesh      :: !NavMesh
  , _lsCommandCont  :: !(Maybe WaitingForCommand)
  , _lsCamera       :: !V2
  , _lsExtraButtons :: !(Maybe [CommandWidget])
  }


data Limit a = Limit
  { _limVal :: !a
  , _limMax :: !a
  }
  deriving (Eq, Ord, Show, Functor, Foldable, Traversable)

instance Applicative Limit where
  pure a = Limit a a
  Limit fa fb <*> Limit a b = Limit (fa a) (fb b)


data AttackData = AttackData
  { _aCooldown :: {-# UNPACK #-} !(Limit Time)
  , _aRange    :: {-# UNPACK #-} !(Double)
  , _aClass    :: !([Maybe Classification])
  , _aTask     :: !(Ent -> Target -> Task ())
  }

type Underlying = ReaderT (IORef LocalState) IO
type Query = QueryT EntWorld Underlying


type Game = SystemT EntWorld Underlying
type Task = Coroutine (Await Time) Game


type Proto = EntWorld 'FieldOf
type Ability = Ent -> Target -> Task ()
type DamageHandler = V2 -> Target -> Game ()




data Target
  = TargetUnit Ent
  | TargetGround V2

data UnitType
  = Unit
  | Missile
  | Building
  deriving (Eq, Ord, Show, Bounded, Enum)

data Classification
  = GroundUnit
  | AirUnit
  | BuildingUnit
  deriving (Eq, Ord, Show, Bounded, Enum)

data MovementType
  = GroundMovement
  | AirMovement
  deriving (Eq, Ord, Show, Bounded, Enum)

data Player = Player
  { pColor :: !Color
  }
  deriving (Eq)


type Flag  f   = Component f 'Field ()
type Field f a = Component f 'Field a

data EntWorld f = World
  { acqRange       :: Field f Double
  , activePassives :: Field f [Command]
  , animBundle     :: Field f AnimBundle
  , art            :: Field f Art
  , attacks        :: Field f [AttackData]
  , classification :: Field f Classification
  , commands       :: Field f [CommandWidget]
  , currentCommand :: Field f Command
  , entSize        :: Component f 'Virtual Double
  , gfx            :: Field f Form
  , gridSize       :: Field f (Int, Int)
  , hp             :: Field f (Limit Int)
  , isAlive        :: Flag f
  , isDepot        :: Flag f
  , isFlying       :: Flag f
  , lastDir        :: Field f V2
  , lifetime       :: Field f Time
  , owner          :: Field f Player
  , pos            :: Component f 'Virtual V2
  , powerup        :: Field f (Resource, Int)
  , resourceSource :: Field f (Resource, Limit Int)
  , selected       :: Flag f
  , speed          :: Field f Double
  , unitType       :: Field f UnitType
  }
  deriving (Generic)

data Resource = Minerals
  deriving (Eq, Ord, Show)


type World = EntWorld ('WorldOf Underlying)

data Attempt a
  = Attempted
  | Failure String
  | Success a
  deriving (Eq, Ord, Show, Functor, Foldable, Traversable)

instance Applicative Attempt where
  pure = Success
  Success f <*> Success a = Success $ f a
  Failure e1 <*> Failure e2 = Failure $ e1 ++ "\n" ++ e2
  Failure err <*> _ = Failure err
  _ <*> Failure err = Failure err
  Attempted <*> _ = Attempted
  _ <*> Attempted = Attempted


class IsCommand a => IsLocationCommand a where
  fromLocation :: CommandParam a -> Ent -> V2 -> Game (Attempt a)

class IsCommand a => IsInstantCommand a where
  fromInstant :: CommandParam a -> Ent -> Game (Attempt a)

class IsCommand a => IsUnitCommand a where
  fromUnit :: CommandParam a -> Ent -> Ent -> Game (Attempt a)

class IsCommand a => IsPlacementCommand a where
  fromPlacement :: CommandParam a -> Ent -> (Int, Int) -> Game (Attempt a)


class Typeable a => IsCommand a where
  type CommandParam a
  type instance CommandParam a = ()
  pumpCommand
      :: Time
      -> Ent
      -> a
      -> Game (Maybe a)
  endCommand :: Ent -> Maybe a -> Game ()
  -- TODO(sandy): there is a reasonable impl of `playAnim e AnimIdle` here
  endCommand _ _ = pure ()

data Command where
  SomeCommand
      :: IsCommand a
      => a
      -> Command

instance IsCommand Command where
  pumpCommand dt e (SomeCommand a) =
    fmap SomeCommand <$> pumpCommand dt e a



data Commanding f where
  LocationCommand
      :: IsLocationCommand a
      => f a V2
      -> Commanding f
  UnitCommand
      :: IsUnitCommand a
      => f a Ent
      -> Commanding f
  InstantCommand
      :: IsInstantCommand a
      => f a ()
      -> Commanding f
  PassiveCommand
      :: IsInstantCommand a
      => f a ()
      -> Commanding f
  PlacementCommand
      :: IsPlacementCommand a
      => f a (Int, Int)
      -> Commanding f
  MenuCommand
      :: Maybe [CommandWidget]
      -> Commanding f

instance Show (Commanding f) where
  show (LocationCommand _)  = "LocationCommand"
  show (UnitCommand _)      = "UnitCommand"
  show (InstantCommand _)   = "InstantCommand"
  show (PassiveCommand _)   = "PassiveCommand"
  show (PlacementCommand _) = "PlacementCommand"
  show (MenuCommand _)      = "MenuCommand"

data Proxy2 a b = Proxy2
  { getCommandParam :: CommandParam a
  }

data GameCont a b = GameCont
  { commandParam :: CommandParam a
  , unTag :: b -> Game ()
  }

type Commander         = Commanding Proxy2
type WaitingForCommand = Commanding GameCont

data WidgetCol
  = Col1
  | Col2
  | Col3
  | Col4
  deriving (Eq, Ord, Show, Enum, Bounded)

data WidgetRow
  = Row1
  | Row2
  | Row3
  deriving (Eq, Ord, Show, Enum, Bounded)

data CommandWidget = CommandWidget
  { cwName    :: T.Text
  , cwCommand :: Commander
  , cwPos     :: Maybe (WidgetCol, WidgetRow)
  , cwHotkey  :: Maybe Key
  } deriving (Show)

data Art = Art
  { _aCanned :: CannedAnim
  , _aTime   :: Time
  } deriving (Eq)

data CannedAnim = CannedAnim
  { _aSchema    :: Schema
  , _aEntity    :: EntityName
  , _aAnim      :: AnimationName
  , _aSpeedMult :: Double
  , _aRepeat    :: Bool
  , _aScale     :: Double
  } deriving (Eq)


data AnimName
  = AnimIdle
  | AnimAttack
  | AnimWalk
  | AnimInstantSpell
  | AnimChannelSpell
  | AnimCustom String
  deriving (Eq, Ord, Show)

type AnimBundle = M.Map AnimName CannedAnim

type FindAnim = [AnimName]

makeLenses ''LocalState
makeLenses ''AttackData
makeLenses ''Limit
makeLenses ''Art
makeLenses ''CannedAnim

makePrisms ''UnitType

