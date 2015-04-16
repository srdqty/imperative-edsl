{-# LANGUAGE CPP #-}
{-# LANGUAGE UndecidableInstances #-}

-- | Deep embedding of imperative programs. The embedding is parameterized on the expression
-- language.

module Language.Embedded.Imperative
  ( module Data.TypePredicates
  , module Control.Monad.Operational.Compositional
  , module Language.Embedded.Interpretation

    -- * Working with instruction sets
  , IPred
  , IExp
  , injPE
  , prjPE
  , injE
  , prjE
  , singlePE
  , singleE

    -- * Commands
  , Ref (..)
  , RefCMD (..)
  , Arr (..)
  , ArrCMD (..)
  , ControlCMD (..)
  , Handle (..)
  , FileCMD (..)
  , ConsoleCMD (..)
  , TimeCMD (..)

    -- * Running commands
  , runRefCMD
  , runArrCMD
  , runControlCMD
  , runFileCMD
  , runConsoleCMD
  , runTimeCMD

    -- * User interface
  , newRef
  , initRef
  , getRef
  , setRef
  , modifyRef
  , unsafeFreezeRef
  , newArr
  , getArr
  , setArr
  , iff
  , while
  , break
  , open
  , close
  , fput
  , fget
  , feof
  , PrintfArg
  , printf
  , getTime
  ) where



import Prelude hiding (break)

import Control.Monad (when)
import Data.Array.IO
import Data.IORef
import Data.Typeable
import qualified System.IO as IO
import System.IO.Unsafe
import Text.Printf (PrintfArg)
import qualified Text.Printf as Printf

import Data.Constraint

import Data.ALaCarte
import Data.TypePredicates
import Control.Monad.Operational.Compositional
import Language.Embedded.Interpretation

import Data.Char (isSpace)


----------------------------------------------------------------------------------------------------
-- * Working with instruction sets
----------------------------------------------------------------------------------------------------

-- | Extract the value predicate from an instruction set
--
-- 'IPred' and 'IExp' are needed to avoid types like
-- @(`SomeInstr` pred exp `:<:` i) => `Program` i ()@. Here it is not possible to constrain @pred@
-- and @exp@ by constraining @i@, so the instance search will always fail. Functions like 'injPE'
-- solve this by using 'IPred' and 'IExp' to determine @pred@ and @exp@ from @i@. For this to work,
-- one must use an instruction set @i@ that has an instance of 'IPred' and 'IExp'. By using
-- instruction sets of the form @(`RefCMD` SomePred SomeExp `:+:` ...)@, such instances are obtained
-- for free (see the available instances defined in this module). Then functions like 'injPE' will
-- determine the predicate and expression type from the first summand, which may or may not be the
-- desired behavior. It is of course also possible to make custom instruction types with custom
-- instances of 'IPred' and 'IExp'.
type family IPred (i :: (* -> *) -> * -> *) :: * -> Constraint

-- | Extract the value predicate from an instruction set. See the documentation of 'IPred' for more
-- information.
type family IExp  (i :: (* -> *) -> * -> *) :: * -> *

-- | Inject an instruction that is parameterized by a value predicate and an expression type
injPE :: (i (IPred instr) (IExp instr) :<: instr) => i (IPred instr) (IExp instr) m a -> instr m a
injPE = inj

-- | Project an instruction that is parameterized by a value predicate and an expression type
prjPE :: (i (IPred instr) (IExp instr) :<: instr) =>
    instr m a -> Maybe (i (IPred instr) (IExp instr) m a)
prjPE = prj

-- | Inject an instruction that is parameterized by an expression type
injE :: (i (IExp instr) :<: instr) => i (IExp instr) m a -> instr m a
injE = inj

-- | Project an instruction that is parameterized by an expression type
prjE :: (i (IExp instr) :<: instr) => instr m a -> Maybe (i (IExp instr) m a)
prjE = prj

-- | Create a program from an instruction that is parameterized by a value predicate and an
-- expression type
singlePE :: (i (IPred instr) (IExp instr) :<: instr) =>
    i (IPred instr) (IExp instr) (ProgramT instr m) a -> ProgramT instr m a
singlePE = singleton . inj

-- | Create a program from an instruction that is parameterized by an expression type
singleE :: (i (IExp instr) :<: instr) => i (IExp instr) (ProgramT instr m) a -> ProgramT instr m a
singleE = singleton . inj



----------------------------------------------------------------------------------------------------
-- * Commands
----------------------------------------------------------------------------------------------------

data Ref a
    = RefComp VarId
    | RefEval (IORef a)
  deriving Typeable

-- | Commands for mutable references
data RefCMD p exp (prog :: * -> *) a
  where
    NewRef          :: p a => RefCMD p exp prog (Ref a)
    InitRef         :: p a => exp a -> RefCMD p exp prog (Ref a)
    GetRef          :: p a => Ref a -> RefCMD p exp prog (exp a)
    SetRef          ::        Ref a -> exp a -> RefCMD p exp prog ()
#if  __GLASGOW_HASKELL__>=708
  deriving Typeable
#endif

instance MapInstr (RefCMD p exp)
  where
    imap _ NewRef              = NewRef
    imap _ (InitRef a)         = InitRef a
    imap _ (GetRef r)          = GetRef r
    imap _ (SetRef r a)        = SetRef r a

type instance IPred (RefCMD p e)       = p
type instance IExp  (RefCMD p e)       = e
type instance IPred (RefCMD p e :+: i) = p
type instance IExp  (RefCMD p e :+: i) = e

data Arr n a
    = ArrComp String
    | ArrEval (IOArray Int a)
  deriving Typeable

-- | Commands for mutable arrays
data ArrCMD p exp (prog :: * -> *) a
  where
    NewArr :: (p a, p n, Integral n) => exp n -> exp a   -> ArrCMD p exp prog (Arr n a)
    GetArr :: (p a, Integral n)      => exp n -> Arr n a -> ArrCMD p exp prog (exp a)
    SetArr :: (Integral n)           => exp n -> exp a   -> Arr n a -> ArrCMD p exp prog ()
#if  __GLASGOW_HASKELL__>=708
  deriving Typeable
#endif

instance MapInstr (ArrCMD p exp)
  where
    imap _ (NewArr n a)     = NewArr n a
    imap _ (GetArr i arr)   = GetArr i arr
    imap _ (SetArr i a arr) = SetArr i a arr

type instance IPred (ArrCMD p e)       = p
type instance IExp  (ArrCMD p e)       = e
type instance IPred (ArrCMD p e :+: i) = p
type instance IExp  (ArrCMD p e :+: i) = e

data ControlCMD exp prog a
  where
    If    :: exp Bool -> prog () -> prog () -> ControlCMD exp prog ()
    While :: prog (exp Bool) -> prog () -> ControlCMD exp prog ()
    Break :: ControlCMD exp prog ()

instance MapInstr (ControlCMD exp)
  where
    imap g (If c t f)        = If c (g t) (g f)
    imap g (While cont body) = While (g cont) (g body)
    imap _ Break             = Break

type instance IExp  (ControlCMD e)       = e
type instance IExp  (ControlCMD e :+: i) = e
type instance IPred (ControlCMD e :+: i) = IPred i

data Handle
    = HandleComp String
    | HandleEval IO.Handle
  deriving Typeable

data FileCMD exp (prog :: * -> *) a
  where
    Open  :: FilePath            -> FileCMD exp prog Handle -- todo: allow specifying read/write mode
    Close :: Handle              -> FileCMD exp prog ()
    Put   :: Handle -> exp Float -> FileCMD exp prog ()
    Get   :: Handle              -> FileCMD exp prog (exp Float) -- todo: generalize to arbitrary types
    Eof   :: Handle              -> FileCMD exp prog (exp Bool)

instance MapInstr (FileCMD exp)
  where
    imap _ (Open file) = Open file
    imap _ (Close hdl) = Close hdl
    imap _ (Put hdl a) = Put hdl a
    imap _ (Get hdl)   = Get hdl
    imap _ (Eof hdl)   = Eof hdl

type instance IExp  (FileCMD e)       = e
type instance IExp  (FileCMD e :+: i) = e
type instance IPred (FileCMD e :+: i) = IPred i

data ConsoleCMD exp (prog :: * -> *) a
  where
    Printf :: PrintfArg a => String -> exp a -> ConsoleCMD exp prog ()

instance MapInstr (ConsoleCMD exp)
  where
    imap _ (Printf form a) = Printf form a

type instance IExp  (ConsoleCMD e)       = e
type instance IExp  (ConsoleCMD e :+: i) = e
type instance IPred (ConsoleCMD e :+: i) = IPred i

data TimeCMD exp (prog :: * -> *) a
  where
    GetTime :: TimeCMD exp prog (exp Double)

instance MapInstr (TimeCMD exp)
  where
    imap _ GetTime = GetTime

type instance IExp  (TimeCMD e)       = e
type instance IExp  (TimeCMD e :+: i) = e
type instance IPred (TimeCMD e :+: i) = IPred i



----------------------------------------------------------------------------------------------------
-- * Running commands
----------------------------------------------------------------------------------------------------

runRefCMD :: forall pred exp prog a . (VarPred exp ~ pred)
          => EvalExp exp => RefCMD pred exp prog a -> IO a
runRefCMD (InitRef a)            = fmap RefEval $ newIORef $ evalExp a
runRefCMD NewRef                 = fmap RefEval $ newIORef (error "Reading uninitialized reference")
runRefCMD (SetRef (RefEval r) a) = writeIORef r $ evalExp a
runRefCMD (GetRef (RefEval (r :: IORef b)))
    = fmap litExp $ readIORef r

runArrCMD :: forall pred exp prog a . (EvalExp exp, VarPred exp ~ pred)
          => ArrCMD pred exp prog a -> IO a
runArrCMD (NewArr n a)               = fmap ArrEval $ newArray (0, fromIntegral (evalExp n) - 1) (evalExp a)
runArrCMD (SetArr i a (ArrEval arr)) = writeArray arr (fromIntegral (evalExp i)) (evalExp a)
runArrCMD (GetArr i (ArrEval (arr :: IOArray Int b)))
    = fmap litExp $ readArray arr (fromIntegral (evalExp i))

runControlCMD :: EvalExp exp => ControlCMD exp IO a -> IO a
runControlCMD (If c t f)        = if evalExp c then t else f
runControlCMD (While cont body) = loop
  where loop = do
          c <- cont
          when (evalExp c) $ body >> loop
runControlCMD Break = error "runControlCMD not implemented for Break"

readWord :: IO.Handle -> IO String
readWord h = do
    eof <- IO.hIsEOF h
    if eof
    then return ""
    else do
      c  <- IO.hGetChar h
      if isSpace c
      then return ""
      else do
        cs <- readWord h
        return (c:cs)

runFileCMD :: (EvalExp exp, VarPred exp Bool, VarPred exp Float) => FileCMD exp IO a -> IO a
runFileCMD (Open path)            = fmap HandleEval $ IO.openFile path IO.ReadWriteMode
runFileCMD (Close (HandleEval h)) = IO.hClose h
runFileCMD (Put (HandleEval h) a) = IO.hPrint h (evalExp a)
runFileCMD (Get (HandleEval h))   = do
    w <- readWord h
    case reads w of
        [(f,"")] -> return $ litExp f
        _        -> error $ "runFileCMD: Get: no parse (input " ++ show w ++ ")"
runFileCMD (Eof (HandleEval h)) = fmap litExp $ IO.hIsEOF h

runConsoleCMD :: EvalExp exp => ConsoleCMD exp IO a -> IO a
runConsoleCMD (Printf format a) = Printf.printf format (evalExp a)

runTimeCMD :: EvalExp exp => TimeCMD exp IO a -> IO a
runTimeCMD GetTime | False = undefined

instance (EvalExp exp, VarPred exp ~ pred)                  => Interp (RefCMD pred exp) IO where interp = runRefCMD
instance (EvalExp exp, VarPred exp ~ pred)                  => Interp (ArrCMD pred exp) IO where interp = runArrCMD
instance EvalExp exp                                        => Interp (ControlCMD exp)  IO where interp = runControlCMD
instance (EvalExp exp, VarPred exp Bool, VarPred exp Float) => Interp (FileCMD exp)     IO where interp = runFileCMD
instance EvalExp exp                                        => Interp (ConsoleCMD exp)  IO where interp = runConsoleCMD
instance EvalExp exp                                        => Interp (TimeCMD exp)     IO where interp = runTimeCMD



----------------------------------------------------------------------------------------------------
-- * User interface
----------------------------------------------------------------------------------------------------

-- | Create an uninitialized reference
newRef :: (IPred instr a, RefCMD (IPred instr) (IExp instr) :<: instr) => ProgramT instr m (Ref a)
newRef = singlePE NewRef

-- | Create an initialized reference
initRef :: (IPred instr a, RefCMD (IPred instr) (IExp instr) :<: instr) =>
    IExp instr a -> ProgramT instr m (Ref a)
initRef = singlePE . InitRef

-- | Get the contents of a reference
getRef :: (IPred instr a, RefCMD (IPred instr) (IExp instr) :<: instr) =>
    Ref a -> ProgramT instr m (IExp instr a)
getRef = singlePE . GetRef

-- | Set the contents of a reference
setRef :: (IPred instr a, RefCMD (IPred instr) (IExp instr) :<: instr) =>
    Ref a -> IExp instr a -> ProgramT instr m ()
setRef r = singlePE . SetRef r

-- | Modify the contents of reference
modifyRef :: (IPred instr a, RefCMD (IPred instr) (IExp instr) :<: instr, Monad m) =>
    Ref a -> (IExp instr a -> IExp instr a) -> ProgramT instr m ()
modifyRef r f = getRef r >>= setRef r . f

-- | Freeze the contents of reference (only safe if the reference is never written to after the
-- first action that makes use of the resulting expression)
unsafeFreezeRef :: (VarPred exp a, EvalExp exp, CompExp exp) => Ref a -> exp a
unsafeFreezeRef (RefEval r) = litExp (unsafePerformIO $ readIORef r)
unsafeFreezeRef (RefComp v) = varExp v

-- | Create an uninitialized an array
newArr :: (IPred instr a, IPred instr i, ArrCMD (IPred instr) (IExp instr) :<: instr, Integral i) =>
    IExp instr i -> IExp instr a -> ProgramT instr m (Arr i a)
newArr n a = singlePE $ NewArr n a

-- | Set the contents of an array
getArr :: (IPred instr a, ArrCMD (IPred instr) (IExp instr) :<: instr, Integral i) =>
    IExp instr i -> Arr i a -> ProgramT instr m (IExp instr a)
getArr i arr = singlePE (GetArr i arr)

-- | Set the contents of an array
setArr :: (IPred instr a, ArrCMD (IPred instr) (IExp instr) :<: instr, Integral i) =>
    IExp instr i -> IExp instr a -> Arr i a -> ProgramT instr m ()
setArr i a arr = singlePE (SetArr i a arr)

iff :: (ControlCMD (IExp instr) :<: instr)
    => IExp instr Bool
    -> ProgramT instr m ()
    -> ProgramT instr m ()
    -> ProgramT instr m ()
iff b t f = singleE $ If b t f

ifE
    :: ( IPred instr a
       , ControlCMD (IExp instr)           :<: instr
       , RefCMD (IPred instr) (IExp instr) :<: instr
       , Monad m
       )
    => IExp instr Bool
    -> ProgramT instr m (IExp instr a)
    -> ProgramT instr m (IExp instr a)
    -> ProgramT instr m (IExp instr a)
ifE b t f = do
    r <- newRef
    iff b (t >>= setRef r) (f >>= setRef r)
    getRef r

while :: (ControlCMD (IExp instr) :<: instr)
    => ProgramT instr m (IExp instr Bool)
    -> ProgramT instr m ()
    -> ProgramT instr m ()
while b t = singleE $ While b t

break :: (ControlCMD (IExp instr) :<: instr) => ProgramT instr m ()
break = singleE Break

open :: (FileCMD (IExp instr) :<: instr) => FilePath -> ProgramT instr m Handle
open = singleE . Open

close :: (FileCMD (IExp instr) :<: instr) => Handle -> ProgramT instr m ()
close = singleE . Close

fput :: (FileCMD (IExp instr) :<: instr) => Handle -> IExp instr Float -> ProgramT instr m ()
fput hdl = singleE . Put hdl

fget :: (FileCMD (IExp instr) :<: instr) => Handle -> ProgramT instr m (IExp instr Float)
fget = singleE . Get

feof :: (FileCMD (IExp instr) :<: instr) => Handle -> ProgramT instr m (IExp instr Bool)
feof = singleE . Eof

printf :: (PrintfArg a, ConsoleCMD (IExp instr) :<: instr) =>
    String -> IExp instr a -> ProgramT instr m ()
printf format = singleE . Printf format

getTime :: (TimeCMD (IExp instr) :<: instr) => ProgramT instr m (IExp instr Double)
getTime = singleE GetTime

