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
  , module Control.Monad.Trans.Class
  , module Control.Monad.Trans.Maybe
  , module Control.Monad.IO.Class
  , coerce
  , hoistMaybe
  ) where

import qualified Algorithm.Search.JumpPoint as JP
import           BasePrelude hiding (group, rotate, lazy, index, uncons, loop, inRange)
import           Control.Error.Util (hoistMaybe)
import           Control.Lens hiding (without, op)
import           Control.Monad.IO.Class (MonadIO (..))
import           Control.Monad.Reader.Class (MonadReader, ask)
import           Control.Monad.Trans.Class (lift)
import           Control.Monad.Trans.Maybe
import           Control.Monad.Trans.Reader (runReaderT)
import           Data.Coerce
import qualified Data.Ecstasy as E
import           Data.Ecstasy hiding (newEntity, createEntity)
import           Data.Ecstasy.Internal (surgery, getWorld)
import qualified Data.Ecstasy.Types as E
import qualified Data.IntMap.Internal as IMI
import qualified Data.IntMap.Strict as IM
import qualified Data.Map.Strict as M
import           Game.Sequoia hiding (form)
import           Game.Sequoia.Utils (showTrace)
import           Game.Sequoia.Window (MouseButton (..))
import           Linear (norm, normalize, (*^), (^*), quadrance, M22, project)
import           Linear.Matrix
import qualified Linear.V2 as L
import qualified QuadTree.QuadTree as QT
import           Types

get
    :: (MonadIO m, MonadReader (IORef LocalState) m)
    => m LocalState
get = gets id

gets
    :: (MonadIO m, MonadReader (IORef LocalState) m)
    => (LocalState -> a)
    -> m a
gets f = do
  ref <- ask
  fmap f. liftIO $ readIORef ref

modify
    :: (MonadIO m, MonadReader (IORef LocalState) m)
    => (LocalState -> LocalState) -> m ()
modify f = do
  ref <- ask
  liftIO $ modifyIORef ref f





nmIsOpen :: NavMesh -> (Int, Int) -> Bool
nmIsOpen = JP.isTileOpen


nmFind :: NavMesh -> (Int, Int) -> (Int, Int) -> Maybe [(Int, Int)]
nmFind = JP.findPath


