{-# LANGUAGE NoImplicitPrelude #-}

module GameData where

import AbilityUtils
import Overture
import Behavior


mePlayer :: Player
mePlayer = Player $ rgb 1 0 0


neutralPlayer :: Player
neutralPlayer = Player $ rgb 0.25 0.55 0.95


commandCenter :: Proto
commandCenter = newEntity
  { gfx            = Just $ toForm $ image "assets/cc.png"
  , gridSize       = Just (4, 3)
  , classification = Just BuildingUnit
  , unitType       = Just Building
  , hp             = Just $ Limit 100 100
  }


gunAttackData :: AttackData
gunAttackData = AttackData
  { _aCooldown = Limit 0 0.75
  , _aRange    = 75
  , _aClass    = [Nothing]
  , _aTask     = missile (missileEnt 300) $ \v2 t -> do
      doDamage Nothing 30 v2 t
      explosion v2 1 $ \d -> scale (d + 0.01)
                           . filled (rgba 1 0 0 $ 1 - d / 2)
                           . circle
                           $ 8 + d * 3
  }

psiStormWidget :: CommandWidget
psiStormWidget = CommandWidget
  { cwName = "Psi Storm"
  , cwCommand = LocationCommand $ Proxy2 @PsiStormCmd
  , cwVisible = True
  , cwHotkey = Just TKey
  }


moveWidget :: CommandWidget
moveWidget = CommandWidget
  { cwName = "Move"
  , cwCommand = LocationCommand $ Proxy2 @MoveCmd
  , cwVisible = True
  , cwHotkey = Just MKey
  }

attackWidget :: CommandWidget
attackWidget = CommandWidget
  { cwName = "Attack"
  , cwCommand = UnitCommand $ Proxy2 @AttackCmd
  , cwVisible = True
  , cwHotkey = Just AKey
  }

stopWidget :: CommandWidget
stopWidget = CommandWidget
  { cwName = "Stop"
  , cwCommand = InstantCommand $ Proxy2 @StopCmd
  , cwVisible = True
  , cwHotkey = Just SKey
  }

acquireWidget :: CommandWidget
acquireWidget = CommandWidget
  { cwName = "Acquire"
  , cwCommand = InstantCommand $ Proxy2 @AcquireCmd
  , cwVisible = False
  , cwHotkey = Nothing
  }

buildCommandCenterWidget :: CommandWidget
buildCommandCenterWidget = CommandWidget
  { cwName = "Build Command Center"
  , cwCommand = PlacementCommand commandCenter $ Proxy2 @BuildCmd
  , cwVisible = True
  , cwHotkey = Just CKey
  }

stdWidgets :: [CommandWidget]
stdWidgets = [moveWidget, stopWidget, attackWidget, acquireWidget]

