module TTImp.Elab.App

import Core.Context
import Core.Core
import Core.Env
import Core.Normalise
import Core.Unify
import Core.TT
import Core.Value

import TTImp.Elab.Check
import TTImp.TTImp

%default covering

getNameType : {vars : _} ->
              {auto c : Ref Ctxt Defs} ->
              {auto e : Ref EST (EState vars)} ->
              RigCount -> Env Term vars -> FC -> Name -> Maybe (Glued vars) ->
              Core (Term vars, Glued vars)
getNameType rigc env fc x expected
    = case defined x env of
           Just (_ ** (rigb, lv)) => 
              do rigSafe rigb rigc
                 defs <- get Ctxt
                 let bty = binderType (getBinder lv env)
                 pure (Local fc (Just rigb) _ lv, gnf defs env bty)
           Nothing => 
              do defs <- get Ctxt
                 [(fullname, i, def)] <- lookupCtxtName x (gamma defs)
                      | [] => throw (UndefinedName fc x)
                      | ns => throw (AmbiguousName fc (map fst ns))
                 let nt = case definition def of
                               Fn _ => Func
                               DCon t a => DataCon t a
                               TCon t a _ _ _ => TyCon t a
                               _ => Func
                 pure (Ref fc nt (Resolved i), gnf defs env (embed (type def)))
  where
    rigSafe : RigCount -> RigCount -> Core ()
    rigSafe Rig1 RigW = throw (LinearMisuse fc x Rig1 RigW)
    rigSafe Rig0 RigW = throw (LinearMisuse fc x Rig0 RigW)
    rigSafe Rig0 Rig1 = throw (LinearMisuse fc x Rig0 Rig1)
    rigSafe _ _ = pure ()

isHole : NF vars -> Bool
isHole (NApp _ (NMeta _ _ _) _) = True
isHole _ = False

