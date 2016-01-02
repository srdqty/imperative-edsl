{-# LANGUAGE CPP #-}
{-# LANGUAGE QuasiQuotes #-}

-- | C code generation for imperative commands

module Language.Embedded.Imperative.Backend.C where



#if __GLASGOW_HASKELL__ < 710
import Control.Applicative
#endif
import Control.Monad.State
import Data.Proxy

import Language.C.Quote.C
import qualified Language.C.Syntax as C

import Control.Monad.Operational.Higher
import Language.C.Monad
import Language.Embedded.Expression
import Language.Embedded.Imperative.CMD
import Language.Embedded.Imperative.Frontend.General
import Language.Embedded.Backend.C

-- | Compile `RefCMD`
compRefCMD :: forall exp prog a. CompExp exp
           => RefCMD exp prog a -> CGen a
compRefCMD cmd@NewRef = do
    t <- compTypePP2 (Proxy :: Proxy exp) cmd
    r <- RefComp <$> freshId
    case t of
      C.Type _ C.Ptr{} _ -> addLocal [cdecl| $ty:t $id:r = NULL; |]
      _                  -> addLocal [cdecl| $ty:t $id:r; |]
    return r
compRefCMD (InitRef exp) = do
    t <- compType exp
    r <- RefComp <$> freshId
    v <- compExp exp
    addLocal [cdecl| $ty:t $id:r; |]
    addStm   [cstm| $id:r = $v; |]
    return r
compRefCMD (GetRef ref) = do
    (v,_) <- freshVar
    e <- compExp v
    touchVar ref
    addStm [cstm| $e = $id:ref; |]
    return v
compRefCMD (SetRef ref exp) = do
    v <- compExp exp
    touchVar ref
    addStm [cstm| $id:ref = $v; |]
compRefCMD (UnsafeFreezeRef (RefComp v)) = return $ varExp v

-- | Compile `ArrCMD`
compArrCMD :: forall exp prog a. (CompExp exp, EvalExp exp)
           => ArrCMD exp prog a -> CGen a
compArrCMD cmd@(NewArr size) = do
    sym <- gensym "a"
    n   <- compExp size
    t   <- compTypePP2 (Proxy :: Proxy exp) cmd
    case n of
      C.Const _ _ -> addLocal [cdecl| $ty:t $id:sym[ $n ]; |]
      _ -> do
        addInclude "<alloca.h>"
        addLocal [cdecl| $ty:t * $id:sym; |]
        addStm [cstm| $id:sym = alloca($n * sizeof($ty:t)); |]
    return $ ArrComp sym
compArrCMD cmd@(NewArr_) = do
    sym <- gensym "a"
    t   <- compTypePP2 (Proxy :: Proxy exp) cmd
    addLocal [cdecl| $ty:t * $id:sym; |]
    return $ ArrComp sym
compArrCMD cmd@(InitArr as) = do
    sym <- gensym "a"
    t   <- compTypePP2 (Proxy :: Proxy exp) cmd
    as' <- sequence [compExp (litExp a :: exp a') | (a :: a') <- as]
    addLocal [cdecl| $ty:t $id:sym[] = $init:(arrayInit as');|]
    return $ ArrComp sym
compArrCMD (GetArr expi arr) = do
    (v,n) <- freshVar
    i     <- compExp expi
    touchVar arr
    addStm [cstm| $id:n = $id:arr[ $i ]; |]
    return v
compArrCMD (SetArr expi expv arr) = do
    v <- compExp expv
    i <- compExp expi
    touchVar arr
    addStm [cstm| $id:arr[ $i ] = $v; |]
compArrCMD (CopyArr arr1 arr2 expl) = do
    addInclude "<string.h>"
    l <- compExp expl
    t <- compTypePP (Proxy :: Proxy exp) arr1
    addStm [cstm| memcpy($id:arr1, $id:arr2, $l * sizeof($ty:t)); |]

-- | Compile `ControlCMD`
compControlCMD :: CompExp exp => ControlCMD exp CGen a -> CGen a
compControlCMD (If c t f) = do
    cc <- compExp c
    ct <- inNewBlock_ t
    cf <- inNewBlock_ f
    case (ct, cf) of
      ([],[]) -> return ()
      (_ ,[]) -> addStm [cstm| if (   $cc) {$items:ct} |]
      ([],_ ) -> addStm [cstm| if ( ! $cc) {$items:cf} |]
      (_ ,_ ) -> addStm [cstm| if (   $cc) {$items:ct} else {$items:cf} |]
compControlCMD (While cont body) = do
    s <- get
    noop <- do
        conte <- cont
        contc <- compExp conte
        case contc of
          C.Var (C.Id "false"  _) _ -> return True
          _ -> return False
    put s
    bodyc <- inNewBlock_ $ do
        conte <- cont
        contc <- compExp conte
        case contc of
          C.Var (C.Id "true"  _) _ -> return ()
          _ -> case viewNotExp contc of
              Just a -> addStm [cstm| if ($a) {break;} |]
              _      -> addStm [cstm| if (! $contc) {break;} |]
        body
    when (not noop) $ addStm [cstm| while (1) {$items:bodyc} |]
compControlCMD (For (lo,step,hi) body) = do
    loe   <- compExp lo
    hie   <- compExp $ borderVal hi
    (i,n) <- freshVar
    bodyc <- inNewBlock_ (body i)
    let incl = borderIncl hi
    let conte
          | incl && (step>=0) = [cexp| $id:n<=$hie |]
          | incl && (step<0)  = [cexp| $id:n>=$hie |]
          | step >= 0         = [cexp| $id:n< $hie |]
          | step < 0          = [cexp| $id:n> $hie |]
    let stepe
          | step == 1    = [cexp| $id:n++ |]
          | step == (-1) = [cexp| $id:n-- |]
          | step == 0    = [cexp| 0 |]
          | step >  0    = [cexp| $id:n = $id:n + $step |]
          | step <  0    = [cexp| $id:n = $id:n - $(negate step) |]
    addStm [cstm| for ($id:n=$loe; $conte; $stepe) {$items:bodyc} |]
compControlCMD Break = addStm [cstm| break; |]
compControlCMD (Assert cond msg) = do
    addInclude "<assert.h>"
    c <- compExp cond
    addStm [cstm| assert($c && $msg); |]

compIOMode :: IOMode -> String
compIOMode ReadMode      = "r"
compIOMode WriteMode     = "w"
compIOMode AppendMode    = "a"
compIOMode ReadWriteMode = "r+"

-- | Compile `FileCMD`
compFileCMD :: CompExp exp => FileCMD exp CGen a -> CGen a
compFileCMD (FOpen path mode) = do
    addInclude "<stdio.h>"
    addInclude "<stdlib.h>"
    sym <- gensym "v"
    addLocal [cdecl| typename FILE * $id:sym; |]
    addStm   [cstm| $id:sym = fopen($id:path',$string:mode'); |]
    return $ HandleComp sym
  where
    path' = show path
    mode' = compIOMode mode
compFileCMD (FClose h) = do
    addInclude "<stdio.h>"
    touchVar h
    addStm [cstm| fclose($id:h); |]
compFileCMD (FPrintf h form as) = do
    addInclude "<stdio.h>"
    touchVar h
    let h'     = [cexp| $id:h |]
        form'  = show form
        form'' = [cexp| $id:form' |]
    as' <- fmap ([h',form'']++) $ sequence [compExp a | PrintfArg a <- as]
    addStm [cstm| fprintf($args:as'); |]
compFileCMD cmd@(FGet h) = do
    addInclude "<stdio.h>"
    (v,n) <- freshVar
    touchVar h
    let mkProxy = (\_ -> Proxy) :: FileCMD exp prog (exp a) -> Proxy a
        form    = formatSpecifier (mkProxy cmd)
    addStm [cstm| fscanf($id:h, $string:form, &$id:n); |]
    return v
compFileCMD (FEof h) = do
    addInclude "<stdbool.h>"
    addInclude "<stdio.h>"
    (v,n) <- freshVar
    touchVar h
    addStm [cstm| $id:n = feof($id:h); |]
    return v

compObjectCMD :: CompExp exp => ObjectCMD exp CGen a -> CGen a
compObjectCMD (NewObject t) = do
    sym <- gensym "obj"
    let t' = namedType t
    addLocal [cdecl| $ty:t' * $id:sym; |]
    return $ Object True t sym
compObjectCMD (InitObject fun pnt t args) = do
    sym <- gensym "obj"
    let t' = namedType t
    as  <- mapM mkArg args
    addLocal [cdecl| $ty:t' * $id:sym; |]
    addStm   [cstm|  $id:sym = $id:fun($args:as); |]
    return $ Object pnt t sym

compCallCMD :: CompExp exp => CallCMD exp CGen a -> CGen a
compCallCMD (AddInclude inc)    = addInclude inc
compCallCMD (AddDefinition def) = addGlobal def
compCallCMD (AddExternFun fun res args) = do
    tres  <- compTypeP res
    targs <- mapM mkParam args
    addGlobal [cedecl| extern $ty:tres $id:fun($params:targs); |]
compCallCMD (AddExternProc proc args) = do
    targs <- mapM mkParam args
    addGlobal [cedecl| extern void $id:proc($params:targs); |]
compCallCMD (CallFun fun as) = do
    as'   <- mapM mkArg as
    (v,n) <- freshVar
    addStm [cstm| $id:n = $id:fun($args:as'); |]
    return v
compCallCMD (CallProc fun as) = do
    as' <- mapM mkArg as
    addStm [cstm| $id:fun($args:as'); |]

instance CompExp exp                => Interp (RefCMD exp)     CGen where interp = compRefCMD
instance (CompExp exp, EvalExp exp) => Interp (ArrCMD exp)     CGen where interp = compArrCMD
instance CompExp exp                => Interp (ControlCMD exp) CGen where interp = compControlCMD
instance CompExp exp                => Interp (FileCMD exp)    CGen where interp = compFileCMD
instance CompExp exp                => Interp (ObjectCMD exp)  CGen where interp = compObjectCMD
instance CompExp exp                => Interp (CallCMD exp)    CGen where interp = compCallCMD

