module Elman where

import Array exposing (Array)
import Bitwise
import Color exposing (Color)
import Graphics.Collage as Collage exposing (Form)
import Graphics.Element as Element exposing (Element)
import Keyboard
import Random
import Signal exposing ((<~), (~))
import Signals
import Text
import Time exposing (Time)
import XY exposing (XY, (|*), (|*|), (|-|), (|+|), (|<|))
import StateM exposing (StateM, (>>=), (>>.), (>=>), (:=), (:>))
import Lens exposing (Lens, (=>))

--------------------------------------------------------------------------------

gameDim: Dir
gameDim = {x = 960, y = 540} |* 0.5

backColor: Color
backColor = Color.rgb 255 160 214

--------------------------------------------------------------------------------

type alias Pos = XY Float
type alias Dir = XY Float

--------------------------------------------------------------------------------

type Event
  = Arrows Dir
  | Space Bool
  | Tick Time

--------------------------------------------------------------------------------

type alias Play =
  { player: Player
  , ghosts: List Ghost
  , berries: List Berry
  , score: Int
  , lives: Int
  , tick: Int
  , seed: Random.Seed
  , level: Int }

type alias Died =
  { score: Int }

type State
  = InitSt
  | PlaySt Play
  | DiedSt Died

type alias Player = Pos' (Dim' (Rot' (Form' (Spd' {}))))
type alias Ghost = Pos' (Dim' (Rot' (Form' (Spd' {nextAt: Int}))))
type alias Berry = Pos' (Dim' (Rot' (Form' {})))

type alias Pos' r = {r | pos: Pos}
type alias Dim' r = {r | dim: Dir}
type alias Spd' r = {r | spd: Dir}
type alias Form' r = {r | form: Maybe Form}
type alias Rot' r = {r | rot: Float}

--------------------------------------------------------------------------------

playerL: Lens {r | player: player} player
playerL = {get = .player, set = \r x -> {r | player <- x}}

ghostsL: Lens {r | ghosts: ghosts} ghosts
ghostsL = {get = .ghosts, set = \r x -> {r | ghosts <- x}}

berriesL: Lens {r | berries: berries} berries
berriesL = {get = .berries, set = \r x -> {r | berries <- x}}

scoreL: Lens {r | score: score} score
scoreL = {get = .score, set = \r x -> {r | score <- x}}

tickL: Lens {r | tick: tick} tick
tickL = {get = .tick, set = \r x -> {r | tick <- x}}

levelL: Lens {r | level: level} level
levelL = {get = .level, set = \r x -> {r | level <- x}}

livesL: Lens {r | lives: lives} lives
livesL = {get = .lives, set = \r x -> {r | lives <- x}}

seedL: Lens {r | seed: seed} seed
seedL = {get = .seed, set = \r x -> {r | seed <- x}}

formL: Lens {r | form: form} form
formL = {get = .form, set = \r x -> {r | form <- x}}

posL: Lens {r | pos: pos} pos
posL = {get = .pos, set = \r x -> {r | pos <- x}}

rnd: Random.Generator x -> StateM {s | seed: Random.Seed} x
rnd xG =
  StateM.get seedL >>=
  Random.generate xG >> \(x, s) ->
  seedL := s >>= \() ->
  StateM.return x

--------------------------------------------------------------------------------

wrapPos: Pos -> Pos
wrapPos =
  gameDim
  |> XY.zipWith (\d x ->
     if | x < -d -> x + 2 * d
        | d < x  -> x - 2 * d
        | otherwise -> x)

wrappedPos: Pos' (Dim' r) -> List (Pos' (Dim' r))
wrappedPos r =
  let min = r.pos |-| r.dim
      max = r.pos |+| r.dim in
  if max |<| gameDim &&
     XY.neg gameDim |<| min then
    [ r ]
  else
    let sign x = if | x < 0 -> -1
                    | x > 0 -> 1
                    | otherwise -> 0
        x = sign r.pos.x * -2
        y = sign r.pos.y * -2
        mk x y = {r | pos <- r.pos |+| (gameDim |*| {x = x, y = y})} in
    [ mk 0 0, mk x 0, mk 0 y, mk x y ]