newEntity :: EntWorld  'FieldOf
newEntity = E.newEntity
  { isAlive = Just ()
  , lifetime = Just 0
  , lastDir = Just $ V2 1 0
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
    -> IO ((LocalState, SystemState EntWorld Underlying), a)
runGame (gs, ss) m = do
  ref <- newIORef gs
  (ss', a) <- runReaderT (yieldSystemT ss m) ref
  gs' <- readIORef ref
  pure ((gs', ss'), a)


evalGame
    :: (LocalState, SystemState EntWorld Underlying)
    -> SystemT EntWorld Underlying a
    -> IO a
evalGame = fmap (fmap snd) . runGame


buttonLeft :: MouseButton
buttonLeft = ButtonExtra 0


buttonRight :: MouseButton
buttonRight = ButtonExtra 2


entsWith
    :: (Monad m, MonadIO m)
    => (w ('WorldOf m) -> IM.IntMap a)
    -> SystemT w m [Ent]
entsWith sel = do
  w <- getWorld
  pure . fmap E.Ent $ IM.keys $ sel w


aliveEnts :: (Monad m, MonadIO m) => SystemT EntWorld m [Ent]
aliveEnts = entsWith isAlive


fi :: (Num b, Integral a) => a -> b
fi = fromIntegral


toV2 :: (Int, Int) -> V2
toV2 = uncurry V2 . (fi *** fi)


traverseMaybeWithKey
    :: Monad m
    => (IMI.Key -> a -> m (Maybe b))
    -> IMI.IntMap a
    -> m (IMI.IntMap b)
traverseMaybeWithKey f (IMI.Bin p m l r) =
  IMI.bin p m <$> traverseMaybeWithKey f l
              <*> traverseMaybeWithKey f r
traverseMaybeWithKey f (IMI.Tip k x) =
  f k x >>= pure . \case
    Just y  -> IMI.Tip k y
    Nothing -> IMI.Nil
traverseMaybeWithKey _ IMI.Nil =
  pure IMI.Nil


pumpTasks :: Time -> Game ()
pumpTasks dt = do
  tasks  <- gets _lsTasks
  tasks' <- flip traverseMaybeWithKey tasks $ \_ task -> do
    z <- resume task
    pure $ case z of
      Left (Await f) -> Just $ f dt
      Right _        -> Nothing
  newTasks <- gets _lsNewTasks
  modify $ lsTasks .~ tasks' <> IM.fromList newTasks
  modify $ lsNewTasks .~ []


start :: Task () -> Game Int
start t = do
  i <- gets _lsTaskId
  modify $ lsNewTasks %~ ((i, t) :)
  modify $ lsTaskId +~ 1
  pure i


stop :: Int -> Game ()
stop i = modify $ lsTasks %~ IM.delete i


wait :: Time -> Task ()
wait t | t <= 0 = pure ()
       | otherwise = do
           dt <- await
           wait $ t - dt


runCommand :: IsCommand a => Ent -> a -> Task ()
runCommand e cmd = do
  dt <- await
  lift (pumpCommandImpl dt e cmd) >>=
    do traverse_ $ \cmd' -> runCommand e cmd'


waitUntil :: Game Bool -> Task ()
waitUntil what = do
  fix $ \f -> do
    void await
    finished <- lift what
    unless finished f


getUnitsInZone :: (Int, Int) -> Game [(Ent, V2)]
getUnitsInZone zone = do
  dyn <- gets _lsDynamic
  pure $ liftA2 (,) (view _1) (view _2) <$> QT.inZone dyn zone


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
  us <- getUnitsInRange p1 0
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
tileWidth = 32


tileHeight :: Num a => a
tileHeight = 32

halfTile :: V2
halfTile = V2 tileWidth tileHeight ^* 0.5


pumpSomeCommand
    :: Time
    -> Ent
    -> Command
    -> Game (Maybe Command)
pumpSomeCommand dt e (SomeCommand cmd) =
  fmap (fmap SomeCommand) $ pumpCommandImpl dt e cmd


updateCommands
    :: Time
    -> Game ()
updateCommands dt = do
  cmds <- efor allEnts $ (,) <$> queryEnt <*> query currentCommand
  for_ cmds $ \(e, cmd) -> do
    mcmd' <- pumpSomeCommand dt e cmd
    setEntity e unchanged
      { currentCommand = maybe Unset Set mcmd'
      }


issueInstant
    :: forall a
     . IsInstantCommand a
    => CommandParam a
    -> Ent
    -> Game ()
issueInstant param e =
  fromInstant @a param e >>= resolveAttempt e


issueLocation
    :: forall a
     . IsLocationCommand a
    => CommandParam a
    -> Ent
    -> V2
    -> Game ()
issueLocation param e v2 =
  fromLocation @a param e v2 >>= resolveAttempt e


issueUnit
    :: forall a
     . IsUnitCommand a
    => CommandParam a
    -> Ent
    -> Ent
    -> Game ()
issueUnit param e t =
  fromUnit @a param e t >>= resolveAttempt e


issuePlacement
    :: forall a
     . IsPlacementCommand a
    => CommandParam a
    -> Ent
    -> (Int, Int)
    -> Game ()
issuePlacement param e i =
  fromPlacement @a param e i >>= resolveAttempt e


resolveAttempt
    :: IsCommand a
    => Ent
    -> Attempt a
    -> Game ()
resolveAttempt e (Success cmd) = do
  (eon e $ query currentCommand) >>= \case
    Just (SomeCommand oldCmd) -> endCommand e $ Just oldCmd
    Nothing -> pure ()
  setEntity e unchanged
    { currentCommand = Set $ SomeCommand cmd
    }

resolveAttempt _ Attempted = pure ()
resolveAttempt _ (Failure err) = do
  _ <- pure $ showTrace err
  pure ()


attemptToMaybe :: Attempt a -> Maybe a
attemptToMaybe (Success a) = Just a
attemptToMaybe _ = Nothing


eon
    :: Ent
    -> QueryT EntWorld Underlying a
    -> SystemT EntWorld Underlying (Maybe a)
eon e = fmap listToMaybe . efor (anEnt e)


recomputeNavMesh :: Game ()
recomputeNavMesh = do
  nm <- gets $ mapNavMesh . _lsMap
  buildings <- efor aliveEnts $ do
    Building <- query unitType
    xy@(x, y) <- fmap (view $ from centerTileScreen) (query pos)
    (dx, dy)  <- query gridSize
    (,) <$> pure xy
        <*> pure (x + dx - 1, y + dy - 1)

  modify $ lsNavMesh .~ foldr (uncurry JP.closeArea) nm buildings


isPassiveCommand :: Commanding f -> Bool
isPassiveCommand (PassiveCommand _) = True
isPassiveCommand _ = False


getPassives :: Proto -> [Commanding Proxy2]
getPassives
  = maybe [] id
  . fmap (filter isPassiveCommand . fmap cwCommand)
  . commands


-- TODO(sandy): make this a hook
createEntity :: Proto -> Game Ent
createEntity p = do
  let ps = getPassives p
  e <- E.createEntity p
  sps' <- fmap catMaybes . for ps $
    \(PassiveCommand (Proxy2 param :: Proxy2 a ())) ->
      fromInstant @a param e >>= pure . \case
        Success a -> Just $ SomeCommand a
        _ -> Nothing

  setEntity e unchanged
    { activePassives = Set sps'
    , isAlive = Set ()
    }
  pure e


resetLimit :: Limit a -> Limit a
resetLimit (Limit _ b) = Limit b b


-- TODO(sandy): implement resources
acquireResources :: Player -> Resource -> Int -> Game ()
acquireResources _ _ _ = pure ()


findAnim :: FindAnim -> AnimBundle -> Maybe CannedAnim
findAnim anims bundle =
  getFirst $ foldMap (coerce . flip M.lookup bundle) anims


playAnim :: Ent -> FindAnim -> Game ()
playAnim e fs = void . runMaybeT $ do
  bundle <- MaybeT . eon e $ query animBundle
  a <- hoistMaybe $ findAnim fs bundle
  lift $ setEntity e unchanged
    { art = Set $ Art a 0
    }


isSameType
    :: forall (a :: *) (b :: *)
     . (Typeable a, Typeable b)
    => Bool
isSameType = maybe False (const True) $ eqT @a @b

isWidget :: forall a f. IsCommand a => Commanding f -> Bool
isWidget (LocationCommand  (_ :: f b V2))         = isSameType @a @b
isWidget (UnitCommand      (_ :: f b Ent))        = isSameType @a @b
isWidget (InstantCommand   (_ :: f b ()))         = isSameType @a @b
isWidget (PassiveCommand   (_ :: f b ()))         = isSameType @a @b
isWidget (PlacementCommand (_ :: f b (Int, Int))) = isSameType @a @b
-- TODO(sandy): should this look through the subcommands?
isWidget (MenuCommand _)                          = False


hasWidget :: forall a. IsCommand a => Ent -> Game Bool
hasWidget e = fmap (maybe False id) . runMaybeT $ do
  ws <- MaybeT . eon e $ query commands
  pure $ any (isWidget @a . cwCommand) ws


whenM :: Monad m => m Bool -> m () -> m ()
whenM c a = c >>= bool (pure ()) a


defSize :: Double
defSize = 10


pumpCommandImpl
    :: forall a
     . IsCommand a
    => Time
    -> Ent
    -> a
    -> Game (Maybe a)
pumpCommandImpl dt e a = do
  pumpCommand dt e a >>= \case
    z@Just{} -> pure z
    Nothing -> do
      endCommand @a e Nothing
      pure Nothing


getPointObstructions
    :: V2  -- ^ desired pos
    -> Double  -- ^ desired size
    -> Maybe Ent
    -> Game [(Ent, V2)]
getPointObstructions p s me = do
  qt <- gets _lsDynamic
  pure . filter ((/= me) . Just . fst)
       $ QT.inRange qt p s


isPointObstructed
    :: V2  -- ^ desired pos
    -> Double  -- ^ desired size
    -> Maybe Ent
    -> Game Bool
isPointObstructed p s me =
  not . null <$> getPointObstructions p s me


closestPointTo
    :: V2  -- ^ desired pos
    -> Double  -- ^ desired size
    -> V2  -- ^ try direction
    -> Game V2
closestPointTo p s dir = do
  isPointObstructed p s Nothing >>= \case
    False -> pure p
    True -> closestPointTo (p + dir ^* s) s dir


fromFlag :: Maybe () -> Bool
fromFlag = maybe False $ const True

rotV2 :: Double -> V2 -> V2
rotV2 theta v2 =
  L.V2 (L.V2 (cos theta)          (sin theta))
       (L.V2 (negate $ sin theta) (cos theta)) !* v2