mutual
  makeImplicit : {vars : _} ->
                 {auto c : Ref Ctxt Defs} ->
                 {auto u : Ref UST UState} ->
                 {auto e : Ref EST (EState vars)} ->
                 RigCount -> ElabInfo -> Env Term vars -> 
                 FC -> (fntm : Term vars) -> 
                 Name -> NF vars -> (Closure vars -> Core (NF vars)) ->
                 (expargs : List RawImp) ->
                 (impargs : List (Maybe Name, RawImp)) ->
                 (expected : Maybe (Glued vars)) ->
                 Core (Term vars, Glued vars)
  makeImplicit rig elabinfo env fc tm x aty sc expargs impargs expty
      = do defs <- get Ctxt
           nm <- genMVName x
           empty <- clearDefs defs
           metaty <- quote empty env aty
           metaval <- metaVar fc rig env nm metaty
           let fntm = App fc tm (appInf (Just x) Implicit) metaval
           fnty <- sc (toClosure defaultOpts env metaval)
           checkAppWith rig elabinfo env fc
                        fntm fnty expargs impargs expty

  makeAutoImplicit : {vars : _} ->
                     {auto c : Ref Ctxt Defs} ->
                     {auto u : Ref UST UState} ->
                     {auto e : Ref EST (EState vars)} ->
                     RigCount -> ElabInfo -> Env Term vars -> 
                     FC -> (fntm : Term vars) -> 
                     Name -> NF vars -> (Closure vars -> Core (NF vars)) ->
                     (expargs : List RawImp) ->
                     (impargs : List (Maybe Name, RawImp)) ->
                     (expected : Maybe (Glued vars)) ->
                     Core (Term vars, Glued vars)
  makeAutoImplicit rig elabinfo env fc tm x aty sc expargs impargs expty
       = throw (InternalError "Auto implicits not yet implemented")
           
  -- Check the rest of an application given the argument type and the
  -- raw argument. We choose elaboration order depending on whether we know
  -- the argument's type now. If we don't know it, elaborate the rest of the
  -- application first and come back to it. This might help with type-directed
  -- disambiguation when elaborating the argument.
  checkRestApp : {vars : _} ->
                 {auto c : Ref Ctxt Defs} ->
                 {auto u : Ref UST UState} ->
                 {auto e : Ref EST (EState vars)} ->
                 RigCount -> RigCount -> ElabInfo -> Env Term vars -> 
                 FC -> AppInfo -> (fntm : Term vars) -> Name ->
                 (aty : NF vars) -> (sc : Closure vars -> Core (NF vars)) ->
                 (arg : RawImp) ->
                 (expargs : List RawImp) ->
                 (impargs : List (Maybe Name, RawImp)) ->
                 (expected : Maybe (Glued vars)) ->
                 Core (Term vars, Glued vars)
  checkRestApp rig argRig elabinfo env fc appinf tm x aty sc arg 
               expargs impargs expty
     -- If the expected argument type is a metavariable, do the rest
     -- of the application first in the hope that it's filled in
     -- (this can help disambiguation)
       = if False -- isHole aty
            -- TODO: This is probably a bad idea. Better to postpone only
            -- if we got a disambiguation error, perhaps?
            then do
               defs <- get Ctxt
               nm <- genMVName x
               empty <- clearDefs defs
               metaty <- quote empty env aty
               metaval <- metaVar fc argRig env nm metaty
               let fntm = App fc tm appinf metaval
               logNF 10 ("Delaying " ++ show nm ++ " " ++ show arg) env aty
               fnty <- sc (toClosure defaultOpts env metaval)
               (tm, gty) <- checkAppWith rig elabinfo env fc
                                         fntm fnty expargs impargs expty
               defs <- get Ctxt
               aty' <- nf defs env metaty
               logNF 10 ("Now trying " ++ show nm ++ " " ++ show arg) env aty'
               (argv, argt) <- check argRig (nextLevel elabinfo)
                                     env arg (Just (glueBack defs env aty'))
               defs <- get Ctxt
               [] <- convert fc elabinfo env (gnf defs env metaval)
                                             (gnf defs env argv)
                  | cs => throw (CantConvert fc env metaval argv)
               pure (tm, gty)
            else do
               defs <- get Ctxt
               logNF 10 ("Argument type " ++ show x) env aty
               logNF 10 ("Full function type") env 
                        (NBind fc x (Pi argRig Explicit aty) sc)
               logC 10 (do ety <- maybe (pure Nothing)
                                        (\t => pure (Just !(toFullNames!(getTerm t))))
                                        expty
                           pure ("Overall expected type: " ++ show ety))
               (argv, argt) <- check argRig (nextLevel elabinfo)
                                     env arg (Just (glueBack defs env aty))
               let fntm = App fc tm appinf argv
               fnty <- sc (toClosure defaultOpts env argv)
               checkAppWith rig elabinfo env fc 
                            fntm fnty expargs impargs expty  

  -- Check an application of 'fntm', with type 'fnty' to the given list
  -- of explicit and implicit arguments.
  -- Returns the checked term and its (weakly) normalised type
  checkAppWith : {vars : _} ->
                 {auto c : Ref Ctxt Defs} ->
                 {auto u : Ref UST UState} ->
                 {auto e : Ref EST (EState vars)} ->
                 RigCount -> ElabInfo -> Env Term vars -> 
                 FC -> (fntm : Term vars) -> (fnty : NF vars) ->
                 (expargs : List RawImp) ->
                 (impargs : List (Maybe Name, RawImp)) ->
                 (expected : Maybe (Glued vars)) ->
                 Core (Term vars, Glued vars)
  -- Ordinary explicit argument
  checkAppWith rig elabinfo env fc tm (NBind tfc x (Pi rigb Explicit aty) sc)
               (arg :: expargs) impargs expty 
      = do let argRig = rigMult rig rigb
           checkRestApp rig argRig elabinfo env fc (explApp (Just x))
                        tm x aty sc arg expargs impargs expty

  -- If there's no more arguments given, and the plicities of the type and
  -- the expected type line up, stop
  checkAppWith rig elabinfo env fc tm ty@(NBind tfc x (Pi rigb Implicit aty) sc)
               [] [] (Just expty_in)
      = do let argRig = rigMult rig rigb
           expty <- getNF expty_in
           defs <- get Ctxt
           case expty of
                NBind tfc' x' (Pi rigb' Implicit aty') sc'
                   => checkExp rig elabinfo env fc tm (glueBack defs env ty) (Just expty_in)
                _ => makeImplicit argRig elabinfo env fc tm x aty sc [] [] (Just expty_in)
  checkAppWith rig elabinfo env fc tm ty@(NBind tfc x (Pi rigb AutoImplicit aty) sc)
               [] [] (Just expty_in)
      = do let argRig = rigMult rig rigb
           expty <- getNF expty_in
           defs <- get Ctxt
           case expty of
                NBind tfc' x' (Pi rigb' AutoImplicit aty') sc'
                   => checkExp rig elabinfo env fc tm (glueBack defs env ty) (Just expty_in)
                _ => makeAutoImplicit argRig elabinfo env fc tm x aty sc [] [] (Just expty_in)

  -- Check next auto implicit argument
  checkAppWith rig elabinfo env fc tm (NBind tfc x (Pi rigb AutoImplicit aty) sc)
               expargs ((Nothing, arg) :: impargs) expty
      = do let argRig = rigMult rig rigb
           checkRestApp rig argRig elabinfo env fc (appInf (Just x) AutoImplicit)
                        tm x aty sc arg expargs impargs expty
  checkAppWith rig elabinfo env fc tm (NBind tfc x (Pi rigb AutoImplicit aty) sc)
               expargs impargs expty
      = makeAutoImplicit rig elabinfo env fc tm x aty sc expargs impargs expty
  -- Check next implicit argument
  checkAppWith rig elabinfo env fc tm (NBind tfc x (Pi rigb Implicit aty) sc)
               expargs impargs expty
      = case useImp x [] impargs of
             Nothing => makeImplicit rig elabinfo env fc tm 
                                     x aty sc expargs impargs expty
             Just (arg, impargs') =>
                do let argRig = rigMult rig rigb
                   checkRestApp rig argRig elabinfo env fc 
                                (appInf (Just x) Implicit)
                                tm x aty sc arg expargs impargs' expty
    where
      useImp : Name -> List (Maybe Name, RawImp) -> List (Maybe Name, RawImp) ->
               Maybe (RawImp, List (Maybe Name, RawImp))
      useImp x acc [] = Nothing
      useImp x acc ((Just x', xtm) :: rest)
          = if x == x'
               then Just (xtm, acc ++ rest)
               else useImp x ((Just x', xtm) :: acc) rest
      useImp x acc (ximp :: rest)
          = useImp x (ximp :: acc) rest

  checkAppWith rig elabinfo env fc tm ty [] [] expty 
      = do defs <- get Ctxt
           checkExp rig elabinfo env fc tm (glueBack defs env ty) expty
  checkAppWith rig elabinfo env fc tm ty [] impargs expty 
      = throw (InvalidImplicits fc env (map fst impargs) tm)
  checkAppWith {vars} rig elabinfo env fc tm ty (arg :: expargs) impargs expty 
      = -- Invent a function type,  and hope that we'll know enough to solve it
        -- later when we unify with expty
        do argn <- genName "argTy"
           retn <- genName "retTy"
           argTy <- metaVar fc Rig0 env argn (TType fc)
           defs <- get Ctxt
           let argTyG = gnf defs env argTy
           -- Can't use 'metaVar' to record it for binding because it's
           -- in a different scope... so it'll stay global
           retTy <- newMeta {vars = argn :: vars}
                            fc Rig0 (Pi RigW Explicit argTy :: env) 
                            retn (TType fc)
           (argv, argt) <- check rig (nextLevel elabinfo)
                                 env arg (Just argTyG)
           let fntm = App fc tm (appInf Nothing Explicit) argv
           fnty <- nf defs env (Bind fc argn (Let RigW argv argTy) retTy)
           checkAppWith rig elabinfo env fc fntm fnty expargs impargs expty

export
checkApp : {vars : _} ->
           {auto c : Ref Ctxt Defs} ->
           {auto u : Ref UST UState} ->
           {auto e : Ref EST (EState vars)} ->
           RigCount -> ElabInfo -> Env Term vars -> 
           FC -> (fn : RawImp) -> 
           (expargs : List RawImp) -> 
           (impargs : List (Maybe Name, RawImp)) ->
           Maybe (Glued vars) ->
           Core (Term vars, Glued vars)
checkApp rig elabinfo env fc (IApp fc' fn arg) expargs impargs exp
   = checkApp rig elabinfo env fc' fn (arg :: expargs) impargs exp
checkApp rig elabinfo env fc (IImplicitApp fc' fn nm arg) expargs impargs exp
   = checkApp rig elabinfo env fc' fn expargs ((nm, arg) :: impargs) exp
checkApp rig elabinfo env fc (IVar fc' n) expargs impargs exp
   = do (ntm, nty_in) <- getNameType rig env fc n Nothing
        nty <- getNF nty_in
        logC 10 (do defs <- get Ctxt
                    fnty <- quote defs env nty
                    exptyt <- maybe (pure Nothing) 
                                       (\t => do ety <- getTerm t
                                                 pure (Just !(toFullNames ety)))
                                       exp
                    pure ("Checking application of " ++ show n ++
                          " to " ++ show expargs ++ "\n\tFunction type " ++
                          (show !(toFullNames fnty)) ++ "\n\tExpected app type "
                                ++ show exptyt))
        checkAppWith rig elabinfo env fc ntm nty expargs impargs exp
checkApp rig elabinfo env fc fn expargs impargs exp
   = do (fntm, fnty_in) <- checkImp rig elabinfo env fn Nothing
        fnty <- getNF fnty_in
        checkAppWith rig elabinfo env fc fntm fnty expargs impargs exp

