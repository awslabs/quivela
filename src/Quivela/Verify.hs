{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE PatternSynonyms #-}
module Quivela.Verify where

import Control.Applicative ((<$>))
import Control.Arrow (second)
import Control.Monad
import Control.Lens hiding (Context(..), rewrite)
import Control.Lens.At
import Control.Monad.RWS.Strict
import Control.Monad.List
import qualified Data.ByteString as BS
import Data.Generics hiding (Generic)
import Data.List
import Data.Function
import Data.Data
import Data.Maybe
import Data.Serialize (get, put, Serialize(..), encode, decode)
import Data.Typeable
import Debug.Trace
import qualified Data.Map as M
import qualified Data.Map.Merge.Lazy as M
import qualified Data.Set as S
import GHC.Generics (Generic)
import System.Directory
import System.Exit
import System.Microtimer
import System.IO
import System.IO.Temp
import System.Process

import Quivela.Language
import Quivela.SymEval
import Quivela.Parse
import Quivela.VerifyPreludes

-- | Invariants; only the equality invariants are relational right now.
data Invariant = EqualInv (Addr -> Context -> Value) (Addr -> Context -> Value)
  -- ^ Equality of a value from the LHS and RHS contexts
  | Rewrite Expr Expr
  | NoInfer -- ^ turn off proof hint inference for this step
  | IgnoreCache -- ^ Don't use verification cache when checking this step
  | Infer -- ^ Try to automatically infer proof hints
  -- ^ Rewriting with an assumption. Currently we only support a single
  -- rewrite hint in each proof step
  | Admit
  -- ^ Don't check this step
  deriving Generic

-- | A type class for types that only support equality partially. Whenever @(a === b) == Just x@,
-- then the boolean x indicates that a and b are equal/unequal. Otherwise, it cannot be determined
-- if the two values are equal
class PartialEq a where
  (===) :: a -> a -> Maybe Bool

instance PartialEq Invariant where
  NoInfer === NoInfer = Just True
  NoInfer === _ = Just False
  _ === NoInfer = Just False
  Rewrite e1 e2 === Rewrite e1' e2' = Just (e1 == e1' && e2 == e2')
  Rewrite _ _ === _ = Just False
  Admit === Admit = Just True
  Admit === _ = Just False
  EqualInv _ _ === EqualInv _ _ = Nothing
  EqualInv _ _ === _ = Just False
  Infer === Infer = Just True
  Infer === _ = Just False
  IgnoreCache === IgnoreCache = Just True
  IgnoreCache === _ = Just False

-- | Verification conditions
data VC = VC { _conditionName :: String
             -- ^ Purely for readability purposes when generating code for other solvers
             , _assumptions :: [Prop]
             , _goal :: Prop }
          deriving (Read, Ord, Eq, Data, Typeable)
makeLenses ''VC

-- | A monad for emitting code for external tools. In addition to state
-- to keep track of fresh variables, this also includes a writer monad
-- to collect all emitted lines.
newtype Emitter a = Emitter { unEmitter :: RWST () [String] EmitterState IO a }
  deriving (Functor, Applicative, Monad, MonadState EmitterState,
            MonadWriter [String], MonadIO)

data EmitterState = EmitterState { _nextEmitterVar :: M.Map String Integer
                                 , _varTranslations :: M.Map String String
                                 , _usedVars :: [(String, String)]
                                 -- ^ Stores generated fresh variables and their type in the solver
                                 }
  deriving (Read, Show, Eq, Ord, Data, Typeable)

makeLenses ''EmitterState

-- | Havoc a local variable if it's not an immutable variable
havocLocal :: Var -> Local -> Verify Local
havocLocal name l
  | not (view localImmutable l) = do
      fv <- freshVar name
      return $ set (localValue) (Sym (SymVar fv (l ^. localType))) l
  | otherwise = return l

-- | Havoc all non-immutable locals of an object
havocObj :: Object -> Verify Object
havocObj obj
  | obj ^. objAdversary = return obj -- this is a hack, since we currently don't
  -- support const annotations on global variables
  | otherwise = do
    newLocals <- mapM (\(name, loc) -> (name,) <$> havocLocal name loc)
      (M.toList (obj ^. objLocals))
    return (set objLocals (M.fromList newLocals) obj)

-- | Havoc all objects in a context
havocContext :: Context -> Verify Context
havocContext = everywhereM (mkM havocObj)

-- | Return an initial state for the verifier monad
newVerifyState :: IO VerifyState
newVerifyState = do
  (Just hin, Just hout, _, procHandle) <- createProcess $ (proc "z3" ["-in"]){ std_out = CreatePipe, std_in = CreatePipe, std_err = CreatePipe }
  hSetBuffering hin NoBuffering
  hSetBuffering hout NoBuffering
  hPutStrLn hin z3Prelude
  verificationCache <- do
    exists <- doesFileExist "cache.bin"
    if exists
    then do
      maybeCache <- decode <$> liftIO (BS.readFile "cache.bin")
      case maybeCache of
        Right cache -> return cache
        Left err -> return S.empty
    else return S.empty
  return VerifyState { _nextVar = M.empty
                     , _alreadyVerified = verificationCache
                     , _z3Proc = (hin, hout, procHandle) }

-- | Run a Verify action
runVerify :: VerifyEnv -> Verify a -> IO a
runVerify env action = do
  initState <- newVerifyState
  (res, state, _) <- runRWST (unVerify action) env initState
  return res

emptyVC = VC { _conditionName = "vc"
             , _assumptions = []
             , _goal = PTrue }

-- Not technically a correct show instance, since it's not an inverse of `read`
instance Show VC where
  show (VC name assms goal) =
    unlines [ "\nName: " ++ name
            , "\nAssumptions: "
            , intercalate "\n" (map show assms)
            , "Goal: "
            , show goal ]

-- | Check if the assumptions are trivially contradictory
assumptionsContradictory :: [Prop] -> Bool
assumptionsContradictory assms =
  any (\asm -> case asm of
          Not p -> any (\asm' -> asm' == p) assms -- FIXME: this probably shouldn't be quadratic
          _ -> False) assms

-- | Check if the goal is trivial (equalities like x = x, a goal occurring as an assumption,
-- and having both P and (not P) as an assumption)
triviallyTrue :: VC -> Verify Bool
triviallyTrue vc
  | v1 :=: v1' <- vc ^. goal =
      return $ (v1 == v1') ||
      assumptionsContradictory (vc ^. assumptions)
  | (vc ^. goal) `elem` (vc ^. assumptions) = return True
  | otherwise = return False

-- | Rewrite all values that match the LHS of an equality invariant by its RHS.
rewriteInv :: Data p => Addr -> Context -> Addr -> Context -> Invariant -> p -> p
rewriteInv addrL ctxL addrR ctxR (EqualInv f g) x = everywhere (mkT replace) x
  where lhs = f addrL ctxL
        rhs = g addrR ctxR
        replace :: Value -> Value
        replace v | v == lhs = rhs
                  | otherwise= v
rewriteInv _ ctxL _ ctxR _ x = x

-- | Rewrite with a list of invariants. This ignores all non-equality invariants
rewriteEqInvs :: Data p => Addr -> Context -> Addr -> Context -> [Invariant] -> p -> p
rewriteEqInvs addrL ctxL addrR ctxR invs vc =
  foldr (rewriteInv addrL ctxL addrR ctxR) vc invs


-- | Compute all relational proof obligations generated by an invariant
invToVC :: [Prop] -> Addr -> Result -> Addr -> Result -> Invariant -> Verify [VC]
invToVC assms addrL (_, ctxL, pathCondL) addrR (_, ctxR, pathCondR) inv =
  case inv of
    EqualInv f g -> return $
                    [emptyVC { _assumptions = nub $ pathCondL ++ pathCondR ++ assms
                             , _conditionName = "equalInvPreserved"
                             , _goal = f addrL ctxL :=: g addrR ctxR }]
    _ -> return []

-- | Convert an invariant into assumptions. Note that for universal
-- invariants, this produces several assumptions.
invToAsm :: Result -> Result -> Invariant -> Verify [Prop]
invToAsm (VRef addrL, ctxL, pathCondL) (VRef addrR, ctxR, pathCondR) inv =
  case inv of
    EqualInv f g -> return [f addrL ctxL :=: g addrR ctxR]
    _ -> return []
invToAsm (v1, _, _) (v1', _ ,_) _ = error "invToAsm called with non-address arguments"

conjunction :: [Prop] -> Prop
conjunction [] = PTrue
conjunction [p] = p
conjunction ps = foldr1 (:&:) ps

-- | Return all invariant methods in given context
collectInvariants :: Addr -> Context -> [Method]
collectInvariants addr ctx =
  filter (\mtd -> mtd ^. isInvariant) . M.elems $ ctx ^. ctxObjs . ix addr . objMethods

-- | Return all non-relational proof obligations generated by invariants
invToVCnonRelational :: [Prop] -> Addr -> Result -> Invariant -> Verify [VC]
invToVCnonRelational assms addr res@(v, ctx, pathCond) inv = do
  let univInvs = collectInvariants addr ctx
  fmap concat . forM univInvs $ \univInv -> do
    let formals = univInv ^. methodFormals
    (args, ctx', pathCond') <- symArgs ctx formals
    let scope = M.fromList (zip (map fst formals)
                                (zip args (map snd formals)))
    paths <- symEval ( univInv ^. methodBody, set ctxThis addr (set ctxScope scope ctx')
                     , pathCond' ++ pathCond)
    foreachM (return $ paths) $ \(res, ctxI, pathCondI) ->
      return $ [VC { _assumptions = nub $ pathCondI ++ assms
                   , _conditionName = "univInvPreserved_" ++ (univInv ^. methodName)
                   , _goal = Not (res :=: VError) }]

onlySimpleTypes :: Data p => p -> Verify ()
onlySimpleTypes foo = when (not . null . listify isNamed $ foo)
        (error $ "Symbolic objects as method arguments not yet supported")
  where isNamed :: Type -> Bool
        isNamed (TNamed _) = True
        isNamed _ = False

-- | Return a list of all reference values occurring in some data
collectRefs :: Data p => p -> [Value]
collectRefs = listify isRef
  where isRef (VRef _) = True
        isRef _ = False


-- | Substitute x by v in p
substSymVar :: Var -> Value -> Prop -> Prop
substSymVar x v p = everywhereBut (mkQ False binds) (mkT replace) p
  where binds (Forall vs e) = x `elem` map fst vs
        binds _ = False
        replace (Sym (SymVar y t)) | x == y = v
        replace e = e

-- To make Z3 cope with forall quantifications better, make sure there are no forall-quantified
-- variables x occurring in one assumption of the form (x = E) by replacing x by E in the
-- rest of the formula.
onePointTransform :: [(Var, Type)] -> [Prop] -> Prop -> ([(Var, Type)], [Prop], Prop)
onePointTransform vs assms conseq = foldr removeVar (vs, assms, conseq) spuriousAssms
  where spuriousAssms = catMaybes $
          map (\x -> listToMaybe . catMaybes $
           map (\assm -> case assm of
                           Sym (SymVar y t) :=: e -> if y == x then Just (x, e, assm) else Nothing
                           e :=: Sym (SymVar y t) -> if y == x then Just (x, e, assm) else Nothing
                           _ -> Nothing) assms) (map fst vs)
        removeVar (spurVar, spurExpr, origAssm) (vs', assms', conseq') =
          ( filter ((/= spurVar) . fst) vs'
          , map (substSymVar spurVar spurExpr) . filter (/= origAssm) $ assms'
          , substSymVar spurVar spurExpr conseq' )

universalInvariantAssms :: Addr -> Context -> PathCond -> Verify [Prop]
universalInvariantAssms addr ctx pathCond =
  fmap concat . forM (collectInvariants addr ctx) $ \invariantMethod -> do
    let formals = invariantMethod ^. methodFormals
    onlySimpleTypes formals
    (args, ctx', pathCond') <- symArgs ctx formals
    let scope = M.fromList (zip (map fst formals)
                                (zip args (map snd formals)))
    let oldRefs = collectRefs ctx'
    let oldSymVars = collectSymVars ctx'
    paths <- symEval (invariantMethod ^. methodBody, set ctxThis addr (set ctxScope scope ctx), pathCond' ++ pathCond)
    let argNames = map (\(Sym (SymVar name t)) -> (name, t)) args
    foreachM (return paths) $ \(res, ctxI, pathCondI) -> do
      -- If there were symbolic objects created on demand, we may now have a bunch
      -- of extra symbolic variables that were introduced. Since these are going
      -- to be arbitrary parameters, we have to quantify over them as well here:
      -- TODO: check for duplicate symvars of different types
      let newSymVars = collectSymVars (res, ctxI, pathCondI) \\ oldSymVars
      let newRefs = map (\(VRef a) -> a) $ collectRefs (res, ctxI, pathCondI) \\ oldRefs
      refVars <- mapM (freshVar . ("symref" ++) . show) newRefs
      let replaceRef :: Data p => Addr -> Value -> p -> p
          replaceRef a v = everywhere (mkT replace)
            where replace (VRef a') | a == a' = v
                                    | otherwise = VRef a'
                  replace x = x
          replaceAllRefs :: Data p => p -> p
          replaceAllRefs x = foldr (\(ref, symref) p -> replaceRef ref symref p) x
                                   (zip newRefs (map (Sym . SymRef) refVars))
          (vs, assms, conseq) = onePointTransform (nub $ argNames ++ map ((, TInt)) refVars ++ newSymVars)
                                                  pathCondI (Not (res :=: VInt 0))
      return $ replaceAllRefs [Forall vs (conjunction assms :=>: conseq)]

-- | Type synonym for building up bijections between addresses
type AddrBijection = M.Map Addr Addr

tryInsert :: (Show k, Show v, Ord k, Eq k, Eq v) => k -> v -> M.Map k v -> M.Map k v
tryInsert k v m
  | Just v' <- M.lookup k m = if v == v' then m
                              else error "Duplicate conflicting mapping"
  | otherwise =
    case M.keys $ M.filterWithKey (\k' v' -> v' == v) m of
      ks' | not (all (== k) ks') ->
            error $ "Error when trying to remap address: " ++ show k ++ ": "
                  ++ show ks' ++ " are also mapped to: " ++  show v
      _ -> M.insert k v m

-- | Try to find a mapping for addresses that may make the two values equal.
unifyAddrs :: Value -> Value -> AddrBijection -> AddrBijection
unifyAddrs (VInt i1) (VInt i2) bij = bij
unifyAddrs (VMap vs1) (VMap vs2) bij =
  foldr (\(v1, v2) bij' -> unifyAddrs v1 v2 bij') bij
          (M.elems $ M.merge M.dropMissing M.dropMissing
                             (M.zipWithMatched (\k v1 v2 -> (v1, v2))) vs1 vs2)
unifyAddrs (VTuple vs1) (VTuple vs2) bij =
  foldr (\(v1, v2) bij' -> unifyAddrs v1 v2 bij') bij (zip vs1 vs2)
unifyAddrs (VRef a1) (VRef a2) bij
  | a2 >= 0 = tryInsert a2 a2 bij -- we only want to remap RHS addresses, which are always negative
  | M.lookup a2 bij == Just a1 || M.lookup a2 bij == Nothing =
    M.insert a2 a1 bij
unifyAddrs _ _ bij = bij

allAddrs :: Data p => p -> [Addr]
allAddrs = nub . map fromRef . listify isAddr
  where isAddr (Ref a) = True
        isAddr _ = False
        fromRef (Ref a) = a
        fromRef x = error "fromRef called with non-Ref argument"

-- | Try to find a bijection between addresses to be applied to the right-hand
-- side to make both sides possible to be proven equal. This is a best-effort
-- process and may not return a mapping that actually makes them equal, and may
-- not be complete.
findAddressBijection :: Result -> Result -> AddrBijection
findAddressBijection (v, ctx, pathCond) (v', ctx', pathCond') =
  let baseMap = unifyAddrs v v' M.empty
      remainingLHSRefs = allAddrs (v, pathCond) \\ M.elems baseMap
      remainingRHSRefs = allAddrs (v', pathCond') \\ M.keys baseMap
  in extendMap baseMap remainingRHSRefs remainingLHSRefs
  where extendMap base [] addrPool = base
        extendMap base (a : as) (p : ps)
          | a >= 0 = tryInsert a a (extendMap base as (p:ps))
        extendMap base (a : as) (p : ps) = tryInsert a p (extendMap base as ps)
        extendMap base (a : as) [] = tryInsert a (nextFreeAddr base) (extendMap base as [])
        nextFreeAddr m = maximum (M.elems m) + 1

-- | Remap all addresses in a piece of data with given bijection.
applyAddressBijection :: Data p => AddrBijection -> p -> p
applyAddressBijection addrMap = everywhere (mkT replaceAddress)
  where replaceAddress :: SymValue -> SymValue
        replaceAddress (Ref addr)
          | addr >= 0 = Ref addr -- new RHS addresses are always negative
          | Just newAddr <- M.lookup addr addrMap = Ref newAddr
          | otherwise = error $ "No mapping for address: " ++ show addr ++ " in " ++ show addrMap
        replaceAddress v = v

-- | Generate the verification conditions for two sets of results (i.e.
-- configurations returned by evaluating a method call with symbolic arguments
-- in a havoced context). Also takes the old havoced environments as arguments
-- to turn invariants into assumptions.
resultsToVCs :: [Invariant] -> Result -> Results -> Result -> Results -> Verify [VC]
resultsToVCs invs old@(VRef addr1, ctxH, pathCondH) ress1 old'@(VRef addr1', ctxH', pathCondH') ress1' = do
  invAssms <- (++) <$> universalInvariantAssms addr1 ctxH pathCondH
                   <*> universalInvariantAssms addr1' ctxH' pathCondH'
  assms <- (invAssms++) . concat <$> mapM (invToAsm old old') invs
  -- Invariant methods aren't relational and hence we don't need to check them for each pair of
  -- of paths:
  lhsInvVCs <- foreachM (return ress1) $ \res1 -> do
    concat <$> mapM (invToVCnonRelational assms addr1 res1) invs
  rhsInvVCs <- foreachM (return ress1') $ \res1' -> do
    concat <$> mapM (invToVCnonRelational assms addr1' res1') invs
  relationalVCs <-
    foreachM (return ress1) $ \res1@(v1, ctx1, pc1) ->
      foreachM (return ress1') $ \res1'@(v1', ctx1', pc1') -> do
        let simp = rewriteEqInvs addr1 ctx1 addr1' ctx1' invs
            simp' = rewriteEqInvs addr1 ctx1 addr1' ctx1' invs
        -- when (not . null . allAddrs $ v1') $
        --   debug ("Trying to find address bijection for: " ++ show (v1, v1'))
        let addrMap = findAddressBijection res1 res1'
        -- Note that it's fine to only use the address bijection for relational proof
        -- obligations, since non-relational VCs should can not depend on concrete addresses
        -- that the allocator chose.
        when (not . null . allAddrs $ v1') $
          debug ("Using address bijection: " ++ show addrMap)
        let vcRes = simp $ VC { _assumptions = applyAddressBijection addrMap $ nub $ assms ++ pc1 ++ pc1'
                              , _conditionName = "resultsEq"
                              , _goal = simp' (v1 :=: applyAddressBijection addrMap v1') }
        invVCs <-
          if ctx1 == ctxH && ctx1' == ctxH'
          then return []
          else concat <$> mapM (fmap (map simp) .
                                invToVC assms addr1 res1 addr1' res1') invs
        -- Require that adversary was called with same values:
        let vcAdv = VC { _assumptions = applyAddressBijection addrMap $ nub $ assms ++ map simp' (nub $ pc1 ++ pc1' ++ assms)
                       , _conditionName = "advCallsEq"
                       , _goal = simp' $ Sym (AdversaryCall (ctx1 ^. ctxAdvCalls)) :=:
                                         Sym (AdversaryCall (ctx1' ^. ctxAdvCalls)) }
        return $ vcRes : vcAdv : invVCs
  return $ relationalVCs ++ lhsInvVCs ++ rhsInvVCs
resultsToVCs invs (v1, _, _) _ (v1', _, _) _ =
  error $ "resultsToVCs called with non-address values" ++ show (v1, v1')


-- | Collect non-trivial verification conditions for a given method, invariants and arguments
methodEquivalenceVCs :: Method -> [Invariant] -> [Value] -> Result -> Result -> Verify [VC]
methodEquivalenceVCs mtd invs args
                     (VRef a1, ctx1, pathCond1)
                     (VRef a1', ctx1', pathCond1') = do
  ctxH1 <- havocContext ctx1
  ctxH1' <- havocContext ctx1'
  results <- symEval (ECall (EConst (VRef a1)) (mtd ^. methodName) (map EConst  args), ctxH1, pathCond1)
  results' <- symEval ( ECall (EConst (VRef a1')) (mtd ^. methodName) (map EConst  args)
                      , set ctxAllocStrategy Decrease ctxH1'
                      , pathCond1')
  vcs <- resultsToVCs invs (VRef a1, ctxH1, pathCond1) results (VRef a1', ctxH1', pathCond1') results'
  -- debug $ "VCs before pruning: " ++ show (length vcs)
  filterM (\vc -> do
                   trivial <- triviallyTrue vc
                   if trivial
                     then do
                     -- debug $ "Discarding VC as trivial: " ++ show vc
                     return False
                     else return True) vcs
methodEquivalenceVCs mtd invs args (v1, _, _) (v1', _, _) =
  error $ "methodEquivalenceVCs called with non-reference values: " ++ show (v1, v1')


-- | Helper function for writing equality invariants. Produces an exception
-- if the chain of fields doesn't exist in the given context.
getField :: [Var] -> Addr -> Context -> Value
getField [] _ _ = error "Empty list of fields"
getField [x] addr ctx
  | Just v <- ctx ^? ctxObjs . ix addr . objLocals . ix x . localValue = v
  | otherwise = error $ "getField: No such field: " ++ x
getField (x : xs) addr ctx
  | Just (VRef addr') <- ctx ^? ctxObjs . ix addr . objLocals . ix x . localValue =
      getField xs addr' ctx
  | otherwise = error $ "Non-reference in field lookup"

-- | Find the shared methods between two objects in their respective contexts
sharedMethods :: Addr -> Context -> Addr -> Context -> [Method]
sharedMethods addrL ctxL addrR ctxR
  | Just objL <- ctxL ^? ctxObjs . ix addrL,
    Just objR <- ctxR ^? ctxObjs . ix addrR =
  let mtdsL = objL ^. objMethods
      mtdsR = objR ^. objMethods
      sharedNames = M.keys mtdsL `intersect` M.keys mtdsR
  -- TODO: check that there are no extraneous methods and that they
  -- take the same number (and type) of arguments
  in filter (not . (^. isInvariant)) . map (fromJust . (`M.lookup` mtdsL)) $ sharedNames
  | otherwise = error "Invalid addresses passed to sharedMethods"

-- TODO: merge with previous implementation
freshEmitterVar :: String -> String -> Emitter String
freshEmitterVar prefix' typ = do
  let prefix = filter (`notElem` "?") prefix'
  last <- use (nextEmitterVar . at prefix)
  case last of
    Just n -> do
      nextEmitterVar . ix prefix %= (+1)
      let varName = prefix ++ show n
      usedVars %= ((varName, typ) :)
      return varName
    Nothing -> do
      modify (nextEmitterVar . at prefix ?~ 0)
      freshEmitterVar prefix typ

emit :: String -> Emitter ()
emit = tell . (:[])


-- | Translate a variable name. Caches the result for each variable
-- name so when called with the same variable name again, it will return the same result
-- to make sure that each variable receives a fresh identifier and other occurrences of
-- the same variable receive the same name.
translateVar :: String -> String -> Emitter String
translateVar v typ = do
  translated <- gets (\s -> s ^? (varTranslations . ix v))
  case translated of
    Just tv -> return tv
    Nothing -> do
      tv <- freshEmitterVar v typ -- TODO: think if we really need something fresh here, since
      -- we're only using this with fresh variables generated by the VCG
      modify (\s -> varTranslations . at v ?~ tv $ s)
      return tv

-- | Collect all free symbolic variables occurring in some data
-- Only forall statements are considered as variable binders.
collectSymVars :: Data p => p -> [(Var, Type)]
collectSymVars vc =
  nubBy ((==) `on` fst) . map toTup $ everythingWithContext [] (++) (mkQ ((,) []) collect `extQ` propBind) vc
  where collect (SymVar x t) bound
          | x `notElem` bound = ([SymVar x t], bound)
          | otherwise = ([], bound)
        collect _ bound = ([], bound)
        propBind (Forall formals x) bound = ([], bound ++ map fst formals)
        propBind _ bound = ([], bound)
        toTup (SymVar x t) = (x, t)
        toTup _ = undefined

symVarName :: SymValue -> Var
symVarName (SymVar n t) = n
symVarName x = error "symVarName: Not a SymVar: " ++ show x

-- | Type class for things that can be converted into Dafny terms
class ToDafny a where
  toDafny :: a -> Emitter String

listToDafny :: ToDafny a => [a] -> Emitter String
listToDafny [] = return "LNil()"
listToDafny (v : vs) = do
  car <- toDafny v
  cdr <- listToDafny vs
  return $ "Cons(" ++ car ++ ", " ++ cdr ++ ")"

instance ToDafny a => ToDafny [a] where
  toDafny = listToDafny

instance ToDafny Value where
  toDafny = valueToDafny

instance (ToDafny a, ToDafny b) => ToDafny (a, b) where
  toDafny (a, b) = do
    car <- toDafny a
    cdr <- toDafny b
    return $ "Pair(" ++ car ++ ", " ++ cdr ++ ")"

concatM = fmap concat . sequence

instance ToDafny SymValue where
  toDafny = symValToDafny

dafnyFunCall :: String -> [String] -> String
dafnyFunCall f args = f ++ "(" ++ intercalate ", " args ++ ")"

symValToDafny :: SymValue -> Emitter String
symValToDafny (SymVar s t) = translateVar s "Value"
symValToDafny (Insert k v m) =
  dafnyFunCall "Insert" <$> mapM toDafny [k, v, m]
symValToDafny (Lookup k m) =
  dafnyFunCall "Lookup" <$> mapM toDafny [k, m]
symValToDafny (Proj tup idx) =
  dafnyFunCall "Proj" <$> mapM toDafny [tup, idx]
symValToDafny (AdversaryCall advCalls) =
  dafnyFunCall "Adversary" . (:[]) <$> toDafny advCalls
symValToDafny (Add e1 e2) =
  dafnyFunCall "Add" <$> mapM toDafny [e1, e2]
symValToDafny (Mul e1 e2) =
  dafnyFunCall "Mul" <$> mapM toDafny [e1, e2]
symValToDafny (Sub e1 e2) =
  dafnyFunCall "Sub" <$> mapM toDafny [e1, e2]
symValToDafny (Div e1 e2) =
  dafnyFunCall "Div" <$> mapM toDafny [e1, e2]
symValToDafny (Le e1 e2) =
  dafnyFunCall "Le" <$> mapM toDafny [e1, e2]
symValToDafny (ITE tst thn els) = do
  tstDafny <- toDafny tst
  [thnDafny, elsDafny] <- mapM toDafny [thn, els]
  return $ "(if " ++ tstDafny ++ " then " ++ thnDafny ++ " else " ++ elsDafny ++ ")"
symValToDafny (Ref a) = return $ "VRef(" ++ show a ++ ")"
symValToDafny (SymRef s) = dafnyFunCall "VRef" <$> sequence [translateVar s "int"]
symValToDafny (Deref obj field) =
  dafnyFunCall "Deref" <$> sequence [toDafny obj, pure ("\"" ++ field ++ "\"")]
-- symValToDafny e = error $ "symValToDafny: unhandled: " ++ show e

valueToDafny :: Value -> Emitter String
valueToDafny (VInt i) = return $ "Int(" ++ show i ++ ")"
valueToDafny (VTuple vs) = concatM [pure "Tuple(", toDafny vs, pure ")"]
valueToDafny (VMap m) = concatM [pure "Map(", toDafny (M.toList m), pure ")"]
valueToDafny VNil = return "Nil()"
valueToDafny VError = return "Error()"
valueToDafny (Sym sv) = symValToDafny sv

instance ToDafny Prop where
  toDafny = propToDafny

propToDafny :: Prop -> Emitter String
propToDafny (x :=: y) = concatM [valueToDafny x, pure " == ", valueToDafny y]
propToDafny (Not (x :=: y)) = concatM [toDafny x, pure " != ", toDafny y]
propToDafny (Not p) = concatM [pure "!", pure "(", propToDafny p, pure ")"]
propToDafny PTrue = return "true"
propToDafny PFalse = return "false"
propToDafny (p1 :&: p2) = concatM [ pure "("
                                  , toDafny p1
                                  , pure ") && ("
                                  , toDafny p2
                                  , pure ")" ]
propToDafny (p1 :=>: p2) = concatM [ pure "(", toDafny p1
                                   , pure ") ==> ("
                                   , toDafny p2
                                   , pure ")" ]
propToDafny (Forall [] p) = toDafny p
propToDafny (Forall formals p) =
  concatM [ pure "forall "
          , intercalate ", " . map ((++ ": Value")) <$> mapM (\(x, t) -> translateVar x "Value") formals
          , pure " :: "
          , toDafny p ]

asmToDafny :: Prop -> Emitter ()
asmToDafny p =
  emit . ("  requires "++) =<< propToDafny p

vcToDafny :: VC -> Emitter ()
vcToDafny vc = do
  lemName <- (`freshEmitterVar` "_unused") $ vc ^. conditionName
  lemArgs <- mapM (\(x, t) -> translateVar x "Value") $ collectSymVars vc
  emit $ "lemma " ++ lemName ++ "(" ++ intercalate ", " (map (++ ": Value") lemArgs) ++ ")"
  mapM_ asmToDafny (vc ^. assumptions)
  dafnyGoal <- propToDafny $ vc ^. goal
  emit $ "  ensures " ++ dafnyGoal
  emit $ "{ LookupSame(); LookupDifferent(); }"

initialEmitterState = EmitterState { _nextEmitterVar = M.empty
                                   , _usedVars = []
                                   , _varTranslations = M.empty }

runEmitter :: MonadIO m => Emitter a -> m (a, [String])
runEmitter action = liftIO $ evalRWST (unEmitter action) () initialEmitterState

-- | Try to verify a list of verification conditions with dafny
checkWithDafny :: MonadIO m => [VC] -> m Bool
checkWithDafny [] = return True
checkWithDafny vcs = do
  debug $ "Checking " ++ show (length vcs) ++ " VCs with Dafny"
  (_, lines) <- runEmitter $ do
    emit dafnyPrelude
    mapM_ vcToDafny vcs
  tempFile <- liftIO $ writeTempFile "." "dafny-vc.dfy" (unlines lines)
  debug $ "Dafny code written to " ++ tempFile
  (code, out, err) <- liftIO $ readCreateProcessWithExitCode (proc "time"
    ["dafny", "/compile:0", tempFile]) ""
  if code == ExitSuccess
    then do
      debug "Verification succeeded"
      debug err
      return True
    else do
      debug $ "Verification failed\n:stdout:\n" ++ out ++ "\nstderr:\n" ++ err
      return False

-- | Type class for values that can be converted into Z3 terms/formulas
class ToZ3 a where
  toZ3 :: a -> Emitter String

z3Call :: String -> [String] -> String
z3Call fun args = "(" ++ fun ++ " " ++ intercalate " " args ++ ")"

-- | Return an s-expression of applying the first argument to a list things that
-- can be converted to z3 expressions
z3CallM :: (ToZ3 a) => String -> [a] -> Emitter String
z3CallM fun args = z3Call fun <$> mapM toZ3 args

typeToZ3 :: Type -> Emitter String
typeToZ3 TAny = return "Value"
typeToZ3 TInt = return "Int"
typeToZ3 _ = return "Value"

propToZ3 :: Prop -> Emitter String
propToZ3 PTrue = return "true"
propToZ3 PFalse = return "false"
propToZ3 (Not p) = z3CallM "not" [p]
propToZ3 (x :=: y) = z3CallM "="  [x, y]
propToZ3 (x :=>: y) = z3CallM "=>" [x, y]
propToZ3 (x :&: y) = z3CallM "and" [x, y]
propToZ3 (Forall [] p) = toZ3 p
propToZ3 (Forall formals p) = do
  argNames <- mapM (\(x, t) -> (,) <$> (translateVar x =<< typeToZ3 t) <*> pure t) formals
  concatM [ pure "(forall ("
          , intercalate " " <$> mapM (\(n, t) -> do
                                         typ <- typeToZ3 t
                                         return $ "(" ++ n ++ " " ++ typ ++ ")") argNames
          , pure ") "
          , toZ3 p
          , pure ")" ]

instance ToZ3 Prop where
  toZ3 = propToZ3

-- To make life easier for Z3, we keep all the data types involved monomorphic,
-- so we have separate types in Z3 for values, lists of values, and lists of lists of values:
valuesToZ3 :: [Value] -> Emitter String
valuesToZ3 [] = return "nil"
valuesToZ3 (v : vs) = z3Call "cons" <$> sequence [toZ3 v, valuesToZ3 vs]

valuessToZ3 :: [[Value]] -> Emitter String
valuessToZ3 [] = return "nils"
valuessToZ3 (vs : vss) = z3Call "conss" <$> sequence [valuesToZ3 vs, valuessToZ3 vss]

valueToZ3 :: Value -> Emitter String
valueToZ3 (VInt i) = return $ z3Call "VInt" [show i]
valueToZ3 VError = return "VError"
valueToZ3 (VTuple vs) = z3Call "VTuple" <$> sequence [valuesToZ3 vs]
valueToZ3 (VMap map) = freshEmitterVar "map" "Value" -- TODO: map same maps to same variable
valueToZ3 VNil = return "VNil"
valueToZ3 (Sym (Ref addr)) =
  return $ z3Call "vref" [show addr] -- vref is an uninterpreted function instead of a constructor
valueToZ3 (Sym sv) = symValueToZ3 sv

symValueToZ3 :: SymValue -> Emitter String
symValueToZ3 (SymVar x t) =
  case t of
    TInt -> z3Call "VInt" <$> sequence [translateVar x "Int"]
    _ -> translateVar x "Value"
symValueToZ3 (Insert k v m) = z3CallM "insert" [k, v, m]
symValueToZ3 (Lookup k m) = z3CallM "lookup" [k, m]
symValueToZ3 (AdversaryCall vss) = z3Call "adversary" <$> sequence [valuessToZ3 vss]
symValueToZ3 (Proj tup idx) = z3CallM "proj" [tup, idx]
symValueToZ3 (Add v1 v2) = z3CallM "add" [v1, v2]
symValueToZ3 (Sub v1 v2) = z3CallM "sub" [v1, v2]
symValueToZ3 (Mul v1 v2) = z3CallM "mul" [v1, v2]
symValueToZ3 (Div v1 v2) = z3CallM "divi" [v1, v2]
symValueToZ3 (Le v1 v2) = z3CallM "le" [v1, v2]
symValueToZ3 (ITE tst thn els) = z3Call "ite" <$> sequence [toZ3 tst, toZ3 thn, toZ3 els]
symValueToZ3 (SymRef name) = z3Call "vref" <$> sequence [translateVar name "Int"]
symValueToZ3 (Deref obj name) = z3Call "deref" <$> sequence [toZ3 obj, pure ("\"" ++ name ++ "\"")]
symValueToZ3 (Ref a) = z3Call "vref" <$> sequence [toZ3 a]
-- symValueToZ3 x = error $ "symValueToZ3: unhandled value: " ++ show x

instance ToZ3 Integer where
  toZ3 = return . show

vcToZ3 :: VC -> Emitter ()
vcToZ3 vc = do
  emit $ ";; " ++ (vc ^. conditionName)
  translatedAssms <- mapM toZ3 (vc ^. assumptions)
  goalProp <- toZ3 (vc ^. goal)
  vars <- use usedVars
  forM vars $ \(var, typ) ->
    emit $ z3Call "declare-const" [var, typ]
  mapM (\asm -> emit (z3Call "assert" [asm])) translatedAssms
  emit $ z3Call "assert" [z3Call "not" [goalProp]]

sendToZ3 :: String -> Verify ()
sendToZ3 line = do
  (hin, _, _) <- use z3Proc
  liftIO $ hPutStrLn hin line

readLineFromZ3 :: Verify String
readLineFromZ3 = do
  (_, hout, _) <- use z3Proc
  liftIO $ hGetLine hout

checkWithZ3 :: VC -> Verify Bool
checkWithZ3 vc = do
  (_, vcLines) <- runEmitter $ vcToZ3 vc
  sendToZ3 "(push)"
  sendToZ3 (unlines vcLines)
  sendToZ3 "(check-sat)"
  answer <- readLineFromZ3
  sendToZ3 "(pop)"
  return $ "unsat" `isInfixOf` answer

instance ToZ3 Value where
  toZ3 = valueToZ3

instance ToZ3 SymValue where
  toZ3 = symValueToZ3

writeToZ3File :: VC -> Verify FilePath
writeToZ3File vc = do
  (_, vcLines) <- runEmitter $ vcToZ3 vc
  tempFile <- liftIO $ writeTempFile "." "z3-vc.smt2" $ unlines $ z3Prelude : vcLines ++ ["(check-sat)"]
  return tempFile

-- | Verify conditions with external solvers and return unverified conditions
checkVCs :: [VC] -> Verify [VC]
checkVCs [] = return []
checkVCs vcs = do
  debug $ show (length vcs) ++ " verification conditions"
  (t, vcs') <- time $ filterM (fmap not . checkWithZ3) vcs
  when (not . null $ vcs') $ do
    debug $ "Remaining VCs in Z3 files: "
    mapM_ (\vc -> writeToZ3File vc >>= \f -> liftIO (debug f)) vcs'
  debug $ show (length vcs') ++ " VCs left after checking with Z3 (" ++ formatSeconds t ++ ")"
  dafnyRes <- checkWithDafny vcs'
  -- currently we don't have a way to efficiently check just one VC with Dafny, so this
  -- is all or nothing:
  if dafnyRes then return [] else return vcs'

checkEqv :: Bool -> Expr -> [Invariant] -> Expr -> Expr -> Verify [(Var, [VC])]
checkEqv useSolvers prefix [Admit] lhs rhs = do
  -- debug $ "Skipping proof step: " ++ show lhs ++ " ~ " ++ show rhs
  return []
checkEqv useSolvers prefix [Rewrite from to] lhs rhs =
  if lhs' == rhs then return []
  else error $ "Invalid rewrite step:\n" ++ show lhs' ++ "\n/=\n" ++ show rhs
  where lhs' = rewriteExpr from to lhs
checkEqv useSolvers prefix invs lhs rhs = do
  cached <- S.member (lhs, rhs) <$> use alreadyVerified
  if cached && not (any ((== Just True) . (===IgnoreCache)) invs)
  then do
    debug "Skipping cached verification step"
    return []
  else do
    (_, prefixCtx, pathCond) <- fmap singleResult .
                                symEval $ (prefix, emptyCtx, [])
    res1@(VRef a1, ctx1, _) <- singleResult <$> symEval (lhs, prefixCtx, pathCond)
    res1'@(VRef a1', ctx1', _) <- singleResult <$> symEval (rhs, prefixCtx, pathCond)
    -- check that invariants hold initially
    invLHS <- concat <$> mapM (invToVCnonRelational [] a1 res1) invs
    invRHS <- concat <$> mapM (invToVCnonRelational [] a1' res1') invs
    invsRel <- concat <$> mapM (invToVC [] a1 res1 a1' res1') invs
    remainingInvVCs <- checkVCs (invLHS ++ invRHS ++ invsRel)
    let mtds = sharedMethods a1 ctx1 a1' ctx1'
    -- check that there are no other methods except invariants:
    let allMethods :: Addr -> Context -> S.Set String
        allMethods addr ctx = S.fromList . map (^. methodName)
                            . filter (not . (^. isInvariant))
                            . M.elems $ (ctx ^. ctxObjs . ix addr . objMethods)
        lhsMethods = allMethods a1 ctx1
        rhsMethods = allMethods a1' ctx1'
    when (lhsMethods /= rhsMethods) $ do
      -- FIXME: output which methods are the extra ones
      let extraMtds = (lhsMethods `S.difference` rhsMethods) `S.union`
                      (rhsMethods `S.difference` lhsMethods)
      error $ "LHS and RHS do not have the same non-invariant methods; extra methods: " ++ show extraMtds
    (t, remainingVCs) <- fmap (second ([("_invsInit", remainingInvVCs)] ++)) . time $ forM mtds $ \mtd -> do
      debug $ "Checking method: " ++ mtd ^. methodName
      onlySimpleTypes (mtd ^. methodFormals)
      (args, _, _) <- symArgs ctx1 (mtd ^. methodFormals)
      -- TODO: double-check that we don't need path condition here.
      vcs <- methodEquivalenceVCs mtd invs args res1 res1'
      verificationResult <- if useSolvers then checkVCs vcs else return vcs

      return (mtd ^. methodName, verificationResult)
    if (not . all (null . snd) $ remainingVCs)
    then do
      liftIO . putStrLn $ "Verification failed for step: " ++ show lhs ++ " ≈ " ++ show rhs
      liftIO $ print remainingVCs
    else do
      cacheVerified lhs rhs
      liftIO . putStrLn $ "Verification succeeded in " ++ formatSeconds t
    return remainingVCs

-- | Mark a pair of expressions as successfully verified in the cache
cacheVerified :: Expr -> Expr -> Verify ()
cacheVerified lhs rhs = do
  alreadyVerified %= S.insert (lhs, rhs)
  verified <- use alreadyVerified
  liftIO $ BS.writeFile "cache.bin" (encode verified)

-- | Check two quivela files for equivalence using a list of invariants. The
-- first quivela file contains shared global variables and method definitions
-- (The other two programs are evaluated in the context resulting from
-- evaluating the prefix file). If the first argument is False, external solvers
-- will not be used.
checkEqvFile :: Bool -> FilePath -> [Invariant] -> FilePath -> FilePath
         -> Verify [(Var, [VC])]
checkEqvFile verify prefixFile invs lhsFile rhsFile = do
  prefix <- parseFile prefixFile
  lhs <- parseFile lhsFile
  rhs <- parseFile rhsFile
  checkEqv verify prefix invs lhs rhs

-- | Quivela proofs are a series of equivalent expressions and a list of
-- invariants that are needed to verify this step.
type Step = (Expr, [Invariant], Expr)

-- | Check given list of steps and return a list of unverified VCs for each step
checkSteps :: Expr -> [Step] -> Verify [[(Var, [VC])]]
checkSteps prefix = mapM (\(lhs, invs, rhs) -> checkEqv True prefix invs lhs rhs)

-- | @'rewriteExpr' from to e@ rewrites all occurrences of @from@ in @e@ by @to@
-- TODO: take bound variables into account
rewriteExpr :: Expr -> Expr -> Expr -> Expr
rewriteExpr from to e = everywhere (mkT replace) e
  where replace :: Expr -> Expr
        replace e' | e' == from = to
                   | otherwise = e'

-- | Convenience function for expression that both sides agree on looking
-- up a series of fields. @[a, b, c]@ represents looking up field @a.b.c@.
fieldsEqual :: [Var] -> [Var] -> Invariant
fieldsEqual fieldsL fieldsR = EqualInv (getField fieldsL) (getField fieldsR)

-- | Like 'fieldsEqual' but looking up the same fields on both sides.
fieldEqual :: [Var] -> Invariant
fieldEqual fields = fieldsEqual fields fields

-- | Clears the proof cache
clearCache :: IO ()
clearCache = do
  exists <- doesFileExist "cache.bin"
  when exists $ removeFile "cache.bin"

commonVars :: [Var] -> Addr -> Context -> Addr -> Context -> [[Var]]
commonVars prefixFields addrL ctxL addrR ctxR
  | Just objL <- ctxL ^. ctxObjs . at addrL
  , Just objR <- ctxR ^. ctxObjs . at addrR =
      let common = M.filterWithKey (\field locL -> case objR ^. objLocals . at field of
                                                      Just locR ->
                                                        locL ^. localType == locR ^. localType &&
                                                        not (locL ^. localImmutable) &&
                                                        not (locR ^. localImmutable) &&
                                                        locL ^. localValue == locR ^. localValue
                                                      _ -> False)
                                   (objL ^. objLocals)
          commonObjs = M.mapWithKey (\field locL ->
                                       case ( locL ^. localValue
                                            , objR ^? objLocals . ix field . localValue) of
                                         (VRef aL, Just (VRef aR)) -> Just (field, aL, aR)
                                         _ -> Nothing) (objL ^. objLocals)
      in map (\field -> prefixFields ++ [field]) (M.keys common) ++
         (concatMap (\(field, aL, aR) -> commonVars (prefixFields ++ [field]) aL ctxL aR ctxR)
                    . catMaybes . M.elems $ commonObjs)
  | otherwise = error "commonVars called with invalid addresses"


inferInvariants :: Expr -> Step -> Verify Step
inferInvariants prefix step@(lhs, invs, rhs)
  | (not $ any (\x -> (x === Infer) == Just True) invs) && not (null invs) = return step
  | any (\x -> (x === NoInfer) == Just True) invs = return step
  | otherwise = do
  (_, prefixCtx, _) <- singleResult <$> symEval (prefix, emptyCtx, [])
  (VRef addrL, ctxL, _) <- singleResult <$> symEval (lhs, prefixCtx, [])
  (VRef addrR, ctxR, _) <- singleResult <$> symEval (rhs, prefixCtx, [])
  let comVars = commonVars [] addrL ctxL addrR ctxR
  debug $ "Inferred equality invariants on fields: " ++ show comVars
  return (lhs, invs ++ map fieldEqual comVars, rhs)

-- | One part of a quivela proof, which is either an expression, or a proof hint.
-- An followed by a hint and another expression is verified using that hint,
-- while two expressions in a row are verified without additional proof hints.
-- The steps are chained automatically, e.g. @[e1, h1, e2, e3]@ will result in verifying
-- @e1 ~[h1] e2 ~ e3@
data ProofPart = Prog Expr | Hint [Invariant]

type Proof = [ProofPart]

instance Show ProofPart where
  show (Prog e) = "Program:\n" ++ show e
  show _ = "<invariant>"

-- | Convert a series of proof parts into a sequence of steps
toSteps :: [ProofPart] -> [Step]
toSteps [] = []
toSteps [Prog exp] = []
toSteps (Prog lhs : Prog rhs : steps') = (lhs, [], rhs) : toSteps (Prog rhs : steps')
toSteps (Prog lhs : Hint invs : Prog rhs : steps') = (lhs, invs, rhs) : toSteps (Prog rhs : steps')
toSteps _ = error "Invalid sequence of steps"

proveStep :: Expr -> Step -> Verify Int
proveStep prefix step = handleStep =<< inferInvariants prefix step
  where handleStep (lhs, invs, rhs) = do
          remaining <- checkEqv True prefix invs lhs rhs
          return . sum . map (length . snd) $ remaining

-- | A handy alias for cons; this makes a sequence of proof steps look more like
-- an actual equivalence relation.
(~~) :: a -> [a] -> [a]
x ~~ y = x : y

infixr 5 ~~

-- | Like '~~' but using a nicer-looking unicode operator instead.
(≈) :: a -> [a] -> [a]
x ≈ y = x : y

infixr 5 ≈

nop :: Expr
nop = ENop
