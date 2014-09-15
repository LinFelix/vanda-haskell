module Data.RevMapTests where
import Data.RevMap

import TestUtil

import           Control.Arrow ((***))
import           Data.List (inits)
import qualified Data.Map as M
import           Data.Maybe (mapMaybe)
import qualified Data.MultiMap as MM
import qualified Data.Set as S
import           Data.Tuple (swap)
import           Test.HUnit


tests :: Test
tests =
  let x00 = (int 0, int 0)
      x01 = (int 0, int 1)
      x10 = (int 1, int 0)
      x11 = (int 1, int 1)

      ox00 = OrdOnFst x00
      ox01 = OrdOnFst x01
      ox10 = OrdOnFst x10
      ox11 = OrdOnFst x11

      insertions =
        [ (ox00, ox00)
        , (ox10, ox10)
        , (ox10, ox11)
        , (ox11, ox11)
        , (ox11, ox01)
        , (ox10, ox10)
        ]

      ms = scanl (\ acc (k, v) -> insert k v acc) empty insertions

      ls = [ []
           , [(x00, x00)]
           , [(x00, x00), (x10, x10)]
           , [(x00, x00), (x10, x11)]
           , [(x00, x00), (x11, x11)]
           , [(x00, x01), (x11, x01)]
           , [(x00, x01), (x10, x10)]
           ]

      es = [ []
           , [[x00]]
           , [[x00], [x10]]
           , [[x00], [x10]]
           , [[x00], [x11]]
           , [[x00, x11], [x00, x11]]
           , [[x00], [x10]]
           ]

      ordOnFstPairs   = map (  OrdOnFst ***   OrdOnFst)
      unOrdOnFstPairs = map (unOrdOnFst *** unOrdOnFst)

      flatForward  = unOrdOnFstPairs . M.toAscList . forward
      flatBackward = map (unOrdOnFst *** (map unOrdOnFst . S.toAscList))
                   . M.toAscList
                   . backward
  in TestList
  [ "insert/delete/toAscList" ~: TestList $ zipWith (\ m l -> TestList
    [ "forward"  ~: flatForward m ~?= l
    , "backward" ~: (S.fromList $ map swap $ unOrdOnFstPairs $ MM.toList $ backward m) ~?= S.fromList l
    ]) ms ls
  , "fromList" ~: TestList $ zipWith (\ m l -> TestList
    [ "forward"  ~: flatForward m ~?= l
    , "backward" ~: (S.fromList $ map swap $ unOrdOnFstPairs $ MM.toList $ backward m) ~?= S.fromList l
    ]) (map fromList $ inits insertions) ls
  , "equivalenceClass" ~: TestList $ zipWith (\ m e ->
          (map (map unOrdOnFst . S.toList) $ mapMaybe (\ k -> equivalenceClass k m) $ M.keys $ forward m) ~?= e
        ) ms es
  ]
