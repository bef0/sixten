{-# LANGUAGE DeriveFoldable, DeriveFunctor, DeriveTraversable, FlexibleContexts, OverloadedStrings, RankNTypes #-}
module Syntax.Data where

import Bound
import Bound.Scope
import Bound.Var
import Data.Bifunctor
import Data.Bitraversable
import Data.String
import Prelude.Extras

import Pretty
import Syntax.Annotation
import Syntax.Class
import Syntax.GlobalBind
import Syntax.Name
import Syntax.Telescope
import Util

newtype DataDef typ v = DataDef { dataConstructors :: [ConstrDef (Scope Tele typ v)] }
  deriving (Eq, Foldable, Functor, Ord, Show, Traversable)

instance GlobalBound DataDef where
  bound f g (DataDef cs) = DataDef $ fmap (bound f g) <$> cs

hoistDataDef
  :: Functor typ
  => (forall v'. typ v' -> typ' v')
  -> DataDef typ v
  -> DataDef typ' v
hoistDataDef f (DataDef cs) = DataDef $ fmap (hoistScope f) <$> cs

bimapDataDef
  :: Bifunctor typ
  => (a -> a')
  -> (b -> b')
  -> DataDef (typ a) b
  -> DataDef (typ a') b'
bimapDataDef f g (DataDef cs) = DataDef $ fmap (bimapScope f g) <$> cs

bitraverseDataDef
  :: (Bitraversable typ, Applicative f)
  => (a -> f a')
  -> (b -> f b')
  -> DataDef (typ a) b
  -> f (DataDef (typ a') b')
bitraverseDataDef f g (DataDef cs) = DataDef <$> traverse (traverse $ bitraverseScope f g) cs

quantifiedConstrTypes
  :: Syntax typ
  => DataDef typ v
  -> typ v
  -> (Annotation typ -> Annotation typ)
  -> [ConstrDef (typ v)]
quantifiedConstrTypes (DataDef cs) typ anno = map (fmap $ pis ps) cs
  where
    ps = mapAnnotations anno $ telescope typ

constrNames :: DataDef typ v -> [Constr]
constrNames = map constrName . dataConstructors

prettyDataDef
  :: (Eq1 typ, Eq v, IsString v, Monad typ, Pretty (typ v), Eq (Annotation typ), PrettyAnnotation (Annotation typ))
  => Telescope (Annotation typ) typ v
  -> DataDef typ v
  -> PrettyM Doc
prettyDataDef ps (DataDef cs) = "data" <+> "_" <+> withTeleHints ps (\ns ->
    let inst = instantiateTele (pure . fromName) ns in
        prettyTeleVarTypes ns ps <+> "where" <$$>
          indent 2 (vcat (map (prettyM . fmap inst) cs))
    )

data ConstrDef typ = ConstrDef
  { constrName :: Constr
  , constrType :: typ
  } deriving (Eq, Foldable, Functor, Ord, Show, Traversable)

instance (IsString v, Pretty (typ v), Monad typ) => Pretty (DataDef typ v) where
  prettyM (DataDef cs) = "data" <+> "_" <+> "where" <$$>
    indent 2 (vcat (map (prettyM . fmap (instantiate $ pure . shower)) cs))

instance Pretty typ => Pretty (ConstrDef typ) where
  prettyM (ConstrDef n t) = prettyM n <+> ":" <+> prettyM t

abstractDataDef
  :: Functor typ
  => (a -> Maybe b)
  -> DataDef typ a
  -> DataDef typ (Var b a)
abstractDataDef f (DataDef cs) = DataDef (fmap (fmap f') <$> cs)
  where
    f' a = maybe (F a) B $ f a

instantiateDataDef
  :: Monad typ
  => (b -> typ a)
  -> DataDef typ (Var b a)
  -> DataDef typ a
instantiateDataDef f (DataDef cs) = DataDef (fmap (>>>= f') <$> cs)
  where
    f' = unvar f pure
