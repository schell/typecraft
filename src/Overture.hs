{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE NoImplicitPrelude   #-}
{-# LANGUAGE RankNTypes          #-}

module Overture
  ( module Types
  , module BasePrelude
  , module Game.Sequoia
  , module Game.Sequoia.Utils
  , module Control.Lens
  , module Overture
  , module Data.Ecstasy
  , module Linear
  , module Game.Sequoia.Window
  , module Control.Monad.State.Class
  , module Control.Monad.Trans.Class
  , coerce
  , biplate
  ) where

import           BasePrelude hiding (group, rotate, lazy, index, uncons, loop, inRange)
import           Control.Lens hiding (without)
import           Data.Data.Lens (biplate)
import           Control.Monad.State.Class (MonadState, get, gets, put, modify)
import           Control.Monad.State.Strict (runState)
import           Control.Monad.Trans.Class (lift)
import           Data.Coerce
import qualified Data.Ecstasy as E
import           Data.Ecstasy hiding (newEntity)
import           Data.Ecstasy.Internal (surgery)
import qualified Data.Ecstasy.Types as E
import qualified Data.IntMap.Strict as IM
import           Game.Sequoia hiding (form)
import           Game.Sequoia.Utils (showTrace)
import           Game.Sequoia.Window (MouseButton (..))
import           Linear (norm, normalize, (*^), (^*), quadrance, M22)
import qualified QuadTree.QuadTree as QT
import           Types


unitScript :: Ent -> Task a -> Task ()
unitScript ent f = fix $ \loop -> do
  z <- lift . runQueryT ent $ query isAlive
  for_ z . const $ do
    void f
    loop


newEntity :: EntWorld  'FieldOf
newEntity = E.newEntity
  { isAlive = Just ()
  }


canonicalizeV2 :: V2 -> V2 -> (V2, V2)
canonicalizeV2 v1@(V2 x y) v2@(V2 x' y')
    | liftV2 (<=) v1 v2 = (v1, v2)
    | liftV2 (<=) v2 v1 = (v2, v1)
    | otherwise = canonicalizeV2 (V2 x y') (V2 x' y)


liftV2 :: (Double -> Double -> Bool) -> V2 -> V2 -> Bool
liftV2 f (V2 x y) (V2 x' y') = f x x' && f y y'


boolMonoid :: Monoid m => Bool -> m -> m
boolMonoid = flip (bool mempty)


runGame
    :: (LocalState, SystemState EntWorld Underlying)
    -> SystemT EntWorld Underlying a
    -> ((LocalState, SystemState EntWorld Underlying), a)
runGame (gs, ss) m =
  let ((a, b), c) = flip runState gs $ yieldSystemT ss m
   in ((c, a), b)


evalGame
    :: (LocalState, SystemState EntWorld Underlying)
    -> SystemT EntWorld Underlying a
    -> a
evalGame = (snd .) . runGame


buttonLeft :: MouseButton
buttonLeft = ButtonExtra 0


buttonRight :: MouseButton
buttonRight = ButtonExtra 2


entsWith
    :: Monad m
    => (w ('WorldOf m) -> IM.IntMap a)
    -> SystemT w m [Ent]
entsWith sel = do
  w <- fmap snd $ E.SystemT get
  pure . fmap E.Ent $ IM.keys $ sel w


aliveEnts :: Monad m => SystemT EntWorld m [Ent]
aliveEnts = entsWith isAlive


fi :: (Num b, Integral a) => a -> b
fi = fromIntegral


toV2 :: (Int, Int) -> V2
toV2 = uncurry V2 . (fi *** fi)


pumpTasks :: Time -> Game ()
pumpTasks dt = do
  tasks  <- gets _lsTasks
  modify $ lsTasks .~ []
  tasks' <- fmap catMaybes . for tasks $ \task -> do
    z <- resume task
    pure $ case z of
      Left (Await f) -> Just $ f dt
      Right _        -> Nothing
  modify $ lsTasks <>~ tasks'


start :: Task () -> Game ()
start t = modify $ lsTasks %~ (t :)


vgetPos :: Ent -> Underlying (Maybe V2)
vgetPos e = do
  dyn <- gets _lsDynamic
  pure $ QT.getLoc dyn e


vsetPos :: Ent -> Update V2 -> Underlying ()
vsetPos e (Set p) = modify $ lsDynamic %~ \qt -> QT.move qt e p
vsetPos e Unset = modify $ lsDynamic %~ \qt -> QT.remove qt e
vsetPos _ Keep = pure ()


vgetEntSize :: Ent -> Underlying (Maybe Double)
vgetEntSize e = do
  dyn <- gets _lsDynamic
  pure $ QT.getSize dyn e


vsetEntSize :: Ent -> Update Double -> Underlying ()
vsetEntSize e (Set x) = modify $ lsDynamic %~ \qt -> QT.setSize qt e x
vsetEntSize e Unset = modify $ lsDynamic %~ \qt -> QT.removeSize qt e
vsetEntSize _ Keep = pure ()


wait :: Time -> Task ()
wait t | t <= 0 = pure ()
       | otherwise = do
           dt <- await
           wait $ t - dt


waitUntil :: Game Bool -> Task ()
waitUntil what = do
  fix $ \f -> do
    void await
    finished <- lift what
    unless finished f


getUnitsInZone :: (Int, Int) -> Game [(Ent, V2)]
getUnitsInZone zone = do
  dyn <- gets _lsDynamic
  pure $ QT.inZone dyn zone


getUnitsInRange :: V2 -> Double -> Game [(Ent, Double)]
getUnitsInRange v2 rng = do
  dyn <- gets _lsDynamic
  let ents = QT.inRange dyn v2 rng
  pure $ fmap (second $ norm . (v2-)) ents


getUnitsInSquare :: V2 -> V2 -> Game [Ent]
getUnitsInSquare p1 p2 = do
  let r = canonicalizeV2 p1 p2
  dyn <- gets _lsDynamic
  let ents = QT.inRect dyn r
  pure $ fmap fst ents


getUnitAtPoint :: V2 -> Game (Maybe Ent)
getUnitAtPoint p1 = do
  -- TODO(sandy): yucky; don't work for big boys
  us <- getUnitsInRange p1 10
  pure . fmap fst
       . listToMaybe
       $ sortBy (comparing snd) us


during :: Time -> (Double -> Task ()) -> Task ()
during dur f = do
  flip fix 0 $ \loop total -> do
    f $ total / dur
    dt <- await
    let total' = total + dt
    when (total' < dur) $ loop total'


withinV2 :: V2 -> V2 -> Double -> Bool
withinV2 p1 p2 d =
  let qd = quadrance $ p1 - p2
      d1 = d * d
   in qd <= d1


centerTileScreen :: Iso' (Int, Int) V2
centerTileScreen = iso toScreen fromScreen
  where
    toScreen :: (Int, Int) -> V2
    toScreen (fromIntegral -> x, fromIntegral -> y) =
      V2 (x * tileWidth) (y * tileHeight)

    fromScreen :: V2 -> (Int, Int)
    fromScreen (V2 x y) =
      (floor $ x / tileWidth, floor $ y / tileHeight)


tileWidth :: Num a => a
tileWidth = 16


tileHeight :: Num a => a
tileHeight = 16

halfTile :: V2
halfTile = V2 tileWidth tileHeight ^* 0.5


pumpSomeCommand
    :: Time
    -> Ent
    -> Command
    -> Game (Maybe Command)
pumpSomeCommand dt e (SomeCommand cmd) =
  fmap (fmap SomeCommand) $ pumpCommand dt e cmd


updateCommands
    :: Time
    -> Game ()
updateCommands dt = do
  cmds <- efor allEnts $ (,) <$> queryEnt <*> query currentCommand
  for_ cmds $ \(e, cmd) -> do
    mcmd' <- pumpSomeCommand dt e cmd
    emap (anEnt e) $ pure unchanged
      { currentCommand = maybe Unset Set mcmd'
      }


issueInstant :: forall a. IsInstantCommand a => Ent -> Game ()
issueInstant e = fromInstant @a e >>= resolveAttempt e

issueLocation :: forall a. IsLocationCommand a => Ent -> V2 -> Game ()
issueLocation e v2 = fromLocation @a e v2 >>= resolveAttempt e

issueUnit :: forall a. IsUnitCommand a => Ent -> Ent -> Game ()
issueUnit e t = fromUnit @a e t >>= resolveAttempt e


resolveAttempt
    :: IsCommand a
    => Ent
    -> Attempt a
    -> Game ()
resolveAttempt e (Success cmd) = do
  emap (anEnt e) $ pure unchanged
    { currentCommand = Set $ SomeCommand cmd }
resolveAttempt _ Attempted = pure ()
resolveAttempt _ (Failure err) = do
  _ <- pure $ showTrace err
  pure ()


fromAttempt :: forall a. Typeable a => Attempt a -> a
fromAttempt (Success a) = a
fromAttempt _ = error $ mconcat
  [ "fromAttempt failed (for type "
  , show . typeRep $ Proxy @a
  , ")"
  ]


eon
    :: Ent
    -> QueryT EntWorld Underlying a
    -> SystemT EntWorld Underlying (Maybe a)
eon e = fmap listToMaybe . efor (anEnt e)

