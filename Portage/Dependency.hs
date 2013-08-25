module Portage.Dependency
  (
    simplify_deps
  , simplifyUseDeps
  , sortDeps
  , dep2str
  -- reexports
  , module Portage.Dependency.Types
  , module Portage.Dependency.Builder
  ) where

import Portage.Version
import Portage.Use

import Portage.PackageId

import Distribution.Text ( Text(..) )
import qualified Text.PrettyPrint as Disp
import Text.PrettyPrint ( (<>), vcat, nest, render )

import Data.Function ( on )
import Data.Maybe ( fromJust, mapMaybe )
import Data.List ( nub, groupBy, partition, sortBy )
import Data.Ord           ( comparing )

import Portage.Dependency.Builder
import Portage.Dependency.Normalize
import Portage.Dependency.Types

dispSlot :: SlotDepend -> Disp.Doc
dispSlot AnySlot          = Disp.empty
dispSlot AnyBuildTimeSlot = Disp.text ":="
dispSlot (GivenSlot slot) = Disp.text (':' : slot)

dispLBound :: PackageName -> LBound -> Disp.Doc
dispLBound pn (StrictLB    v) = Disp.char '>' <> disp pn <-> disp v
dispLBound pn (NonstrictLB v) = Disp.text ">=" <> disp pn <-> disp v
dispLBound _pn ZeroB = error "unhandled 'dispLBound ZeroB'"

dispUBound :: PackageName -> UBound -> Disp.Doc
dispUBound pn (StrictUB    v) = Disp.char '<' <> disp pn <-> disp v
dispUBound pn (NonstrictUB v) = Disp.text "<=" <> disp pn <-> disp v
dispUBound _pn InfinityB = error "unhandled 'dispUBound Infinity'"

mergeDRanges :: DRange -> DRange -> DRange
mergeDRanges _ r@(DExact _) = r
mergeDRanges l@(DExact _) _ = l
mergeDRanges (DRange ll lu) (DRange rl ru) = DRange (max ll rl) (min lu ru)

dispDAttr :: DAttr -> Disp.Doc
dispDAttr (DAttr s u) = dispSlot s <> dispUses u

merge_pair :: Dependency -> Dependency -> Dependency
merge_pair (Atom lp ld la) (Atom rp rd ra)
    | lp /= rp = error "merge_pair got different 'PackageName's"
    | la /= ra = error "merge_pair got different 'DAttr's"
    | otherwise = Atom lp (mergeDRanges ld rd) la
merge_pair l r = error $ unwords ["merge_pair can't merge non-atoms:", show l, show r]

dep2str :: Int -> Dependency -> String
dep2str start_indent = render . nest start_indent . showDepend . normalize_depend

(<->) :: Disp.Doc -> Disp.Doc -> Disp.Doc
a <-> b = a <> Disp.char '-' <> b

sp :: Disp.Doc
sp = Disp.char ' '

sparens :: Disp.Doc -> Disp.Doc
sparens doc = Disp.parens (sp <> valign doc <> sp)

valign :: Disp.Doc -> Disp.Doc
valign d = nest 0 d

showDepend :: Dependency -> Disp.Doc
showDepend (Atom pn range dattr)
    = case range of
        -- any version
        DRange ZeroB InfinityB -> disp pn          <> dispDAttr dattr
        DRange ZeroB ub        -> dispUBound pn ub <> dispDAttr dattr
        DRange lb InfinityB    -> dispLBound pn lb <> dispDAttr dattr
        -- TODO: handle >=foo-0    special case
        -- TODO: handle =foo-x.y.* special case
        DRange lb ub          ->    showDepend (Atom pn (DRange lb InfinityB) dattr)
                                 <> Disp.char ' '
                                 <> showDepend (Atom pn (DRange ZeroB ub)    dattr)
        DExact v              -> Disp.char '~' <> disp pn <-> disp v { versionRevision = 0 } <> dispDAttr dattr

showDepend (DependIfUse u dep)  = disp u         <> sp <> sparens (showDepend dep)
showDepend (DependAnyOf deps)   = Disp.text "||" <> sp <> sparens (vcat $ map showDependInAnyOf deps)
showDepend (DependAllOf deps)   = valign $ vcat $ map showDepend deps

-- needs special grouping
showDependInAnyOf :: Dependency -> Disp.Doc
showDependInAnyOf d@(DependAllOf _deps) = sparens (showDepend d)
-- both lower and upper bounds are present thus needs 2 atoms
-- TODO: '=foo-x.y.*' will take only one atom, not two
showDependInAnyOf d@(Atom _pn (DRange lb ub) _dattr)
    | lb /= ZeroB && ub /= InfinityB
                                       = sparens (showDepend d)
-- rest are fine
showDependInAnyOf d                    =          showDepend d

