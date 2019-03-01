{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ViewPatterns #-}
module Elaboration.Match where

import Protolude hiding (TypeError)

import Control.Monad
import Control.Monad.Trans.Maybe
import Data.HashMap.Lazy(HashMap)
import qualified Data.HashMap.Lazy as HashMap
import Data.HashSet(HashSet)
import qualified Data.HashSet as HashSet
import qualified Data.Text.Prettyprint.Doc as PP
import Data.Vector (Vector)
import qualified Data.Vector as Vector

import {-# SOURCE #-} Elaboration.TypeCheck.Expr
import qualified Builtin.Names as Builtin
import Driver.Query
import Effect
import qualified Effect.Context as Context
import qualified Effect.Log as Log
import Elaboration.Constraint
import Elaboration.Constructor
import Elaboration.MetaVar
import Elaboration.MetaVar.Zonk
import Elaboration.Monad
import Elaboration.TypeCheck.Literal
import Elaboration.Unify
import qualified Elaboration.Unify.Indices as Indices
import Syntax
import qualified Syntax.Core as Core
import qualified Syntax.Literal as Core
import qualified Syntax.Pre.Literal as Pre
import qualified Syntax.Pre.Scoped as Pre
import Util
import Util.TopoSort

matchClauses
  :: Foldable t
  => Vector Var
  -> t (Pre.Clause Pre.Expr Var)
  -> Polytype
  -> (Pre.Expr Var -> Polytype -> Elaborate CoreM)
  -> Elaborate CoreM
matchClauses vars preClauses typ k = do
  ctx <- getContext
  loc <- getCurrentLocation
  let
    clauses = foreach (toList preClauses) $ \(Pre.Clause pats rhs) ->
      Clause
        { _matches =
          toList $ Vector.zipWith (\v (p, pat) -> Match (pure v) (p, desugarPatLits pat) (Context.lookupType v ctx) loc) vars $ indexedPatterns pats
        , _rhs = rhs
        }
  match Config
    { _targetType = typ
    , _scrutinees = pure <$> vars
    , _clauses = clauses
    , _coveredLits = mempty
    }
    k

matchBranches
  :: CoreM
  -> CoreM
  -> [(Pat (HashSet QConstr) Pre.Literal (PatternScope Pre.Expr Var) NameHint, PatternScope Pre.Expr Var)]
  -> Polytype
  -> (Pre.Expr Var -> Polytype -> Elaborate CoreM)
  -> Elaborate CoreM
matchBranches (Core.varView -> Just var) exprType brs typ k = do
  loc <- getCurrentLocation
  match Config
    { _targetType = typ
    , _scrutinees = pure (pure var)
    , _clauses =
      [ Clause
        { _matches = [Match (pure var) (Explicit, imap (\i _ -> PatternVar i) $ desugarPatLits pat) exprType loc]
        , _rhs = rhs
        }
      | (pat, rhs) <- brs
      ]
    , _coveredLits = mempty
    }
    k
matchBranches expr exprType brs typ k =
  Context.freshExtend (binding "matchvar" Explicit exprType) $ \var -> do
    result <- matchBranches (pure var) exprType brs typ k
    Core.let_ (pure (var, noSourceLoc "match", expr)) result

uninhabitedType :: Int -> CoreM -> Elaborate Bool
uninhabitedType fuel typ = do
  typ' <- whnf typ
  logMeta "tc.match" "uninhabitedType typ'" $ zonk typ'
  case typ' of
    Builtin.Equals _ e1 e2 -> do
      res <- Indices.unify e1 e2
      case res of
        Indices.Nope -> return True
        Indices.Dunno -> return False
        Indices.Success _ -> return False
    (Core.appsView -> (Core.Global typeName, toVector -> args)) -> do
      def <- fetchDefinition typeName
      case def of
        ConstantDefinition {} -> return False
        DataDefinition (DataDef _ constrDefs) _ ->
          allM (uninhabitedConstrType fuel . instantiateTele snd args . constrType) constrDefs
    _ -> return False

uninhabitedConstrType :: Int -> CoreM -> Elaborate Bool
uninhabitedConstrType 0 _ = return False
uninhabitedConstrType fuel typ = do
  typ' <- whnf typ
  case typ' of
    Core.Pi h p t s -> do
      u <- uninhabitedType (fuel - 1) t
      if u then
        return True
      else
        Context.freshExtend (binding h p t) $ \v ->
          uninhabitedConstrType fuel $ instantiate1 (pure v) s
    _ -> return False

uninhabitedScrutinee :: CoreM -> Elaborate Bool
uninhabitedScrutinee expr = do
  expr' <- whnf expr
  logMeta "tc.match" "uninhabitedScrutinee expr'" $ zonk expr'
  case expr' of
    Core.Var v -> do
      typ <- Context.lookupType v
      uninhabitedType 1 typ
    (Core.appsView -> (Core.Con qc, es)) -> do
      (numParams, _) <- fetchQConstructor qc
      let
        args = drop numParams es
      anyM (uninhabitedScrutinee . snd) args
    _ -> return False

matchSingle
  :: Var
  -> Pat (HashSet QConstr) Pre.Literal (PatternScope Pre.Expr Var) NameHint
  -> PatternScope Pre.Expr Var
  -> Polytype
  -> (Pre.Expr Var -> Polytype -> Elaborate CoreM)
  -> Elaborate CoreM
matchSingle v pat body typ k = do
  varType <- Context.lookupType v
  loc <- getCurrentLocation
  match Config
    { _targetType = typ
    , _scrutinees = pure (pure v)
    , _clauses =
      [ Clause
        { _matches = [Match (pure v) (Explicit, PatternVar . fst <$> indexed (desugarPatLits pat)) varType loc]
        , _rhs = body
        }
      ]
    , _coveredLits = mempty
    }
    k

desugarPatLits
  :: Pat (HashSet QConstr) Pre.Literal typ v
  -> Pat (HashSet QConstr) Core.Literal typ v
desugarPatLits = bindPatLits litPat

-------------------------------------------------------------------------------

type PrePat = Pat (HashSet QConstr) Core.Literal (PatternScope Pre.Type Var) PatternVar

data Config = Config
  { _targetType :: CoreM
  , _scrutinees :: Vector CoreM
  , _clauses :: [Clause]
  , _coveredLits :: !CoveredLits
  }

type CoveredLits = HashSet (Var, Core.Literal)

data Clause = Clause
  { _matches :: [Match]
  , _rhs :: PatternScope Pre.Expr Var
  }

data Match = Match CoreM (Plicitness, PrePat) CoreM !(Maybe SourceLoc)

prettyClause :: Clause -> Elaborate Doc
prettyClause (Clause matches rhs) = do
  cs <- pretty <$> traverse prettyMatch matches
  e <- pretty . instantiate (pure . ("α" <>) . pretty . unPatternVar) <$> traverse prettyVar rhs
  return $ cs <> " ~> " <> e

prettyMatch :: Match -> Elaborate Doc
prettyMatch (Match expr (p, pat) typ _) = do
  pexpr <- prettyMeta =<< zonk expr
  let
    ppat = pretty
      $ prettyAnnotation p
      $ prettyM
      $ bimap (const ()) (\(PatternVar i) -> "α" <> pretty i) pat
  ptype <- prettyMeta =<< zonk typ
  return $ pexpr <> " / " <> ppat <> " : " <> ptype

-------------------------------------------------------------------------------

match
  :: Config
  -> (Pre.Expr Var -> Polytype -> Elaborate CoreM)
  -> Elaborate CoreM
match config k = Log.indent $ do
  logPretty "tc.match.context" "context" $ Context.prettyContext $ prettyMeta <=< zonk
  logMeta "tc.match" "targetType" $ zonk $ _targetType config
  logPretty "tc.match" "clauses" $ traverse prettyClause $ _clauses config
  clauses <- catMaybes <$> mapM (simplifyClause $ _coveredLits config) (_clauses config)
  logPretty "tc.match" "simplified clauses" $ traverse prettyClause clauses
  case clauses of
    [] -> do
      ok <- anyM uninhabitedScrutinee $ toList $ _scrutinees config
      if ok then do
        logCategory "tc.match" "uninhabitedScrutinee"
        return $ Builtin.Fail $ _targetType config
      else do
        logCategory "tc.match" "non-exhaustive"
        loc <- getCurrentLocation
        scrutinees <- mapM (runMaybeT . exprPattern) $ _scrutinees config
        let
          prettyScrutinees
            = foreach (scrutinees :: Vector (Maybe (Pat QConstr Core.Literal Void Var)))
            $ maybe "?" (prettyM . fmap (pure ("_" :: Doc)))
        report
          $ TypeError "Non-exhaustive patterns" loc
          $ PP.vcat
          [ "Patterns not matched:"
          , dullBlue $ pretty $ prettyApps "" prettyScrutinees
          ]
        return $ Builtin.Fail $ _targetType config
    firstClause:clauses' -> do
      logPretty "tc.match" "firstClause" $ prettyClause firstClause
      let
        matches' = _matches firstClause
        config' = config { _clauses = firstClause : clauses' }
      eqMatch <- findEqMatch matches'
      case eqMatch of
        Just (v, typ, e1, e2, s) -> splitEq config' v typ e1 e2 s k
        Nothing ->
          case findConMatches matches' of
            (x, Left qc, typ):_ -> do
              logPretty "tc.match" "found con" $ pure qc
              splitCon config' x qc typ k
            (x, Right l, typ):_ -> do
              logPretty "tc.match" "found lit" $ pure l
              splitLit config' x l typ k
            [] -> do
              logCategory "tc.match" "found no con"
              case solved matches' of
                Just sub -> do
                  logCategory "tc.match" "solved"
                  instantiateSubst sub (_rhs firstClause) $ \e ->
                    k e $ _targetType config
                Nothing ->
                  panic "tc.match no solution"

exprPattern
  :: CoreM
  -> MaybeT Elaborate (Pat QConstr Core.Literal void Var)
exprPattern expr = do
  expr' <- whnf expr
  case expr' of
    Core.Var v -> return $ VarPat v
    (Core.appsView -> (Core.Con qc, es)) ->do
      (numParams, _) <- fetchQConstructor qc
      pats <- mapM (mapM exprPattern) $ drop numParams es
      return $ ConPat qc $ toVector pats
    Core.Lit l -> return $ LitPat l
    _ -> fail "couldn't convert expression to pattern"

findConMatches
  :: [Match]
  -> [(Var, Either (HashSet QConstr) Core.Literal, CoreM)]
findConMatches matches
  = catMaybes
  $ foreach matches
  $ \case
    Match (Core.Var x) (_, unPatLoc -> ConPat qc _) typ _ ->
      Just (x, Left qc, typ)
    Match (Core.Var x) (_, unPatLoc -> LitPat l) typ _ ->
      Just (x, Right l, typ)
    Match {} ->
      Nothing

findEqMatch
  :: [Match]
  -> Elaborate (Maybe (Var, CoreM, CoreM, CoreM, Indices.Subst))
findEqMatch [] = return Nothing
findEqMatch (Match (Core.Var x) (Constraint, unPatLoc -> WildcardPat) (Builtin.Equals typ e1 e2) loc:rest) = do
  result <- Indices.unify e1 e2
  case result of
    Indices.Success s -> return $ Just (x, typ, e1, e2, s)
    Indices.Dunno -> findEqMatch rest
    Indices.Nope -> do
      e1' <- zonk e1
      e2' <- zonk e2
      pe1 <- prettyMeta e1'
      pe2 <- prettyMeta e2'
      let
        err = "Unification failure" <> PP.line <> PP.vcat
          [ red pe1
          , "and"
          , red pe2
          , "cannot be unified."
          ]
      report $ TypeError err loc mempty
      return Nothing
findEqMatch (_:rest) = findEqMatch rest

splitCon
  :: Config
  -> Var
  -> HashSet QConstr
  -> CoreM
  -> (Pre.Expr Var -> Polytype -> Elaborate CoreM)
  -> Elaborate CoreM
splitCon config x qcs typ k = do
  qc <- resolveConstr qcs $ Just typ
  logPretty "tc.match" "splitCon" $ pure qc
  let
    typeName = qconstrTypeName qc
  logPretty "tc.match.context" "splitCon context" $ Context.prettyContext prettyMeta
  def <- fetchDefinition $ gname typeName
  case def of
    ConstantDefinition {} -> panic "splitCon ConstantDefinition"
    DataDefinition (DataDef paramsTele constrDefs) _ -> do
      ctx <- getContext
      case Context.splitAt x ctx of
        Nothing -> panic "splitCon couldn't split context"
        Just (ctx1, b, ctx2) -> do
          params <- modifyContext (const ctx1) $ forTeleWithPrefixM paramsTele $ \h p s params -> do
            v <- exists h p $ instantiateTele snd params s
            return (p, v)
          runUnify (unify [] (Core.apps (global $ gname typeName) params) typ) report
          branches <- forM constrDefs $ \(ConstrDef c constrScope) -> do
            let
              constrType_ = instantiateTele snd params constrScope
            args <- forTeleWithPrefixM (Core.piTelescope constrType_) $ \h p s args -> do
              let t = instantiateTele (pure . fst) args s
              v <- Context.freeVar
              return (v, binding h p t)

            let
              plicitArgs = (\(v, Context.Binding _ p _ _) -> (p, pure v)) <$> args
              implicitParams = first implicitise <$> params
              val
                = Core.apps (Core.Con (QConstr typeName c))
                $ implicitParams <> plicitArgs
              ctx' =
                  ctx1
                  <> Context.fromList (toList args)
                  <> Context.fromList [(x, b { Context._value = Just val })]
                  <> ctx2
            modifyContext (const ctx') $ do
              branch <- match config k
              conBranch (QConstr typeName c) (fst <$> args) branch
          return $ Core.Case (pure x) (ConBranches branches) $ _targetType config

splitLit
  :: Config
  -> Var
  -> Core.Literal
  -> CoreM
  -> (Pre.Expr Var -> Polytype -> Elaborate CoreM)
  -> Elaborate CoreM
splitLit config x lit typ k = do
  let
    litType = inferCoreLit lit
  runUnify (unify [] litType typ) report
  branch <- Context.set x (Core.Lit lit) $ match config k
  defBranch <- match config
    { _coveredLits = _coveredLits config <> HashSet.singleton (x, lit)
    }
    k
  return
    $ Core.Case (pure x) (LitBranches (pure $ LitBranch lit branch) defBranch)
    $ _targetType config

splitEq
  :: Config
  -> Var
  -> CoreM
  -> CoreM
  -> CoreM
  -> Indices.Subst
  -> (Pre.Expr Var -> Polytype -> Elaborate CoreM)
  -> Elaborate CoreM
splitEq config x typ lhs rhs sub k = do
  logMeta "tc.match" "splitEq typ" $ zonk typ
  logMeta "tc.match" "splitEq lhs" $ zonk lhs
  logMeta "tc.match" "splitEq rhs" $ zonk rhs
  whenLoggingCategory "tc.match" $ forM_ (HashMap.toList sub) $ \(v, e) -> do
    logPretty "tc.match" "splitEq sub v" $ prettyVar v
    logMeta "tc.match" "splitEq sub e" $ zonk e
  ctx <- getContext
  case Context.splitAt x ctx of
    Nothing -> panic "splitCon couldn't split context"
    Just (ctx1, b, ctx2) -> do
      let
        subList = (x, Builtin.Refl typ lhs rhs) : HashMap.toList sub
        f m (v, e) = HashMap.adjust (\(Context.Binding h p t _) -> Context.Binding h p t $ Just e) v m
        ctx1' = foldl' f (Context._varMap (ctx1 Context.:> (x, b))) subList
        ctx1''
          = Context.fromList
          $ acyclic <$> topoSortWith fst (foldMap toHashSet . snd) (HashMap.toList ctx1')
        ctx' = ctx1'' <> ctx2
      modifyContext (const ctx') $
        match config k
  where
    acyclic (AcyclicSCC v) = v
    acyclic (CyclicSCC _) = panic "match splitEq cyclic"

simplifyClause :: CoveredLits -> Clause -> Elaborate (Maybe Clause)
simplifyClause coveredLits (Clause matches rhs) = Log.indent $ do
  logPretty "tc.match.simplify" "clause" $ prettyClause $ Clause matches rhs
  mmatches <- runMaybeT $
    concat <$> mapM (simplifyMatch coveredLits) matches
  case mmatches of
    Nothing -> do
      logCategory "tc.match.simplify" "Nothing"
      return Nothing
    Just matches' -> do
      logPretty "tc.match.simplify" "clause'" $ prettyClause $ Clause matches' rhs
      maybeExpanded <- runMaybeT $
        expandAnnos mempty matches'
      case maybeExpanded of
        Nothing -> return $ Just $ Clause matches' rhs
        Just expanded -> simplifyClause coveredLits $ Clause expanded rhs


simplifyMatch :: CoveredLits -> Match -> MaybeT Elaborate [Match]
simplifyMatch coveredLits m@(Match expr (plic, pat) typ loc) = do
  ctx <- getContext
  case (expr, pat) of
    (Core.Lit l1, LitPat l2)
      | l1 == l2 -> return []
      | otherwise -> fail "Literal mismatch"
    (Core.Var v, LitPat lit)
      | HashSet.member (v, lit) coveredLits -> fail "Literal already covered"
    (Core.Var v, _)
      | Just expr' <- Context.lookupValue v ctx ->
        simplifyMatch coveredLits $ Match expr' (plic, pat) typ loc
    (Core.appsView -> (Core.Con qc, pes), ConPat qcs pats)
      | qc `HashSet.member` qcs -> do
        (numParams, conType) <- fetchQConstructor qc
        let
          tele = Core.piTelescope conType
          exprs = toVector $ snd <$> pes
          types = forTele tele $ \_ _ s -> instantiateTele identity exprs s
          argTypes = Vector.drop numParams types
          argExprs = Vector.drop numParams exprs
          argPlics = Vector.drop numParams $ telePlics tele
        equalisedPats <- lift $ Vector.fromList <$> exactlyEqualisePats (toList argPlics) (toList pats)
        let
          matches = Vector.zipWith3 (\e p t -> Match e p t loc) argExprs equalisedPats argTypes
        lift $ logPretty "tc.match" "simplify con matches" $ traverse prettyMatch matches
        concat <$> mapM (simplifyMatch coveredLits) matches
      | otherwise -> fail "Constructor mismatch"
    (_, PatLoc loc' pat') -> do
      located loc' $ simplifyMatch coveredLits $ Match expr (plic, pat') typ $ Just loc'
    (Core.SourceLoc _ expr', _) -> simplifyMatch coveredLits $ Match expr' (plic, pat) typ loc
    _ -> return [m]

expandAnnos
  :: PatSubst
  -> [Match]
  -> MaybeT Elaborate [Match]
expandAnnos _ [] = fail "expanded nothing"
expandAnnos sub (c:cs) = case matchSubst c of
  Nothing -> case c of
    Match expr (plic, AnnoPat pat annoScope) typ loc -> do
      annoType' <- instantiateSubst sub annoScope $ \annoType ->
        lift $ checkPoly annoType Builtin.Type
      runUnify (unify [] annoType' typ) report
      return $ Match expr (plic, pat) typ loc : cs
    _ -> fail "couldn't create subst for prefix"
  Just sub' -> (c:) <$> expandAnnos (sub' <> sub) cs

matchSubst :: Match -> Maybe PatSubst
matchSubst (Match _ (_, WildcardPat) _ _) = return mempty
matchSubst (Match expr (_, VarPat pv) typ _) = return $ HashMap.singleton pv (expr, typ)
matchSubst (Match expr (plic, PatLoc _ pat) typ loc) = matchSubst $ Match expr (plic, pat) typ loc
matchSubst _ = Nothing

solved :: [Match] -> Maybe PatSubst
solved = fmap mconcat . traverse matchSubst

-------------------------------------------------------------------------------

type PatSubst = HashMap PatternVar (CoreM, CoreM)

instantiateSubst
  :: (Eq b, Hashable b, Monad e, MonadContext CoreM m, MonadFresh m)
  => HashMap b (CoreM, CoreM)
  -> Scope b e Var
  -> (e Var -> m CoreM)
  -> m CoreM
instantiateSubst sub scope k = do
  let
    varSub = HashMap.mapMaybe (Core.varView . fst) sub
    exprSub = HashMap.difference sub varSub
  if HashMap.null exprSub then
    k $ instantiate (pure . (varSub HashMap.!)) scope
  else do
    let
      exprVec = toVector $ HashMap.toList exprSub
    Context.freshExtends
      (foreach exprVec $ \(_, (e, t)) -> Context.Binding mempty Explicit t $ Just e) $ \vs -> do
        let
          varSub' = varSub <> toHashMap (Vector.zipWith (\(p, _) v -> (p, v)) exprVec vs)
          vsSet = toHashSet vs
        e <- k $ instantiate (pure . (varSub' HashMap.!)) scope
        ctx <- getContext
        return
          $ e >>= \v ->
            if HashSet.member v vsSet then
              fromMaybe (pure v) $ Context.lookupValue v ctx
            else
              pure v

--------------------------------------------------------------------------------
-- "Equalisation" -- making the patterns match a list of parameter plicitnesses
-- by adding implicits
exactlyEqualisePats
  :: (Pretty c, Pretty l)
  => [Plicitness]
  -> [(Plicitness, Pat c l e v)]
  -> Elaborate [(Plicitness, Pat c l e v)]
exactlyEqualisePats [] [] = return []
exactlyEqualisePats [] ((p, pat):_) = do
  reportLocated
    $ PP.vcat
      [ "Too many patterns for type"
      , "Found the pattern:" PP.<+> red (pretty $ prettyAnnotation p (prettyM $ bimap (const ()) (const ()) pat)) <> "." -- TODO var printing
      , bold "Expected:" PP.<+> "no more patterns."
      ]
  return []
exactlyEqualisePats (Constraint:ps) ((Constraint, pat):pats)
  = (:) (Implicit, pat) <$> exactlyEqualisePats ps pats
exactlyEqualisePats (Implicit:ps) ((Implicit, pat):pats)
  = (:) (Implicit, pat) <$> exactlyEqualisePats ps pats
exactlyEqualisePats (Explicit:ps) ((Explicit, pat):pats)
  = (:) (Explicit, pat) <$> exactlyEqualisePats ps pats
exactlyEqualisePats (Constraint:ps) pats
  = (:) (Constraint, WildcardPat) <$> exactlyEqualisePats ps pats
exactlyEqualisePats (Implicit:ps) pats
  = (:) (Implicit, WildcardPat) <$> exactlyEqualisePats ps pats
exactlyEqualisePats (Explicit:ps) ((Constraint, pat):pats) = do
  reportExpectedExplicit pat
  exactlyEqualisePats (Explicit:ps) pats
exactlyEqualisePats (Explicit:ps) ((Implicit, pat):pats) = do
  reportExpectedExplicit pat
  exactlyEqualisePats (Explicit:ps) pats
exactlyEqualisePats (Explicit:ps) [] = do
  reportLocated
    $ PP.vcat
      [ "Not enough patterns for type"
      , "Found: no patterns."
      , bold "Expected:" PP.<+> "an explicit pattern."
      ]
  exactlyEqualisePats (Explicit:ps) [(Explicit, WildcardPat)]

equalisePats
  :: (Pretty c, Pretty l)
  => [Plicitness]
  -> [(Plicitness, Pat c l e v)]
  -> Elaborate [(Plicitness, Pat c l e v)]
equalisePats _ [] = return []
equalisePats [] pats = return pats
equalisePats (Constraint:ps) ((Constraint, pat):pats)
  = (:) (Constraint, pat) <$> equalisePats ps pats
equalisePats (Implicit:ps) ((Implicit, pat):pats)
  = (:) (Implicit, pat) <$> equalisePats ps pats
equalisePats (Explicit:ps) ((Explicit, pat):pats)
  = (:) (Explicit, pat) <$> equalisePats ps pats
equalisePats (Constraint:ps) pats
  = (:) (Constraint, WildcardPat) <$> equalisePats ps pats
equalisePats (Implicit:ps) pats
  = (:) (Implicit, WildcardPat) <$> equalisePats ps pats
equalisePats (Explicit:ps) ((Implicit, pat):pats) = do
  reportExpectedExplicit pat
  equalisePats (Explicit:ps) pats
equalisePats (Explicit:ps) ((Constraint, pat):pats) = do
  reportExpectedExplicit pat
  equalisePats (Explicit:ps) pats

reportExpectedExplicit :: (Pretty c, Pretty l) => Pat c l e v -> Elaborate ()
reportExpectedExplicit pat
  = reportLocated
  $ PP.vcat
    [ "Explicit/implicit mismatch"
    , "Found the implicit pattern:" PP.<+> red (pretty $ prettyAnnotation Implicit (prettyM $ bimap (const ()) (const ()) pat)) <> "." -- TODO var printing
    , bold "Expected:" PP.<+> "an" PP.<+> dullGreen "explicit" PP.<+> "pattern."
    ]
