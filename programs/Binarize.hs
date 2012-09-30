{-# LANGUAGE LiberalTypeSynonyms
           , ExistentialQuantification
           , RankNTypes
           , TupleSections
           , EmptyDataDecls
           , RecordWildCards #-}

module Main where

import Codec.Compression.GZip ( compress, decompress )
import Control.DeepSeq ( NFData )
import Control.Monad ( when, unless, forM_, forM, liftM4 )
import Control.Monad.ST
import qualified Data.Array as A
import qualified Data.Array.Base as AB
-- import qualified Data.Array.MArray as MA
import qualified Data.Array.ST as STA
import qualified Data.Binary as B
import qualified Data.ByteString.Lazy as B
import qualified Data.IntMap as IM
import qualified Data.IntSet as IS
import qualified Data.Ix as Ix
import Data.List ( foldl' )
import qualified Data.Map as M
import Data.NTT
import qualified Data.Queue as Q
-- import qualified Data.Set as S
import Data.STRef
import qualified Data.Vector as V
import System.Environment ( getArgs )

-- import Debug.Trace

import Vanda.Grammar.XRS.Binary ()
import Vanda.Grammar.XRS.IRTG
import Vanda.Hypergraph.IntHypergraph
import qualified Vanda.Hypergraph.Tree as T
import Vanda.Util


instance NFData StrictIntPair

data WTA l = WTA
             { finalState :: Int
             , transitions :: Hypergraph l ()
             }
             deriving Show

data BOT -- =

type RegRep l l' = l -> [WTA (Var l')] -> WTA (Var l')

rene :: Int -> Int -> WTA l -> WTA l
rene i i' (WTA v0 (Hypergraph vs es))
  = WTA (v0 + i) $ Hypergraph (vs + i) (es' ++ map (mapHE (i +)) es)
  where
    es' = if i' == 0
          then []
          else [ mkHyperedge i' (map (i +) $ from e) (label e) (ident e)
               | e <- es
               , to e == v0
               ]

relab :: [l'] -> WTA l -> WTA (l, l')
relab ls (WTA v0 (Hypergraph vs es))
  = WTA v0
  $ Hypergraph vs
  $ [ mkHyperedge (to e) (from e) (label e, l') (ident e)
    | e <- es
    , l' <- ls
    ]

varta :: RegRep l l' -> Var l -> [WTA (Var l')] -> WTA (Var l')
varta _ (Var i) [] = WTA 0 $ Hypergraph 1 [mkHyperedge 0 [] (var i) ()]
varta rr (NV l) tas = rr l tas
varta _ _ _ = error "Variables cannot have children"


regrep :: RegRep l l' -> T.Tree (Var l) -> WTA (Var l')
regrep rr = let go t = varta rr (T.rootLabel t) (map go (T.subForest t))
            in go


{- chTo :: Int -> Hyperedge l i -> Hyperedge l i
chTo i e@Nullary{} = e{ to = i } -} 

type GigaMap = M.Map IS.IntSet Int

type AnalMap = IM.IntMap (IS.IntSet, Int) -- analysis map

forwMskel
  :: GigaMap -> Int -> WTA (Var l') -> (WTA Int, AnalMap, GigaMap, Int)
forwMskel gm_ gmi_ WTA{ .. } = runST $ do
  gm <- newSTRef gm_         -- maps variable sets to terminal symbols
  gmi <- newSTRef gmi_       -- max. terminal symbol
  ntr <- STA.newArray (0, nodes transitions - 1) []
         :: ST s (STA.STArray s Int [Hyperedge Int ()])
  -- mmap :: GigaMap <- M.empty -- maps variable sets to states of the wta
  amap <- newSTRef (IM.empty :: AnalMap)
  -- ^ maps each state to its var. set and the gm image of that var. set
  forwA <- computeForwardA transitions
  q <- newSTRef $ Q.fromList [ e | e@Nullary{} <- edges transitions ]
  let -- addt v e = AB.unsafeRead nt v >>= AB.unsafeWrite nt v . (e :)
      register s = do
        mb <- fmap (M.lookup s) $ readSTRef gm
        case mb of
          Nothing -> do
                       i <- readSTRef gmi
                       modifySTRef' gmi (+ 1)
                       modifySTRef' gm $ M.insert s i
                       return i
          Just i -> return i
      construct = fmap concat
                $ forM [0 .. nodes transitions - 1]
                $ AB.unsafeRead ntr
      go = do
        viewSTRef' q (Q.deqMaybe)
          ( liftM4 (,,,)
              (fmap (WTA finalState . mkHypergraph) construct)
              (readSTRef amap)
              (readSTRef gm)
              (readSTRef gmi)
          )
          $ \ e -> do
            case e of
              Nullary{ label = Var i, .. } -> let s = IS.singleton i in do
                ti <- register s
                modifySTRef' amap $ IM.insert to (s, ti)
                es <- AB.unsafeRead ntr to
                AB.unsafeWrite ntr to (Nullary{ label = ti, .. } : es)
              Nullary{ .. } -> do
                es <- AB.unsafeRead ntr to
                when (null es) $ let s = IS.empty in do
                  ti <- register s
                  modifySTRef' amap $ IM.insert to (s, ti)
                  AB.unsafeWrite ntr to (Nullary{ label = ti, ..} : es)
              Unary{ .. } -> do
                sti <- fmap (IM.! from1) $ readSTRef amap
                modifySTRef' amap $ IM.insert to sti
                -- divert transitions that end in from also to to
                esf <- AB.unsafeRead ntr from1
                est <- AB.unsafeRead ntr to
                AB.unsafeWrite ntr to $ est ++ map (\ e1 -> e1{ to = to }) esf
              Binary{ .. } -> do
                (s1, ti1) <- fmap (IM.! from1) $ readSTRef amap
                (s2, ti2) <- fmap (IM.! from2) $ readSTRef amap
                let s = s1 `IS.union` s2
                ti <- register s
                modifySTRef amap $ IM.insert to (s, ti)
                est <- AB.unsafeRead ntr to
                case (ti == ti1, ti == ti2, to /= from1, to /= from2) of
                  (False, False, _, _) ->      -- insert new edges
                    AB.unsafeWrite ntr to
                      $ Binary{ label = ti, .. }
                      : Binary{ label = ti, from1 = from2, from2 = from1, .. }
                      : est
                  (True, False, True, _) -> do -- divert from1 also to to
                    esf <- AB.unsafeRead ntr from1
                    AB.unsafeWrite ntr to
                      $ est ++ map (\ e1 -> e1{ to = to }) esf
                  (False, True, _, True) -> do -- divert from2 also to to
                    esf <- AB.unsafeRead ntr from2
                    AB.unsafeWrite ntr to
                      $ est ++ map (\ e1 -> e1{ to = to }) esf
                  _ -> return ()               -- probably s1 = s2 = s = empty
              _ -> error "WTA is not BINARY"
            hes <- AB.unsafeRead forwA (to e)
            forM_ hes $ updateHe $ \ e1 -> modifySTRef' q (Q.enq e1)
            AB.unsafeWrite forwA (to e) []
            go
  go

inters :: WTA Int -> WTA Int -> WTA Int
inters (WTA fs1 h1@(Hypergraph vs1 tr1)) (WTA fs2 h2@(Hypergraph vs2 tr2))
  = WTA (st (fs1, fs2)) $ Hypergraph (Ix.rangeSize ix) $ tr{-runST $ do
    tr <- newSTRef []
    forw1 <- computeForwardA h1
    forw2 <- computeForwardA h2
    stat <- STA.newArray (0, vs1 - 1) IS.IntSet
    una1 <- STA.newArray (0, vs1 - 1) []
            :: ST s (STA.STArray s Int [Hyperedge Int ()])
    una2 <- STA.newArray (0, vs2 - 1) []
            :: ST s (STA.STArray s Int [Hyperedge Int ()])
    bin1 <- STA.newArray (0, vs1 - 1) []
            :: ST s (STA.STArray s Int [Hyperedge Int ()])
    bin2 <- STA.newArray (0, vs2 - 1) []
            :: ST s (STA.STArray s Int [Hyperedge Int ()])
    q <- newSTRef [ (q1, q2, Nullary (st (q1, q2)) l1 ())
                  | (Nullary q1 l1 ()) <- tr1
                  , (Nullary q2 _  ()) <- nul2 IM.! l1
                  ]
    let add1 e1@Unary{ to = q1, from1 = q11, label = l1 } = do
          es1 <- AB.unsafeRead una1 l1
          AB.unsafeWrite una1 l1 (e1 : es1)
          es2 <- AB.unsafeRead una2 l1
          modifySTRef' q
            $ (++) [ (q1, q2, Unary (st (q1, q2)) (st (q11, q21)) l1 ())
                   | (Unary q2 q21 _ ()) <- es2
                   ]
        add1 e1@Binary{ to = q1, from1 = q11, from2 = q12, label = l1 } = do
          es1 <- AB.unsafeRead bin1 l1
          AB.unsafeWrite bin1 l1 (e1 : es1)
          es2 <- AB.unsafeRead bin2 l1
          modifySTRef' q $ (++)
            [ (q1, q2, Binary (st (q1, q2)) (st (q11, q21)) (st (q12, q22)) l1 ())
            | (Binary q2 q21 q22 _ ()) <- es2
            ]
        add2 e2@Unary{ to = q2, from1 = q21, label = l2 } = do
          es2 <- AB.unsafeRead una2 l2
          AB.unsafeWrite una2 l2 (e2 : es2)
          es1 <- AB.unsafeRead una1 l2
          modifySTRef' q
            $ (++) [ (q1, q2, Unary (st (q1, q2)) (st (q11, q21)) l2 ())
                   | (Unary q1 q11 _ ()) <- es1
                   ]
        add2 e2@Binary{ to = q2, from1 = q21, from2 = q22, label = l2 } = do
          es2 <- AB.unsafeRead bin2 l2
          AB.unsafeWrite bin2 l2 (e2 : es2)
          es1 <- AB.unsafeRead bin1 l2
          modifySTRef' q $ (++)
            [ (q1, q2, Binary (st (q1, q2)) (st (q11, q21)) (st (q12, q22)) l2 ())
            | (Binary q1 q11 q12 _ ()) <- es1
            ]
        go = do
          lviewSTRef' q (readSTRef tr) $ \ (q1, q2, e) -> do
            modifySTRef' tr (e :)
            mapM_ (updateHe add1) =<< AB.unsafeRead forw1 q1
            AB.unsafeWrite forw1 q1 []
            mapM_ (updateHe add2) =<< AB.unsafeRead forw2 q2
            AB.unsafeWrite forw2 q2 []
            go
    go-}
  where
    ix = ((0, 0), (vs1 - 1, vs2 - 1))
    st ij = Ix.index ix ij
    -- nul2 = IM.fromListWith (++) [ (label e, [e]) | e@Nullary{} <- tr2 ]
    nul2 = foldl' (\m (l, e) -> IM.alter (prep e) l m) IM.empty
           [ (label e, e) | e@Nullary{} <- tr2 ]
    prep e Nothing = Just [e]
    prep e (Just es) = Just (e : es)
    tr = [ mkHyperedge
             (st (to e1, to e2))
             (map st (zip (from e1) (from e2)))
             ll
             ()
         | e1 <- tr1
         , e2 <- tr2
         , arity e1 == arity e2
         , let ll = label e1
         , ll == label e2
         ]

type Branches = IM.IntMap (Int, Int)

-- derivToTree :: Derivation l i -> T.Tree l
-- derivToTree (T.Node e ds) = T.Node (label e) (map derivToTree ds)

extractBranches :: Branches -> [T.Tree Int] -> Branches
extractBranches !s [] = s
extractBranches !s (T.Nullary{} : ts) = extractBranches s ts
extractBranches !s (T.Unary{ .. } : ts) = extractBranches s (sub1 : ts)
extractBranches !s (T.Binary i t1 t2 : ts) = extractBranches
              (IM.insert i (T.rootLabel t1, T.rootLabel t2) s) (t1 : t2 : ts)
extractBranches _ (T.Node _ _ : _) = error "Tree not BINARY1" 

backMskel
  :: AnalMap
  -> WTA (Var l')
  -> Branches
  -> (Branches, WTA (Var l', (Int, Int)))
backMskel amap wta@WTA{ transitions = tr@Hypergraph{ .. } } branches
  = ( IM.fromList br
    , wta{ transitions = tr{ edges = foldr f [] edges ++ es' } }
    )
  where
    (es', br)
      = unzip
        [ ( e{ label = (label, lus to) }
          , (lto, if b1 then (lfrom1, lfrom2) else (lfrom2, lfrom1))
          )
        | e@Binary{ .. } <- edges
        , let lto = lu to; lfrom1 = lu from1; lfrom2 = lu from2
        , lfrom1 /= 0
        , lfrom2 /= 0
        , let (lf1, lf2) = IM.findWithDefault (0, 0) lto branches
        , let b1 = lf1 == lfrom1 && lf2 == lfrom2
        , let b2 = lf2 == lfrom1 && lf1 == lfrom2
        , b1 || b2
        ]
    f e es = case e of
               Nullary{ .. } -> e{ label = (label, lus to) } : es
               Unary{ .. }   -> e{ label = (label, lus to) } : es
               Binary{ .. }
                 | eligible  -> e{ label = (label, lus to) } : es
                 | otherwise -> es
                 where
                   eligible = lfrom1 == 0 || lfrom2 == 0 || maybe False
                                 (`elem` [(lfrom1, lfrom2), (lfrom2, lfrom1)])
                                 (IM.lookup lto branches)
                   lto = lu to; lfrom1 = lu from1; lfrom2 = lu from2
               _ -> error "WTA is not BINARY"
    lu q = snd $ amap IM.! q
    lus q = first' IS.size $ amap IM.! q

dissect
  :: Branches -> T.Tree (Var l', (Int, Int)) -> IM.IntMap (T.Tree (Var l'))
dissect br = go IM.empty . (: [])
  where
    go !m [] = m
    go !m (t : ts)
      = case T.rootLabel t of
          (_, (_, i)) ->
            case go2 i t ts of
              (trm, ts') -> go (IM.insert i trm m) ts'
    makevar i' i = T.Nullary (if fst (br IM.! i') == i then var 0 else var 1)
    go2 i' (T.Nullary (Var _, (_, i))) ts = (makevar i' i, ts)
    go2 i' t ts = case T.rootLabel t of
                    (l, (vc, i))
                      | vc < 2 || i == i' -> first' (T.node l)
                                          $ fold (go2 i') (T.subForest t) ts
                      | otherwise -> (makevar i' i, t : ts)
      where
        fold _ [] ts0 = ([], ts0)
        fold f (c : cs) ts0 = let (c1, ts1) = f c ts0
                                  (cs1, ts2) = fold f cs ts1
                              in (c1 : cs1, ts2)







data StrLabel = StrConcat | StrConst !Int deriving (Eq, Ord, Show)

cumu :: Int -> [Int] -> [Int]
cumu _ [] = []
cumu a (x : xs) = let x' = a + x in x' : cumu x' xs

strrr :: RegRep StrLabel StrLabel
strrr sc@StrConst{} []
  = WTA 1
  $ Hypergraph 3
  $ [ mkHyperedge 1 [] (NV sc) () ]          -- [0,1] -> i
  {-[ mkHyperedge 0 [] (NV StrConcat) ()     -- [0,0] -> eps
    , mkHyperedge 2 [] (NV StrConcat) ()     -- [1,1] -> eps
    , mkHyperedge 1 [] (NV sc) ()            -- [0,1] -> i
    , mkHyperedge 0 [0, 0] (NV StrConcat) () -- [0,0] -> [0,0]*[0,0]
    , mkHyperedge 1 [0, 1] (NV StrConcat) () -- [0,1] -> [0,0]*[0,1]
    , mkHyperedge 1 [1, 2] (NV StrConcat) () -- [0,1] -> [0,1]*[1,1]
    , mkHyperedge 2 [2, 2] (NV StrConcat) () -- [1,1] -> [1,1]*[1,1]
    ]-}
strrr sc@StrConcat tas
  = WTA (st (0, k))
  $ Hypergraph (last bnds)
  $ concat
  $ [ [ mkHyperedge (st (i, j)) [st (i, i'), st (i', j)] (NV sc) ()
      | i <- [0 .. k], i' <- [i + 1 .. k], j <- [i' + 1 .. k]
      ]
    ]
    ++ 
    [ edges $ transitions $ rene b (st (i - 1, i)) ta
    | (i, b, ta) <- zip3 [1 ..] bnds tas
    ]
  where
    k = length tas
    ix = ((0, 0), (k, k))
    bnd = Ix.rangeSize ix
    bnds = cumu bnd $ 0 : map (nodes . transitions) tas
    st ij = Ix.index ix ij
strrr _ _ = error "String constants must be nullary"

strrr' :: RegRep StrLabel StrLabel
strrr' sc@StrConst{} []
  = WTA 1
  $ Hypergraph 3
  $ [ mkHyperedge 0 [] (NV StrConcat) ()     -- [0,0] -> eps
    , mkHyperedge 2 [] (NV StrConcat) ()     -- [1,1] -> eps
    , mkHyperedge 1 [] (NV sc) ()            -- [0,1] -> i
    , mkHyperedge 0 [0, 0] (NV StrConcat) () -- [0,0] -> [0,0]*[0,0]
    , mkHyperedge 1 [0, 1] (NV StrConcat) () -- [0,1] -> [0,0]*[0,1]
    , mkHyperedge 1 [1, 2] (NV StrConcat) () -- [0,1] -> [0,1]*[1,1]
    , mkHyperedge 2 [2, 2] (NV StrConcat) () -- [1,1] -> [1,1]*[1,1]
    ]
strrr' sc@StrConcat tas
  = WTA (st (0, k))
  $ Hypergraph (last bnds)
  $ concat
  $ [ [ mkHyperedge (st (i, i)) [] (NV sc) () | i <- [0..k] ]
    , [ mkHyperedge (st (i, j)) [st (i, i'), st (i', j)] (NV sc) ()
      | i <- [0 .. k], i' <- [i .. k], j <- [i' .. k]
      ]
    ]
    ++ 
    [ edges $ transitions $ rene b (st (i - 1, i)) ta
    | (i, b, ta) <- zip3 [1 ..] bnds tas
    ]
  where
    k = length tas
    ix = ((0, 0), (k, k))
    bnd = Ix.rangeSize ix
    bnds = cumu bnd $ 0 : map (nodes . transitions) tas
    st ij = Ix.index ix ij
strrr' _ _ = error "String constants must be nullary"


data TreeLabel = TreeConcat !Int | ForestLeft | ForestRight | ForestEmpty
                deriving (Eq, Ord, Show)

treerr :: RegRep TreeLabel TreeLabel
treerr tc@TreeConcat{} tas
  = WTA fin
  $ Hypergraph (fin + 1)
  $ concat
  $ [ [ transition (i, i) [] ForestEmpty | i <- [0..k] ]
    , [ transition (i, j) [(i, i'), (i', j)] ForestLeft  {- (-1, i) -}
      | i <- [0 .. k], i' <- [i + 1 .. k], j <- [i' + 1 .. k] {- i .. k -}
      ]
    , [ mkHyperedge {- (-1, 0) -} fin [st (0, k)] (NV tc) () ]
    ]
    ++
    [ edges $ transitions $ rene b (st (i - 1, i)) ta {- (-1, i) -}
    | (i, b, ta) <- zip3 [1 ..] bnds tas
    ]
  where
    k = length tas
    ix = (({- -1 -} 0, 0), (k, k))
    bnd = Ix.rangeSize ix
    bnds = cumu bnd $ 0 : map (nodes . transitions) tas
    fin = last bnds
    st ij = Ix.index ix ij
    transition q qs l = mkHyperedge (st q) (map st qs) (NV l) ()
treerr _ _ = error "Only tree concatenation allowed for reg. repr."



treerr' :: RegRep TreeLabel TreeLabel
treerr' tc@TreeConcat{} tas
  = WTA fin
  $ Hypergraph (fin + 1)
  $ concat
  $ [ [ transition (i, i) [] ForestEmpty | i <- [0..k] ]
    , [ transition (i - 1, j) [(i - 1, i), (i, j)] ForestLeft  {- (-1, i) -}
      | i <- [1 .. k], j <- [i + 1 .. k] {- i .. k -}
      ]
    , [ transition (i, j) [(i, j - 1), (j - 1, j)] ForestRight {- (-1, j) -}
      | i <- [0 .. k], j <- [i + 2 .. k] {- i + 1 .. k -}
      ]
    , [ mkHyperedge {- (-1, 0) -} fin [st (0, k)] (NV tc) () ]
    ]
    ++
    [ edges $ transitions $ rene b (st (i - 1, i)) ta {- (-1, i) -}
    | (i, b, ta) <- zip3 [1 ..] bnds tas
    ]
  where
    k = length tas
    ix = (({- -1 -} 0, 0), (k, k))
    bnd = Ix.rangeSize ix
    bnds = cumu bnd $ 0 : map (nodes . transitions) tas
    fin = last bnds
    st ij = Ix.index ix ij
    transition q qs l = mkHyperedge (st q) (map st qs) (NV l) ()
treerr' _ _ = error "Only tree concatenation allowed for reg. repr."




-- an IRTG is an IntHypergraph l i together with mappings
-- l -> Data.Tree l'
{-
data IntTree
  = Nullary { label :: !Int }
  | Unary   { label :: !Int, succ1 :: IntTree }
  | Binary  { label :: !Int, succ1 :: IntTree, succ2 :: IntTree }
  | Node    { label :: !Int, succ :: [IntTree] }

mkIntTree :: Int -> [IntTree] -> IntTree
mkIntTree l s
  = case s of
      []       -> Nullary { label = l }
      [s1]     -> Unary   { label = l, succ1 = s1 }
      [s1, s2] -> Binary  { label = l, succ1 = s1, succ2 = s2 }
      _        -> Node    { label = l, succ = s }


arity :: IntTree -> Int
arity Nullary{} = 0
arity Unary{} = 1
arity Binary{} = 2
arity Node{ succ = s } = length s


type RegRep = Int -> Int -> IntHypergraph Int ()



data IRTG l i = IRTG
                { rtg :: IntHypergraph l i
                , 
-}
{-
instance Ord l => Ord (T.Tree l) where
  T.Node l1 ts1 `compare` T.Node l2 ts2
    = case (l1 `compare` l2, ts1 `compare` ts2) of
        (LT, _) -> LT
        (EQ, LT) -> LT
        (EQ, EQ) -> EQ
        _ -> GT
-}

-- trick: initialize gigamap so that emptyset and singletons are clear

binarizeXRS :: IRTG Int -> IRTG Int
binarizeXRS irtg@IRTG{ .. }
  = runST $ do
    tr <- newSTRef []
    newh1 <- newSTRef M.empty
    h1c <- newSTRef (0 :: Int)
    newh2 <- newSTRef M.empty
    h2c <- newSTRef (0 :: Int)
    virt <- newSTRef M.empty
    vc <- newSTRef $ nodes $ rtg
    let noact = \ _ -> return ()
        register :: (Show v, Ord v) => STRef s (M.Map v Int) -> STRef s Int -> (Int -> ST s ()) -> v -> ST s Int
        register h hc act v = do
          mb <- fmap (M.lookup v) $ readSTRef h
          case mb of
            Nothing -> do
              i <- readSTRef hc
              modifySTRef' hc (+ 1)
              modifySTRef' h $ M.insert v i
              act i
              return i
            Just i -> return i
        takeover e = case label e of
          SIP ti0 si0 -> do
            ti <- register newh1 h1c noact $ fmap h1convert $ h1 V.! ti0
            si <- register newh2 h2c noact $ h2convert $ h2 V.! si0
            modifySTRef' tr (e{ label = SIP ti si } :)
    forM_ (edges rtg) $ \ e ->
      case e of
        Hyperedge{ label = SIP i1 i2 } ->
          let twta = h1term i1
              swta = h2term i2
              (ftwta, tamap, gm1, gmi1) = forwMskel gm0 gmi0 twta
              (fswta, samap, _, _)      = forwMskel gm1 gmi1 swta
              inter = inters ftwta fswta
              options (WTA fs tr_) = (A.! fs) $ knuth tr_ (\ _ _ _ -> 1.0)
              choose = fmap label . deriv . head
              cand = choose (options inter)
              bran = extractBranches IM.empty [cand]
              (tbran, tback) = backMskel tamap twta bran
              (sbran, sback) = backMskel samap swta bran
              ttree = choose (options tback)
              stree = choose (options sback)
              tmap = dissect tbran ttree
              smap = dissect sbran stree
              go False (T.Nullary i) = return $ e `deref` (i - 1)
              go atroot (T.Binary i c1 c2) = do
                -- vs@[v1, v2] <- mapM (go False) cs
                v1 <- go False c1
                v2 <- go False c2
                ti <- register newh1 h1c noact $ tmap IM.! i
                si <- register newh2 h2c noact $ smap IM.! i
                if atroot
                  then let v = to e in do
                    modifySTRef' tr (Binary v v1 v2 (SIP ti si) (ident e) :)
                    return v
                  else do
                    v <- flip (register virt vc) (ti, si, v1, v2)
                         $ \ v -> modifySTRef' tr
                                    (Binary v v1 v2 (SIP ti si) (-1) :)
                    return v
              go _ _ = error "Tree not BINARY2"
          in case options inter of
               [] -> takeover e
               os -> go True (choose os) >> return ()
        _ -> takeover e
    nodes <- readSTRef vc
    edges <- readSTRef tr
    h1_ <- readSTRef newh1
    h1c_ <- readSTRef h1c
    h2_ <- readSTRef newh2
    h2c_ <- readSTRef h2c
    let h1new = V.fromList $ A.elems $ A.array (0, h1c_ - 1)
                $ map (swap . first' (fmap h1cc)) $ M.toList h1_
    let h2new = V.fromList $ A.elems $ A.array (0, h2c_ - 1)
                $ map (swap . first' h2cc) $ M.toList h2_
    return irtg{ rtg = Hypergraph{ .. }, h1 = h1new, h2 = h2new } 
  where
    gm0 = M.fromList
        $ (IS.empty, 0) : [ (IS.singleton i, i + 1) | i <- [ 0 .. 99 ] ]
    gmi0 = M.size gm0
    h1term = regrep treerr . fmap h1convert . (h1 V.!)
    h1convert (NT i) = var i
    h1convert (T i) = NV (TreeConcat i)
    h2term = regrep strrr . h2convert . (h2 V.!)
    h2convert [x] = h2cv x
    h2convert xs = T.node (NV StrConcat) (map h2cv xs)
    h2cv (NT i) = T.Nullary (var i)
    h2cv (T i) = T.Nullary (NV (StrConst i))
    h1cc (Var i) = nt i
    h1cc (NV (TreeConcat i)) = tt i
    h1cc (NV ForestEmpty) = T (-1)
    h1cc (NV ForestLeft) = T (-2)
    h1cc (NV ForestRight) = T (-3)
    h2cc (T.Nullary (Var i)) = [nt i]
    h2cc (T.Nullary (NV (StrConst i))) = [tt i]
    h2cc (T.Binary (NV StrConcat) c1 c2) = h2cc c1 ++ h2cc c2
    h2cc (T.Node (NV StrConcat) cs) = concatMap h2cc cs
    h2cc t = error (show t) -- "should not happen"
    swap (x, y) = (y, x)

fst3 (x, _, _) = x

myshow WTA { .. } = "Final state: " ++ show finalState ++ "\nTransitions:\n"
                    ++ unlines (map show (edges transitions))

{-
main :: IO ()
main = do
  args <- getArgs
  case args of
    ["-z", zhgFile] -> do
      irtg@IRTG{ .. } :: IRTG Int
        <- fmap (B.decode . decompress) $ B.readFile (zhgFile ++ ".bhg.gz")
      let birtg = binarizeXRS irtg
      B.writeFile (zhgFile ++ ".bin.bhg.gz") $ compress $ B.encode birtg
-}

main :: IO ()
main = let swta = regrep strrr
                $ T.Node (NV StrConcat)
                $ [ T.Node (Var i) []
                  | i <- [0 .. 2]
                  ]
           twta = regrep treerr
                $ T.Node (NV (TreeConcat 0))
                $ [ T.Node (NV (TreeConcat 1)) []
                  , T.Node (Var 2) []
                  , T.Node (Var 1) []
                  , T.Node (Var 0) []
                  ]
           gm0 = M.singleton IS.empty 0
           gmi0 = 1
           (fswta, smap, gm1, gmi1) = forwMskel gm0 gmi0 swta
           (ftwta, tmap, _, _)      = forwMskel gm1 gmi1 twta
           inter = inters fswta ftwta
           options (WTA fs tr) = (A.! fs) $ knuth tr (\ _ _ _ -> 1.0)
           choose = fmap label . deriv . head
           bran = extractBranches IM.empty [ choose (options inter) ]
           (sswap, sback) = backMskel smap swta bran
           (tswap, tback) = backMskel tmap twta bran
           stree = choose (options sback)
           ttree = choose (options tback)
       in do
            putStrLn $ myshow swta
            putStrLn $ myshow twta
            putStrLn $ myshow inter
            -- putStrLn $ myshow sback
            -- putStrLn $ myshow tback
            -- print $ choose inter
            -- print $ stree
            -- print $ dissect sswap stree
            -- print $ ttree
            -- print $ dissect tswap ttree
     -- $ relab [ [1, 2, 3], [4, 5, 6], [7, 8, 9] ]