-- TODO: remove it in favour of more robust 'normalize_depend'
simplify_group :: [Dependency] -> Dependency
simplify_group [x] = x
simplify_group xs = foldl1 merge_pair xs

-- TODO: remove it in favour of more robust 'normalize_depend'
-- divide packages to groups (by package name), simplify groups, merge again
simplify_deps :: [Dependency] -> [Dependency]
simplify_deps deps = flattenDep $ 
                        (map (simplify_group.nub) $
                            groupBy cmpPkgName $
                                sortBy (comparing getPackagePart) groupable)
                        ++ ungroupable
    where (ungroupable, groupable) = partition ((==Nothing).getPackage) deps
          --
          cmpPkgName p1 p2 = cmpMaybe (getPackage p1) (getPackage p2)
          cmpMaybe (Just p1) (Just p2) = p1 == p2
          cmpMaybe _         _         = False
          --
          flattenDep :: [Dependency] -> [Dependency]
          flattenDep [] = []
          flattenDep (DependAllOf ds:xs) = (concatMap (\x -> flattenDep [x]) ds) ++ flattenDep xs
          flattenDep (x:xs) = x:flattenDep xs
          -- TODO concat 2 dep either in the same group

getPackage :: Dependency -> Maybe PackageName
getPackage (DependAllOf _dependency) = Nothing
getPackage (Atom pn _dr _attrs) = Just pn
getPackage (DependAnyOf _dependency           ) = Nothing
getPackage (DependIfUse  _useFlag    _Dependency) = Nothing
{-
getUses  :: Dependency -> Maybe [UseFlag]
getUses (DependAllOf _d) = Nothing
getUses (Atom _pn _dr (DAttr _s u)) = Just u
getUses (DependAnyOf _d) = Nothing
getUses (DependIfUse _u _d) = Nothing

getSlot :: Dependency -> Maybe SlotDepend
getSlot (DependAllOf _d) = Nothing
getSlot (Atom _pn _dr (DAttr s _u)) = Just s
getSlot (DependAnyOf _d) = Nothing
getSlot (DependIfUse _u _d) = Nothing
-}

--
getPackagePart :: Dependency -> PackageName
getPackagePart dep = fromJust (getPackage dep)

-- | remove all Use dependencies that overlap with normal dependencies
simplifyUseDeps :: [Dependency]         -- list where use deps is taken
                    -> [Dependency]     -- list where common deps is taken
                    -> [Dependency]     -- result deps
simplifyUseDeps ds cs =
    let (u,o) = partition isUseDep ds
        c = mapMaybe getPackage cs
    in (mapMaybe (intersectD c) u)++o

intersectD :: [PackageName] -> Dependency -> Maybe Dependency
intersectD fs (DependIfUse u d) = intersectD fs d >>= Just . DependIfUse u
intersectD fs (DependAnyOf ds) =
    let ds' = mapMaybe (intersectD fs) ds
    in if null ds' then Nothing else Just (DependAnyOf ds')
intersectD fs (DependAllOf ds) =
    let ds' = mapMaybe (intersectD fs) ds
    in if null ds' then Nothing else Just (DependAllOf ds')
intersectD fs x =
    let pkg = fromJust $ getPackage x -- this is unsafe but will save from error later
    in if any (==pkg) fs then Nothing else Just x

isUseDep :: Dependency -> Bool
isUseDep (DependIfUse _ _) = True
isUseDep _ = False


sortDeps :: [Dependency] -> [Dependency]
sortDeps = sortBy dsort . map deeper
  where
    deeper :: Dependency -> Dependency
    deeper (DependIfUse u1 d) = DependIfUse u1 $ deeper d
    deeper (DependAllOf ds)   = DependAllOf $ sortDeps ds
    deeper (DependAnyOf ds)  = DependAnyOf $ sortDeps ds
    deeper x = x
    dsort :: Dependency -> Dependency -> Ordering
    dsort (DependIfUse u1 _) (DependIfUse u2 _) = u1 `compare` u2
    dsort (DependIfUse _ _)  (DependAnyOf _)   = LT
    dsort (DependIfUse _ _)  (DependAllOf  _)   = LT
    dsort (DependIfUse _ _)  _                  = GT
    dsort (DependAnyOf _)   (DependAnyOf _)   = EQ
    dsort (DependAnyOf _)  (DependIfUse _ _)   = GT
    dsort (DependAnyOf _)   (DependAllOf _)    = LT
    dsort (DependAnyOf _)   _                  = GT
    dsort (DependAllOf _)    (DependAllOf _)    = EQ
    dsort (DependAllOf _)    (DependIfUse  _ _) = LT
    dsort (DependAllOf _)    (DependAnyOf _)   = GT
    dsort _ (DependIfUse _ _)                   = LT
    dsort _ (DependAllOf _)                     = LT
    dsort _ (DependAnyOf _)                    = LT
    dsort a b = (compare `on` getPackage) a b