--------------------------------------------------------------------------------

playerForms: Array Form
playerForms =
  [ "web/gfx/Elman-0.png"
  , "web/gfx/Elman-1.png"
  , "web/gfx/Elman-2.png"
  , "web/gfx/Elman-1.png" ]
 |> List.map (Element.image 32 32 >> Collage.toForm) |> Array.fromList

--------------------------------------------------------------------------------

init: State
init = InitSt

--------------------------------------------------------------------------------

updateArrowsM: Dir -> StateM Play ()
updateArrowsM dir =
  StateM.upd playerL <| \player ->
  { player
  | spd <- dir |* 4
  , rot <- if dir.x == 0 && dir.y == 0
           then player.rot
           else atan2 -dir.y -dir.x}

--

berryForm: Form
berryForm = Element.image 32 32 "web/gfx/Strawberry.png" |> Collage.toForm

ghostForms: Array Form
ghostForms =
  [ "web/gfx/Ghost-Green-0.png"
  , "web/gfx/Ghost-Green-1.png"
  , "web/gfx/Ghost-Green-2.png"
  , "web/gfx/Ghost-Green-3.png" ]
 |> List.map (Element.image 32 32 >> Collage.toForm) |> Array.fromList

updateLevelM: StateM Play ()
updateLevelM =
  StateM.getState >>= \{berries, level} ->
  List.isEmpty berries `StateM.when` \() ->
     let gxys = Random.pair
                  (Random.float -gameDim.x gameDim.x)
                  (Random.float -gameDim.y gameDim.y)
                |> Random.list level in
     rnd gxys >>= \berryXYs ->
     rnd gxys >>= \ghostXYs ->
     let berry (x, y) =
           { pos = {x = x, y = y}
           , dim = {x = 16, y = 16}
           , form = Just berryForm
           , rot = 0 }
         ghost (x, y) =
           { pos = {x = x, y = y}
           , spd = {x = 0, y = 0}
           , dim = {x = 16, y = 16}
           , rot = 0
           , form = Nothing
           , nextAt = 10 } in
     StateM.upd levelL ((+) 1) >>.
     berriesL := (berryXYs |> List.map berry) >>.
     ghostsL := (ghostXYs |> List.map ghost)

--

updateTickM: StateM Play ()
updateTickM = tickL :> (+) 1

--

updatePhysical: Pos' (Spd' r) -> Pos' (Spd' r)
updatePhysical p =
  { p | pos <- wrapPos (p.pos |+| p.spd) }

updatePhysicsM: StateM Play ()
updatePhysicsM =
  playerL :> updatePhysical >>.
  ghostsL :> List.map updatePhysical

--

updatePlayerM: StateM Play ()
updatePlayerM =
  StateM.getState >>= \{player, tick, ghosts} ->
  let wrapped = wrappedPos player in
  playerL => formL := (let n = Array.length playerForms in
                       Array.get (tick // 4 % n) playerForms) >>.
  (ghosts
   |> List.any (\ghost -> List.any (collides ghost) wrapped)) `StateM.when` \() ->
    livesL :> (+) -1 >>.
    playerL => posL := {x = 0, y = 0}

--

collides: Pos' (Dim' l) -> Pos' (Dim' r) -> Bool
collides l r =
  XY.norm (l.pos |-| r.pos) < 16*16

updateBerriesM: StateM Play ()
updateBerriesM =
  StateM.getState >>= \{player} ->
  let players = wrappedPos player in
  StateM.updM berriesL <| StateM.filterM <| \berry ->
  if List.any (collides berry) players
  then scoreL :> (+) 1 >>.
       StateM.return False
  else StateM.return True

--

