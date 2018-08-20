{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveFunctor      #-}
{-# LANGUAGE FlexibleContexts   #-}
{-# LANGUAGE LambdaCase         #-}
{-# LANGUAGE NoImplicitPrelude  #-}
{-# LANGUAGE TemplateHaskell    #-}

module Behavior where

import Overture
import AbilityUtils

data PsiStormCmd = PsiStormCmd V2
  deriving Typeable

data MoveCmd = MoveCmd [V2]
  deriving (Typeable)

data StopCmd = StopCmd
  deriving (Typeable)

data AttackCmd = AttackCmd
  { _acIx     :: Int
  , _acTarget :: Ent
  , _acPath   :: Maybe (V2, MoveCmd)
  , _acRepath :: Time
  } deriving (Typeable)

data AcquireCmd = AcquireCmd
  { _aqAttack :: AttackCmd
  , _aqPos    :: V2
  , _aqDist   :: Double
  } deriving (Typeable)

data BuildCmd = BuildCmd
  { _bcProto :: Proto
  , _bcPos   :: V2
  , _bcMove  :: Maybe MoveCmd
  } deriving (Typeable)


makeLenses ''AttackCmd
makeLenses ''AcquireCmd
makeLenses ''BuildCmd

instance IsPlacementCommand BuildCmd where
  fromPlacement e i proto = do
    Just src <- eon e $ query pos
    let dst = i ^. centerTileScreen
    findPath src dst >>= pure . \case
      Just pp -> Success $ BuildCmd proto dst . Just $ MoveCmd pp
      Nothing -> Failure "Unable to get to building location"

instance IsCommand BuildCmd where
  pumpCommand dt e bc@BuildCmd{..} = case _bcMove of
    Just cmd -> do
      cmd' <- pumpCommand dt e cmd
      pure $ Just $ bc & bcMove .~ cmd'

    Nothing -> do
      Just o <- eon e $ query owner
      void . createEntity $ _bcProto
        { pos   = Just _bcPos
        , owner = Just o
        }
      pure Nothing

instance IsLocationCommand PsiStormCmd where
  fromLocation _ = pure . pure . PsiStormCmd

instance IsCommand PsiStormCmd where
  pumpCommand _ _ (PsiStormCmd v2) = do
    start $ do
      let size       = 100
          dmg        = 100
          flashTime  = 0.1
          waitPeriod = 0.75
          cycles     = 4

      let add  = V2 size size ^* 0.5
          p1   = v2 - add
          p2   = v2 + add
          form = rect size size

      lift . explosion v2 (waitPeriod * cycles)
          . const
          $ filled (rgba 0 0.8 1 0.3) form
      for_ [0 .. cycles - 1] . const $ do
        wait waitPeriod
        lift $ do
          explosion v2 flashTime
            . const
            $ filled (rgb 0 0.8 1) form
          inRange <- getUnitsInSquare p1 p2
          eover (someEnts inRange)
            . fmap ((),)
            $ performDamage dmg
    pure Nothing

instance IsInstantCommand AcquireCmd where
  fromInstant e = do
    Just (p, acq, o) <-
      eon e $ (,,) <$> query pos
                   <*> query acqRange
                   <*> query owner
    badGuys <- efor (fmap fst <$> getUnitsInRange p acq) $ do
        o' <- query owner
        guard $ isEnemy o o'
        (,) <$> queryEnt
            <*> query pos
    let bads = sortBy (comparing $ quadrance . (p - ) . snd) badGuys
    -- TODO(sandy): check to make sure you can attack this guy!
    case listToMaybe bads of
      Just (t, _) -> do
        fromUnit @AttackCmd e t >>= \case
          Success atk -> pure $ pure $ AcquireCmd atk p acq
          _ -> pure Attempted

      Nothing -> pure Attempted

instance IsCommand AcquireCmd where
  pumpCommand dt e aq@AcquireCmd{..} = do
    Just p <- eon e $ query pos
    case fastInRange (p - _aqPos) _aqDist of
      True ->
        pumpCommand dt e _aqAttack >>= pure . \case
          Just acmd' -> Just $ aq & aqAttack .~ acmd'
          Nothing    -> Nothing
      False -> pure Nothing



isEnemy :: Player -> Player -> Bool
isEnemy = (/=)


biggestDude :: Num t => t
biggestDude = 10

sqr :: Num a => a -> a
sqr x = x * x

instance IsLocationCommand MoveCmd where
  fromLocation e g = do
    [p] <- efor (anEnt e) $ query pos
    mpp <- findPath p g
    pure $ case mpp of
      Just pp -> Success $ MoveCmd pp
      Nothing -> Attempted

instance IsCommand MoveCmd where
  pumpCommand _ _ (MoveCmd []) = pure Nothing
  pumpCommand dt e (MoveCmd gg@(g:gs)) = do
    [gg'] <- eover (anEnt e) $ do
      (notThereYet, p) <- moveTowards dt g

      pure . (bool gs gg notThereYet, ) $ unchanged
        { pos = Set p
        }
    pure . Just $ MoveCmd gg'


instance IsInstantCommand StopCmd where
  fromInstant _ = pure $ pure StopCmd

instance IsCommand StopCmd where
  pumpCommand _ _ _ = pure Nothing


matches :: Eq a => Maybe a -> Maybe a -> Bool
matches a b = maybe True id $ (==) <$> a <*> b

acRepathTime :: Time
acRepathTime = 0.2


instance IsUnitCommand AttackCmd where
  fromUnit e t = do
    mas <- eon e $ query attacks
    case mas of
      Nothing -> pure $ Failure "No attackdata!"
      Just as -> do
        c <- eon t $ query classification
        case listToMaybe . filter (any (matches c) . _aClass . fst)
                         $ zip as [0..] of
          Just (_, ixx) ->
            pure . pure $ AttackCmd ixx t Nothing 0
          Nothing  -> pure . Failure $ "Unable to attack" ++ show c

instance IsCommand AttackCmd where
  pumpCommand dt e ac@AttackCmd{..} = do
    let t = _acTarget
    eon t (with isAlive >> query pos) >>= \case
      Nothing -> pure Nothing
      Just tp -> do
        -- get attackdata
        Just (p, a) <- eon e $
          (,) <$> query pos <*> query (fmap (!! _acIx) . attacks)

        let cooldown' = a ^. aCooldown.limVal - dt
            rng       = a ^. aRange

        case fastInRange (p - tp) rng of
          -- if in range
          True -> do
            let refresh    = cooldown' < 0
                cooldown'' = bool cooldown' (a ^. aCooldown.limMax) refresh
                action     = bool Nothing (Just $ _aTask a e (TargetUnit t)) refresh
            for_ action start
            emap (anEnt e) $ do
              as <- query attacks
              pure unchanged
                { attacks = Set $ as & ix _acIx . aCooldown.limVal .~ cooldown''
                }
            pure . Just $
              ac & acPath .~ Nothing

          -- not in range
          False -> do
            -- needs to repath
            case (isNothing _acPath
                || (_acRepath <= 0
                 && not (fastInRange (fst (fromJust _acPath) - tp) rng))) of
              True -> do
                fromLocation @MoveCmd e tp >>= \case
                  Success mcmd ->
                    pure . Just $ ac & acPath   ?~ (tp, mcmd)
                                     & acRepath .~ acRepathTime
                  _ -> pure Nothing

              -- has a path
              False -> do
                Just (g, mcmd) <- pure _acPath
                mcmd' <- pumpCommand dt e mcmd
                pure . Just $ ac & acPath .~ fmap (g,) mcmd'
                                 & acRepath -~ dt

fastInRange :: V2 -> Double -> Bool
fastInRange dst rng = quadrance dst <= rng * rng


findPath :: MonadState LocalState m => V2 -> V2 -> m (Maybe [V2])
findPath src dst = do
  nm <- gets _lsNavMesh
  let dst' = dst ^. from centerTileScreen
      thepath = nmFind nm (src ^. from centerTileScreen)
                          dst'
  pure $ if nmIsOpen nm dst'
     then thepath <&> fmap ((+ halfTile) . view centerTileScreen)
     else Nothing


moveTowards :: Time -> V2 -> Query (Bool, V2)
moveTowards dt g = do
  p <- query pos
  s <- query speed

  let dir = g - p
      dist = norm dir
      dx = s * dt

  pure (dx < dist, p + dx *^ normalize dir)


setOrder :: Command -> EntWorld 'SetterOf
setOrder o = unchanged
  { currentCommand   = Set o
  }


getSelectedEnts :: Game [Ent]
getSelectedEnts = efor aliveEnts $
  with selected *> queryEnt

