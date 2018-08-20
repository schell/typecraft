{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Client
  ( run
  , gameWidth
  , gameHeight
  , loadWaiting
  ) where

import           Behavior
import           Control.FRPNow.Time (delayTime)
import           Data.Ecstasy.Types (SystemState (..), Hooks)
import qualified Data.Set as S
import           Game.Sequoia.Keyboard
import           Game.Sequoia.Window (mousePos, mouseButtons)
import           Overture hiding (init)


gameWidth :: Num t => t
gameWidth = 800


gameHeight :: Num t => t
gameHeight = 600


getMouse
    :: B (MouseButton -> Bool)
    -> B (MouseButton -> Bool)
    -> B (Int, Int)
    -> B Mouse
getMouse buttons oldButtons mouse = do
  mPos     <- toV2 <$> sample mouse
  mPress   <- sample $ (\b' b z -> b' z && not (b z)) <$> buttons <*> oldButtons
  mUnpress <- sample $ (\b' b z -> b' z && not (b z)) <$> oldButtons <*> buttons
  mDown    <- sample buttons
  let mUp = fmap not mDown
  pure Mouse {..}


getKB
    :: B [Key]
    -> B [Key]
    -> B Keyboard
getKB keys oldKeys = do
  kDowns    <- keys
  kLastDown <- oldKeys
  let kPress k   = elem k kDowns && not (elem k kLastDown)
      kUnpress k = elem k kLastDown && not (elem k kDowns)
      kPresses = S.toList $ S.fromList kDowns S.\\ S.fromList kLastDown
      kDown k = elem k kDowns
      kUp k = not $ elem k kDowns
  pure Keyboard {..}


run
    :: LocalState
    -> Hooks EntWorld Underlying
    -> Game ()
    -> (Mouse -> Keyboard -> Game ())
    -> (Time -> Game ())
    -> (Mouse -> Game [Form])
    -> N (B Element)
run realState hooks initialize player update draw = do
  clock    <- deltaTime <$> getClock

  keyboard <- do
    kb <- getKeyboard
    oldKb <- sample $ delayTime clock [] kb
    pure $ getKB kb oldKb

  mouseB <- do
    mb    <- mouseButtons
    oldMb <- sample $ delayTime clock (const False) mb
    mpos  <- mousePos
    pure $ getMouse mb oldMb mpos

  let world = defStorage
              { pos     = VTable vgetPos vsetPos
              , entSize = VTable vgetEntSize vsetEntSize
              }
      init = fst $ runGame (realState, (SystemState 0 world hooks)) initialize

  (game, _) <- foldmp init $ \state -> do
    -- arrs  <- sample $ arrows keyboard
    dt    <- sample clock
    kb    <- sample keyboard
    mouse <- sample mouseB

    pure $ fst $ runGame state $ do
      player mouse kb
      update dt

  pure $ do
    state <- sample game
    mouse <- sample mouseB

    pure . collage gameWidth gameHeight
         . evalGame state
         $ draw mouse


loadWaiting :: Commander -> Game ()
loadWaiting cmd = do
  sel <- getSelectedEnts
  case cmd of
    LocationCommand (Proxy2 :: Proxy2 a V2) ->
      modify $ lsCommandCont ?~ do
        LocationCommand . GameCont @a $ \v2 ->
          for_ sel $ \e -> issueLocation @a e v2

    UnitCommand (Proxy2 :: Proxy2 a Ent) ->
      modify $ lsCommandCont ?~ do
        UnitCommand . GameCont @a $ \t ->
          for_ sel $ \e -> issueUnit @a e t

    InstantCommand (_ :: Proxy2 a ()) -> do
      for_ sel $ issueInstant @a

    PlacementCommand proto (Proxy2 :: Proxy2 a (Int, Int)) ->
      modify $ lsCommandCont ?~ do
        PlacementCommand proto . GameCont @a $ \i ->
          for_ sel $ \e -> issuePlacement @a e i proto

