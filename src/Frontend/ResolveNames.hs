{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MonadComprehensions #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ViewPatterns #-}
module Frontend.ResolveNames where

import Protolude hiding (TypeError, moduleName)

import Control.Monad.RWS
import Data.Bitraversable
import qualified Data.HashMap.Lazy as HashMap
import Data.HashMap.Lazy(HashMap)
import Data.HashSet(HashSet)
import qualified Data.HashSet as HashSet
import qualified Data.Text.Prettyprint.Doc as PP
import qualified Data.Vector as Vector
import Rock

import qualified Builtin.Names as Builtin
import Driver.Query
import Effect
import Pretty
import Syntax
import qualified Syntax.Pre.Literal as Literal
import qualified Syntax.Pre.Scoped as Scoped
import qualified Syntax.Pre.Unscoped as Unscoped
import Util
import Util.MultiHashMap(MultiHashMap)
import qualified Util.MultiHashMap as MultiHashMap
import Util.TopoSort
import VIX hiding (Env)

newtype Env = Env
  { scopeConstrs :: PreName -> HashSet QConstr
  }

type ResolveNames = RWST Env () (HashSet QName) VIX

runResolveNames :: ResolveNames a -> Env -> VIX (a, HashSet QName)
runResolveNames m env = do
  (a, s, ~()) <- runRWST m env mempty
  return (a, s)

resolveModule
  :: ModuleHeader
  -> HashMap QName (SourceLoc, Unscoped.Definition)
  -> VIX [[(QName, SourceLoc, Closed (Scoped.Definition Scoped.Expr))]]
resolveModule modul defs = do
  let imports
        = Import Builtin.BuiltinModuleName Builtin.BuiltinModuleName AllExposed
        : moduleImports modul

  (importedConstrAliases, importedNameAliases) <- mconcat <$> mapM importedAliases imports
  let env = Env
        $ flip MultiHashMap.lookup
        $ localConstrAliases defs <> importedConstrAliases

  checkedDefDeps <- forM (HashMap.toList defs) $ \(n, (loc, def)) -> do
    (def', deps) <- runResolveNames (resolveTopLevelDefinition n def) env
    return (n, loc, def', deps)

  let aliases = localAliases defs <> importedNameAliases
      lookupAlias preName
        | HashSet.size candidates == 1 = return $ pure $ fromMaybe (panic "resolveModule impossible") $ head $ HashSet.toList candidates
        | HashSet.size candidates == 0 = do
          report
            $ TypeError ("Not in scope:" PP.<+> red (pretty preName)) (preNameSourceLoc preName) mempty
          let err = Scoped.App
                (global Builtin.StaticErrorName)
                Explicit
                (Scoped.Lit $ Literal.String "error\n")
          return err
        | otherwise = do
          report
            $ TypeError ("Ambiguous occurrence:" PP.<+> red (pretty preName)) (preNameSourceLoc preName) $ PP.vcat
              [ "It could refer to" PP.<+> prettyHumanList "or" (dullBlue . pretty <$> toList candidates) <> "."
              ]
          let err = Scoped.App
                (global Builtin.StaticErrorName)
                Explicit
                (Scoped.Lit $ Literal.String "error\n")
          return err
        where
          candidates = MultiHashMap.lookup preName aliases

  resolvedDefs <- forM checkedDefDeps $ \(n, loc, def, deps) -> do
    def' <- boundJoin <$> traverse lookupAlias def
    return (n, (loc, def' >>>= global), toHashSet def' <> deps)

  -- Each _usage_ of a class (potentially) depends on all its instances.
  -- But the class itself doesn't (necessarily).
  --
  -- So, create an instanceDeps table: For each definition that's an instance i of
  -- class c, add a vertex c -> i, and map the instanceDeps table over all _dependencies_.
  --
  -- We also add a dependency from method to class for all methods
  instanceDeps <- instances $ (\(n, (loc, def), _) -> (n, loc, def)) <$> resolvedDefs
  let methodDeps = methodClasses defs
      addMethodDeps dep
        = maybe (HashSet.singleton dep) (HashSet.insert dep . HashSet.singleton)
        $ HashMap.lookup dep methodDeps
      addInstanceDeps dep = HashSet.insert dep $ MultiHashMap.lookup dep instanceDeps
      addExtraDeps deps = do
        let deps' = mconcat $ addMethodDeps <$> HashSet.toList deps
            deps'' = addInstanceDeps <$> HashSet.toList deps'
        mconcat deps''

  let sortedDefGroups = flattenSCC <$> topoSortWith fst3 (addExtraDeps . thd3) resolvedDefs

  return [[(n, loc, close identity def) | (n, (loc, def), _) <- defs'] | defs' <- sortedDefGroups]

localConstrAliases
  :: HashMap QName (SourceLoc, Unscoped.Definition)
  -> MultiHashMap PreName QConstr
localConstrAliases contents = MultiHashMap.fromList $ concat
  [ [ (k, QConstr n c)
    , (fromName (qnameName n) <> "." <> k, QConstr n c)
    , (fromModuleName (qnameModule n) <> "." <> k, QConstr n c)
    , (fromQName n <> "." <> k, QConstr n c)
    ]
  | (n, (_, Unscoped.DataDefinition _ _ cs)) <- HashMap.toList contents
  , c <- Unscoped.constrName <$> cs
  , let k = fromConstr c
  ]

localAliases
  :: HashMap QName (SourceLoc, Unscoped.Definition)
  -> MultiHashMap PreName QName
localAliases contents = MultiHashMap.fromList $ concat
  [ [ (fromName $ qnameName qn, qn)
    , (fromQName qn, qn)
    ]
  | qn <- HashMap.keys contents
  ] <> localMethods
  where
    localMethods
      = concat
      [ [ (fromName m, qn)
        , (fromQName qn, qn)
        ]
      | (n, (_, Unscoped.ClassDefinition _ ms)) <- HashMap.toList contents
      , m <- methodName <$> ms
      , let qn = QName (qnameModule n) m
      ]

methodClasses
  :: HashMap QName (SourceLoc, Unscoped.Definition)
  -> HashMap QName QName
methodClasses contents = HashMap.fromList
  [ (QName (qnameModule n) m, n)
  | (n, (_, Unscoped.ClassDefinition _ ms)) <- HashMap.toList contents
  , m <- methodName <$> ms
  ]

instances
  :: [(QName, SourceLoc, Scoped.Definition Scoped.Expr void)]
  -> VIX (MultiHashMap QName QName)
instances defs = fmap (MultiHashMap.fromList . concat) $ forM defs $ \(name, _, def) -> case def of
  Scoped.InstanceDefinition (Scoped.InstanceDef typ _) -> do
    mc <- getClass typ
    return [(c, name) | c <- toList mc]
  _ -> return mempty

importedAliases
  :: Import
  -> VIX (MultiHashMap PreName QConstr, MultiHashMap PreName QName)
importedAliases (Import modName asName exposed) = do
  (otherNames, otherConstrs) <- fetch $ ModuleExports modName
  let
    constrs
      = MultiHashMap.fromList
      $ concat
      [ [ (k, c)
        , (fromName (qnameName $ qconstrTypeName c) <> "." <> k, c)
        ]
      | c <- HashSet.toList otherConstrs
      , let k = fromConstr $ qconstrConstr c
      ]

    names
      = MultiHashMap.fromList
      $ (\n -> (fromName $ qnameName n :: PreName, n))
      <$> HashSet.toList otherNames

    exposedConstrs = case exposed of
      AllExposed -> constrs
      Exposed ns -> MultiHashMap.setIntersection constrs $ HashSet.map fromName ns

    exposedNames = case exposed of
      AllExposed -> names
      Exposed ns -> MultiHashMap.setIntersection names $ HashSet.map fromName ns

  return
    ( exposedConstrs <> MultiHashMap.mapKeys (fromQName . QName asName . fromPreName) constrs
    , exposedNames <> MultiHashMap.mapKeys (fromQName . QName asName . fromPreName) names
    )

-- | Distinguish variables from constructors, resolve scopes
resolveTopLevelDefinition
  :: QName
  -> Unscoped.Definition
  -> ResolveNames (Scoped.Definition Scoped.Expr PreName)
resolveTopLevelDefinition _ (Unscoped.ConstantDefinition d) =
  Scoped.ConstantDefinition <$> resolveDefinition d
resolveTopLevelDefinition name (Unscoped.DataDefinition boxiness params cs) = do
  (params', abstr) <- resolveParams params
  let
    dataType
      = Unscoped.apps
        (Unscoped.Var $ fromQName name)
        [(p, Unscoped.Var $ fromName n) | (p, n, _) <- params]
  cs' <- forM cs $ \case
    Unscoped.ADTConstrDef c types -> do
      let
        typ = Unscoped.pis
          ((\e -> (Explicit, AnnoPat WildcardPat e)) <$> types)
          dataType
      ConstrDef c . abstr <$> resolveExpr typ
    Unscoped.GADTConstrDef c typ ->
      ConstrDef c . abstr <$> resolveExpr typ
  return $ Scoped.DataDefinition $ DataDef boxiness params' cs'
resolveTopLevelDefinition _ (Unscoped.ClassDefinition params ms) = do
  (params', abstr) <- resolveParams params
  ms' <- mapM (mapM (fmap abstr . resolveExpr)) ms
  return $ Scoped.ClassDefinition $ ClassDef params' ms'
resolveTopLevelDefinition _ (Unscoped.InstanceDefinition typ ms) = do
  typ' <- resolveExpr typ
  ms' <- forM ms $ \(n, loc, m) -> do
    m' <- resolveDefinition m
    return $ Method n loc m'
  return
    $ Scoped.InstanceDefinition
    $ Scoped.InstanceDef typ' ms'

resolveParams
  :: Monad f
  => [(Plicitness, Name, Unscoped.Type)]
  -> ResolveNames (Telescope Scoped.Expr PreName, f PreName -> Scope TeleVar f PreName)
resolveParams params = do
  params' <- forM (toVector params) $ \(p, n, t) -> do
    t' <- resolveExpr t
    return (fromName n, binding (fromName n) p t')
  let paramNames = fst <$> params'
      abstr = abstract $ teleAbstraction paramNames
  return (bindingTelescope params', abstr)

resolveDefinition
  :: Unscoped.ConstantDef Unscoped.Expr
  -> ResolveNames (Scoped.ConstantDef Scoped.Expr PreName)
resolveDefinition (Unscoped.ConstantDef a clauses mtyp) =
  Scoped.ConstantDef a <$> mapM resolveClause clauses <*> mapM resolveExpr mtyp

resolveClause
  :: Unscoped.Clause Unscoped.Expr
  -> ResolveNames (Scoped.Clause Scoped.Expr PreName)
resolveClause (Unscoped.Clause loc plicitPats e) = do
  plicitPats' <- traverse (traverse resolvePat) plicitPats
  Scoped.clause loc fromPreName plicitPats' <$> resolveExpr e

resolveExpr
  :: Unscoped.Expr
  -> ResolveNames (Scoped.Expr PreName)
resolveExpr expr = case expr of
  Unscoped.Var v -> do
    constrCandidates <- asks (($ v) . scopeConstrs)
    if HashSet.null constrCandidates then
      return $ Scoped.Var v
    else do
      let defs = HashSet.map qconstrTypeName constrCandidates
      modify $ mappend defs
      return $ Scoped.Con constrCandidates
  Unscoped.Lit l -> return $ Scoped.Lit l
  Unscoped.Pi p pat e -> do
    pat' <- resolvePat pat
    Scoped.pi_ fromPreName p pat' <$> resolveExpr e
  Unscoped.Lam p pat e -> do
    pat' <- resolvePat pat
    Scoped.lam fromPreName p pat' <$> resolveExpr e
  Unscoped.App e1 p e2 -> Scoped.App
    <$> resolveExpr e1
    <*> pure p
    <*> resolveExpr e2
  Unscoped.Let defs body -> do
    defs' <- traverse (\(n, loc, d) -> (,,) n loc <$> resolveDefinition d) defs
    body' <- resolveExpr body
    let sortedDefs = topoSortWith
          (\(name, _, _) -> fromName name)
          (\(_, _, d) -> toHashSet d)
          defs'

        go ds e = do
          let ds' = Vector.fromList ds
              abstr = letAbstraction $ fromName . fst3 <$> ds'
          Scoped.Let
            (Scoped.LetRec $ (\(name, loc, def) -> Scoped.LetBinding loc (fromName name) $ Scoped.abstractConstantDef abstr def) <$> ds')
            (abstract abstr e)

    return $ foldr go body' $ flattenSCC <$> sortedDefs
  Unscoped.Case e pats -> Scoped.case_ fromPreName
    <$> resolveExpr e
    <*> mapM (bitraverse resolvePat resolveExpr) pats
  Unscoped.ExternCode c -> Scoped.ExternCode <$> mapM resolveExpr c
  Unscoped.Wildcard -> return Scoped.Wildcard
  Unscoped.SourceLoc loc e -> Scoped.SourceLoc loc <$> resolveExpr e
  Unscoped.Error e -> do
    lift $ report e
    return
      $ Scoped.App
        (global Builtin.StaticErrorName)
        Explicit
        (Scoped.Lit $ Literal.String "name resolution error")

resolvePat
  :: Pat PreName Scoped.Literal PreName Unscoped.Expr
  -> ResolveNames (Pat (HashSet QConstr) Scoped.Literal PreName (Scoped.Expr PreName))
resolvePat pat = case pat of
  VarPat v -> do
    constrCandidates <- asks (($ v) . scopeConstrs)
    if HashSet.null constrCandidates then
      return $ VarPat v
    else do
      modify $ mappend $ HashSet.map qconstrTypeName constrCandidates
      return $ ConPat constrCandidates mempty
  WildcardPat-> return WildcardPat
  LitPat l -> return $ LitPat l
  ConPat con ps -> do
    cons <- asks (($ con) . scopeConstrs)
    forM_ cons $ \(QConstr def _) -> modify $ HashSet.insert def
    ConPat cons <$> mapM (\(p, pat') -> (,) p <$> resolvePat pat') ps
  AnnoPat p t -> AnnoPat <$> resolvePat p <*> resolveExpr t
  ViewPat t p -> ViewPat <$> resolveExpr t <*> resolvePat p
  ForcedPat t -> ForcedPat <$> resolveExpr t
  PatLoc loc p -> PatLoc loc <$> resolvePat p

getClass
  :: Scoped.Expr v
  -> VIX (Maybe QName)
getClass (Scoped.Pi _ _ s) = getClass $ fromScope s
getClass (Scoped.SourceLoc loc e) = located loc $ getClass e
getClass (Scoped.appsView -> (Scoped.Global g, _)) = return $ Just g
getClass _ = do
  reportInvalidInstance
  return Nothing

reportInvalidInstance :: VIX ()
reportInvalidInstance
  = reportLocated
  $ PP.vcat
  [ "Invalid instance"
  , "Instance types must return a class"
  , bold "Expected:" PP.<+> "an instance of the form" PP.<+> dullGreen "instance ... => C as where ..." <> ", where" PP.<+> dullGreen "C" PP.<+> "is a class."
  ]

moduleExports
  :: ModuleHeader
  -> HashMap QName (a, Unscoped.Definition)
  -> (HashSet QName, HashSet QConstr)
moduleExports moduleHeader_ defs = do
  let
    p = case moduleExposedNames moduleHeader_ of
      AllExposed -> const True
      Exposed names -> (`HashSet.member` toHashSet names)

    defNames = HashSet.filter (p . qnameName) $ HashSet.fromMap $ void defs
    conNames = HashSet.fromList
      [ QConstr n c
      | (n, (_, Unscoped.DataDefinition _ _ cs)) <- HashMap.toList defs
      , c <- Unscoped.constrName <$> cs
      , p $ qnameName n
      ]
    methods = HashSet.fromList
      [ QName n m
      | (QName n _, (_, Unscoped.ClassDefinition _ ms)) <- HashMap.toList defs
      , m <- methodName <$> ms
      , p m
      ]
  (defNames <> methods, conNames)