updateGhostsM: StateM Play ()
updateGhostsM =
  StateM.getState >>= \{player, tick} ->
  StateM.updM ghostsL <| StateM.mapM <| \g ->
  let form = ghostForms
             |> Array.get (Bitwise.xor
                            (if player.pos.x < g.pos.x then 0 else 1)
                            (if player.pos.y < g.pos.y then 0 else 3)) in
  if tick < g.nextAt then
    { g | form <- form } |> StateM.return
  else
    Random.int 0 3 |> rnd >>= \d ->
    Random.int 20 50 |> rnd >>= \t ->
    Random.float 1 6 |> rnd >>= \s ->
    { g
    | nextAt <- tick + t
    , form <- form
    , spd <- if | d == 0    -> {x =-s, y = 0}
                | d == 1    -> {x = 0, y =-s}
                | d == 2    -> {x = s, y = 0}
                | otherwise -> {x = 0, y = s} } |> StateM.return

--



update: Event -> State -> State
update input state =
  case state of
    InitSt ->
      case input of
        Space _ ->
          PlaySt { player = { pos = {x = 0, y = 0}
                            , spd = {x = 0, y = 0}
                            , dim = {x = 16, y = 16}
                            , rot = 0
                            , form = Nothing }
                 , ghosts = []
                 , berries = []
                 , score = 0
                 , lives = 3
                 , tick = 0
                 , seed = Random.initialSeed 3141592
                 , level = 5 }
        _ ->
          InitSt
    PlaySt play ->
      play
      |> StateM.run (case input of
                       Space _ ->
                         StateM.return ()
                       Arrows dir ->
                         updateArrowsM dir
                       Tick _  ->
                         updateLevelM
                         >>. updateTickM
                         >>. updatePlayerM
                         >>. updateGhostsM
                         >>. updatePhysicsM
                         >>. updateBerriesM)
      |> \play ->
           if play.lives == 0 then
             DiedSt {score = play.score}
           else
             PlaySt play
    DiedSt {score} ->
      case input of
        Space _ ->
          InitSt
        _ ->
          state

--------------------------------------------------------------------------------

viewBack: Form
viewBack =
  XY.curryTo Collage.rect (gameDim |* 2)
  |> Collage.filled backColor

maybeGroup: List Form -> Form
maybeGroup fs =
  case fs of
    [f] -> f
    _ -> Collage.group fs

viewSprite: Pos' (Dim' (Rot' (Form' s))) -> Form
viewSprite sprite =
  case sprite.form of
    Nothing -> Collage.group []
    Just form ->
      let rotf = Collage.rotate sprite.rot form in
      wrappedPos sprite
      |> List.map (\s -> XY.move s.pos rotf)
      |> maybeGroup

viewScoreAndLives: Play -> Form
viewScoreAndLives state =
  ("Score " ++ toString state.score ++ " - Lives " ++ toString state.lives)
  |> Text.fromString
  |> Collage.text
  |> XY.move {x = 0, y = gameDim.y - 32}

view: State -> Element
view state =
  (case state of
     InitSt ->
       [ viewBack
       , Text.fromString "Get Ready!" |> Collage.text ]
     PlaySt play ->
       [ viewBack
       , play.berries |> List.map viewSprite |> Collage.group
       , play.player |> viewSprite
       , play.ghosts |> List.map viewSprite |> Collage.group
       , play |> viewScoreAndLives ]
     DiedSt {score} ->
       [ viewBack
       , Text.fromString ("Final score " ++ toString score) |> Collage.text ])
  |> XY.curryTo Collage.collage (XY.map round (gameDim |* 2))
  |> XY.curryTo Element.container (XY.map round (gameDim |* 2)) Element.middle

--------------------------------------------------------------------------------

main: Signal Element
main = view <~ state

state: Signal State
state =
  input
  |> Signals.foldpFrom init update

--------------------------------------------------------------------------------

input: Signal Event
input =
  [ (XY.map toFloat >> Arrows) <~ Keyboard.arrows
  , Space <~ Keyboard.space
  , Tick <~ Time.fps 30 ]
  |> Signal.mergeMany
