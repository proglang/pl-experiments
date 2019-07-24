open Syntax
module T = Types
module Region = T.Region
module C = Constraint
module Normal = Constraint.Normal


let fail fmt =
  Zoo.error ~kind:"Type error" fmt

let is_var = function
  | Var _ -> true
  | _ -> false

let rec is_nonexpansive = function
  | Constant _
  | Lambda _
  | Constructor _
  | Var _
  | Borrow _
  | ReBorrow _
  | Array []
    -> true
  | Tuple l
  | App (Constructor _, l) ->
    List.for_all is_nonexpansive l
  | Region (_, e) -> is_nonexpansive e
  | Let (_, _, e1, e2) ->
    is_nonexpansive e1 && is_nonexpansive e2
  | Match (_, e, l) ->
    is_nonexpansive e &&
    List.for_all (fun (_, e) -> is_nonexpansive e) l
  | App (_, _)
  | Array _
    -> false

(** Instance *)
module Instantiate = struct

  let instance_kvar ~level ~ktbl id =
    try
      Name.Tbl.find ktbl id
    with Not_found ->
      let b = T.kind ~name:id.name level in
      Name.Tbl.add ktbl id b ;
      b
  let instance_tyvar ~level ~tbl id =
    try
      Name.Tbl.find tbl id
    with Not_found ->
      let b = T.var ~name:id.name level in
      Name.Tbl.add tbl id b ;
      b

  let rec instance_kind ~level ~ktbl = function
    | T.KVar {contents = KLink k} as korig ->
      let knew = instance_kind ~level ~ktbl k in
      if korig = knew then korig else knew
    | T.KVar {contents = KUnbound _} as k -> k
    | T.KGenericVar id -> snd @@ instance_kvar ~level ~ktbl id
    | T.Un _ | T.Aff _ | T.Lin _ as k -> k

  let rec instance_type ~level ~tbl ~ktbl = function
    | T.Var {contents = Link ty} -> instance_type ~level ~tbl ~ktbl ty
    | T.GenericVar id -> snd @@ instance_tyvar ~level ~tbl id
    | T.Var {contents = Unbound _} as ty -> ty
    | T.App(ty, args) ->
      let args = List.map (instance_type ~level ~tbl ~ktbl) args in
      App(ty, args)
    | T.Tuple args ->
      let args = List.map (instance_type ~level ~tbl ~ktbl) args in
      Tuple args
    | T.Borrow (r, k, ty) ->
      let k = instance_kind ~level ~ktbl k in
      let ty = instance_type ~level ~tbl ~ktbl ty in
      Borrow (r, k, ty)
    | T.Arrow(param_ty, k, return_ty) ->
      Arrow(instance_type ~level ~tbl ~ktbl param_ty,
            instance_kind ~level ~ktbl k,
            instance_type ~level ~tbl ~ktbl return_ty)


  let instance_constr ~level ~ktbl l =
    let f = instance_kind ~level ~ktbl in
    List.map (fun (k1,k2) -> (f k1, f k2)) l

  let included tbl vars = 
    Name.Tbl.keys tbl
    |> Iter.for_all
      (fun x -> CCList.mem ~eq:Name.equal x vars)

  let kind_scheme ~level ~kargs ~ktbl {T. kvars; constr; args; kind } =
    let kl = List.length kargs and l = List.length args in
    if kl <> l then
      fail
        "This type constructor is applied to %i types \
         but has only %i parameters." l kl;
    let constr =
      List.fold_left2 (fun l k1 k2 -> (k1, k2) :: l)
        constr
        kargs
        args
    in
    let constr = instance_constr ~level ~ktbl constr in
    let kind = instance_kind ~level ~ktbl kind in
    assert (included ktbl kvars);
    (constr, kind)

  let typ_scheme ~level ~env ~tbl ~ktbl {T. constr ; tyvars; kvars; ty } =
    let c = instance_constr ~level ~ktbl constr in
    let ty = instance_type ~level ~tbl ~ktbl ty in
    let env =
      List.fold_left
        (fun env (t,k) ->
           let ty = fst @@ Name.Tbl.find tbl t in
           let kind = T.kscheme (instance_kind ~level ~ktbl k) in
           Env.add_ty ty kind env)
        env
        tyvars
    in
    assert (included ktbl kvars);
    assert (included tbl @@ List.map fst tyvars);
    (env, c, ty)

  let go_constr level constr =
    let ktbl = Name.Tbl.create 10 in
    instance_constr ~level ~ktbl constr
  let go_kscheme ?(args=[]) level k =
    let ktbl = Name.Tbl.create 10 in
    kind_scheme ~level ~kargs:args ~ktbl k
  let go level env ty =
    let tbl = Name.Tbl.create 10 in
    let ktbl = Name.Tbl.create 10 in
    typ_scheme ~level ~env ~tbl ~ktbl ty

end
let instantiate = Instantiate.go

(** Unification *)
module Kind = struct

  exception Fail of T.kind * T.kind

  let adjust_levels tvar_id tvar_level kind =
    let rec f : T.kind -> _ = function
      | T.KVar {contents = T.KLink k} -> f k
      | T.KGenericVar _ -> assert false
      | T.KVar ({contents = T.KUnbound(other_id, other_level)} as other_tvar) ->
        if other_id = tvar_id then
          fail "Recursive types"
        else
          other_tvar := KUnbound(other_id, min tvar_level other_level)
      | T.Un _ | T.Aff _ | T.Lin _ -> ()
    in
    f kind

  let rec unify k1 k2 = match k1, k2 with
    | _, _ when k1 == k2
      -> ()

    | T.Un r1, T.Un r2
    | T.Aff r1, T.Aff r2
    | T.Lin r1, T.Lin r2
      -> if Region.equal r1 r2 then () else raise (Fail (k1, k2))

    | T.KVar {contents = KUnbound(id1, _)},
      T.KVar {contents = KUnbound(id2, _)} when Name.equal id1 id2 ->
      (* There is only a single instance of a particular type variable. *)
      assert false

    | T.KVar {contents = KLink k1}, k2
    | k1, T.KVar {contents = KLink k2} -> unify k1 k2

    | T.KVar ({contents = KUnbound (id, level)} as tvar), ty
    | ty, T.KVar ({contents = KUnbound (id, level)} as tvar) ->
      adjust_levels id level ty ;
      tvar := KLink ty ;
      ()

    | _, T.KGenericVar _ | T.KGenericVar _, _ ->
      (* Should always have been instantiated before *)
      assert false

    | (T.Aff _ | T.Un _ | T.Lin _),
      (T.Aff _ | T.Un _ | T.Lin _)
      -> raise (Fail (k1, k2))

  (* let unify k1 k2 =
   *   Format.eprintf "Unifying %a and %a@." Printer.kind k1 Printer.kind k2 ;
   *   unify k1 k2 *)
  
  module Lat = struct
    type t =
      | Un of Region.t
      | Aff of Region.t
      | Lin of Region.t
    let (<) l1 l2 = match l1, l2 with
      | Lin r1, Lin r2
      | Aff r1, Aff r2
      | Un r1, Un r2 -> Region.compare r1 r2 <= 0
      | _, Lin Never -> true
      | Un Global, _ -> true
      | Un r1, Aff r2 | Un r1, Lin r2 | Aff r1, Lin r2 ->
        Region.compare r1 r2 <= 0
      | _ -> false
    let (=) l1 l2 = match l1, l2 with
      | Lin r1, Lin r2
      | Aff r1, Aff r2
      | Un r1, Un r2 -> Region.equal r1 r2
      | _ -> false
    let smallest = Un Region.smallest
    let biggest = Lin Region.biggest
    let max l1 l2 = match l1, l2 with
      | Un r1, Un r2 -> Un (Region.max r1 r2)
      | Aff r1, Aff r2 -> Aff (Region.max r1 r2)
      | Lin r1, Lin r2 -> Lin (Region.max r1 r2)
      | Un _, (Aff _ as r)
      | (Un _ | Aff _), (Lin _ as r)
      | (Lin _ as r), (Un _ | Aff _)
      | (Aff _ as r), Un _ -> r
    let min l1 l2 = match l1, l2 with
      | Un r1, Un r2 -> Un (Region.min r1 r2)
      | Aff r1, Aff r2 -> Aff (Region.min r1 r2)
      | Lin r1, Lin r2 -> Lin (Region.min r1 r2)
      | (Aff _ | Lin _), (Un _ as r)
      | Lin _, (Aff _ as r)
      | (Un _ as r), (Aff _ | Lin _) 
      | (Aff _ as r), Lin _
        -> r
    let least_upper_bound = List.fold_left max smallest
    let greatest_lower_bound = List.fold_left min biggest
    let constants =
      [ Un Global ; Un Never ;
        Aff Global ; Aff Never ;
        Lin Global ; Lin Never ;
      ]
    let relations consts =
      let consts = constants @ consts in
      CCList.product (fun l r -> l, r) consts consts
      |> CCList.filter (fun (l, r) -> l < r)
  end
    
  (* TOFIX: Use an immutable reasonable representation. *)
  module K = struct
    (* type t = Var of Name.t | Constant of Lat.t
     * let equal l1 l2 = match l1, l2 with
     *   | Var n1, Var n2 -> Name.equal n1 n2
     *   | Constant l1, Constant l2 -> Lat.equal l1 l2
     *   | _ -> false
     * let hash = Hashtbl.hash
     * let compare l1 l2 = if equal l1 l2 then 0 else compare l1 l2 *)
    type t = T.kind
               
    let rec shorten = function
      | Types.KVar {contents = KLink k} -> shorten k
      | Types.Un _ | Types.Aff _ | Types.Lin _ | Types.KGenericVar _
      | Types.KVar {contents = KUnbound _} as k -> k

    let equal a b = shorten a = shorten b
    let hash x = Hashtbl.hash (shorten x)
    let compare a b = Pervasives.compare (shorten a) (shorten b)

    type constant = Lat.t
    let rec classify = function
      | T.KVar { contents = KLink k } -> classify k
      | T.KVar { contents = KUnbound _ }
      | T.KGenericVar _ -> `Var
      | T.Lin r -> `Constant (Lat.Lin r)
      | T.Aff r -> `Constant (Lat.Aff r)
      | T.Un r -> `Constant (Lat.Un r)
    let constant = function
      | Lat.Lin r -> T.Lin r
      | Lat.Aff r -> T.Aff r
      | Lat.Un r -> T.Un r
    let unify = function
      | [] -> assert false
      | [ x ] -> x
      | h :: t -> List.fold_left (fun k1 k2 -> unify k1 k2; k1) h t

  end
  include Constraint.Make(Lat)(K)

  let solve ?keep_vars c =
    try solve ?keep_vars c with
    | IllegalEdge (k1, k2) -> raise (Fail (K.constant k1, K.constant k2))
    | IllegalBounds (k1, v, k2) ->
      fail "The kind inequality %a < %a < %a is not satisfiable."
        Printer.kind (K.constant k1)
        Printer.kind v
        Printer.kind (K.constant k2)

  (* let solve ?keep_vars l =
   *   Format.eprintf "@[<2>Solving:@ %a@]@."
   *     Printer.constrs l ;
   *   let l' = solve ?keep_vars l in
   *   Format.eprintf "@[<2>To:@ %a@]@."
   *     Printer.constrs l' ;
   *   l' *)
  
  let un = T.Un Global
  let constr = Normal.cleq
  let first_class n k = C.(k <= T.Lin (Region n))
end

module Simplification = struct
  open Variance

  module PosMap = struct
    type bimap = { ty : Variance.Map.t ; kind : variance Kind.Map.t }
    let empty = { ty = Variance.Map.empty ; kind = Kind.Map.empty }
    let add_ty m ty v =
      { m with ty = Variance.Map.add m.ty ty v }
    let add_kind m k v =
      let add m k v =
        Kind.Map.update
          k (function None -> Some v | Some v' -> Some (merge v v')) m
      in { m with kind = add m.kind k v }
    let add_kinds m k v =
      let f m set var =
        Kind.Set.fold (fun name m -> Kind.Map.add name var m) set m
      in { m with kind = f m.kind k v }
  end

  let rec collect_kind ~level ~variance map = function
    | T.KVar {contents = KUnbound(_, other_level)} as k
      when other_level > level ->
      PosMap.add_kind map k variance
    | T.KVar {contents = KLink ty} -> collect_kind ~level ~variance map ty
    | ( T.KGenericVar _
      | T.KVar {contents = KUnbound _}
      | T.Un _ | T.Aff _ | T.Lin _
      ) -> map
  
  let rec collect_type ~level ~variance map = function
    | T.GenericVar _ -> map
    | T.Var { contents = Link t } ->
      collect_type ~level ~variance map t
    | T.Var {contents = Unbound(name, other_level)} ->
      if other_level > level
      then PosMap.add_ty map name variance
      else map
    | T.App (_, args) ->
      (* TOFIX : This assumes that constructors are covariant. This is wrong *)
      List.fold_left (fun map t ->
          collect_type ~level ~variance:Invar map t
        ) map args
    | T.Arrow (ty1, k, ty2) ->
      let map = collect_type ~level ~variance:(neg variance) map ty1 in
      let map = collect_kind ~level ~variance map k in
      let map = collect_type ~level ~variance map ty2 in
      map
    | T.Tuple tys ->
      let aux map ty = collect_type ~level ~variance map ty in
      List.fold_left aux map tys
    | T.Borrow (_, k, ty) ->
      let map = collect_type ~level ~variance map ty in
      let map = collect_kind ~level ~variance map k in
      map

  
  let collect_kscheme ~level ~variance map = function
    | {T. kvars = []; constr = []; args = [] ; kind } ->
      collect_kind ~level ~variance map kind
    | ksch ->
      fail "Trying to generalize kinda %a. \
            This kind has already been generalized."
        Printer.kscheme ksch

  let collect_kschemes ~env ~level map =
    Name.Map.fold
      (fun ty variance map -> 
         collect_kscheme ~level ~variance map (Env.find_ty ty env))
      map.PosMap.ty map

  let go ~env ~level ~constr tys kinds =
    let map = PosMap.empty in
    let map =
      List.fold_left
        (fun map (k,variance) -> collect_kind ~level ~variance map k)
        map kinds
    in
    let map =
      List.fold_left (collect_type ~level ~variance:Pos) map tys
    in
    let map = collect_kschemes ~env ~level map in
    Kind.solve ~keep_vars:map.kind constr
end

(** Generalization *)
module Generalize = struct

  let update_kind ~kenv k =
    kenv := Kind.Set.add k !kenv
  let update_type ~tyenv k =
    tyenv := Name.Set.add k !tyenv
  
  let rec gen_kind ~level ~kenv = function
    | T.KVar {contents = KUnbound(id, other_level)} as k
      when other_level > level ->
      update_kind ~kenv k ;
      T.KGenericVar id
    | T.KVar {contents = KLink ty} -> gen_kind ~level ~kenv ty
    | ( T.KGenericVar _
      | T.KVar {contents = KUnbound _}
      | T.Un _ | T.Aff _ | T.Lin _
      ) as ty -> ty

  let rec gen_ty ~env ~level ~tyenv ~kenv = function
    | T.Var {contents = Unbound(id, other_level)} when other_level > level ->
      update_type ~tyenv id ;
      T.GenericVar id
    | T.App(ty, ty_args) ->
      App(ty, List.map (gen_ty ~env ~level ~tyenv ~kenv) ty_args)
    | T.Tuple ty_args ->
      Tuple (List.map (gen_ty ~env ~level ~tyenv ~kenv) ty_args)
    | T.Borrow (r, k, ty) ->
      Borrow (r, gen_kind ~level ~kenv k, gen_ty ~env ~level ~tyenv ~kenv ty)
    | T.Arrow(param_ty, k, return_ty) ->
      Arrow(gen_ty ~env ~level ~tyenv ~kenv param_ty,
            gen_kind ~level ~kenv k,
            gen_ty ~env ~level ~tyenv ~kenv return_ty)
    | T.Var {contents = Link ty} -> gen_ty ~env ~level ~tyenv ~kenv ty
    | ( T.GenericVar _
      | T.Var {contents = Unbound _}
      ) as ty -> ty
  
  let gen_kscheme ~level ~kenv = function
    | {T. kvars = []; constr = []; args = [] ; kind } ->
      gen_kind ~level ~kenv kind
    | ksch ->
      fail "Trying to generalize kinda %a. \
            This kind has already been generalized."
        Printer.kscheme ksch

  let gen_kschemes ~env ~level ~kenv tyset =
    let get_kind (env : Env.t) id =
      gen_kscheme ~level ~kenv (Env.find_ty id env)
    in
    Name.Set.fold (fun ty l -> (ty, get_kind env ty)::l) tyset []

  let rec gen_constraint ~level = function
    | [] -> Normal.ctrue, Normal.ctrue
    | (k1, k2) :: rest ->
      let kenv = ref Kind.Set.empty in
      let k1 = gen_kind ~level ~kenv k1 in
      let k2 = gen_kind ~level ~kenv k2 in
      let constr = Normal.cleq k1 k2 in
      let c1, c2 =
        if Kind.Set.is_empty !kenv
        then constr, Normal.ctrue
        else Normal.ctrue, constr
      in
      let no_vars, vars = gen_constraint ~level rest in
      Normal.(c1 @ no_vars , c2 @ vars)

  let collect_gen_vars ~kenv l =
    let add_if_gen = function
      | T.KGenericVar _ as k ->
        update_kind ~kenv k
      | _ -> ()
    in
    List.iter (fun (k1, k2) -> add_if_gen k1; add_if_gen k2) l

  let kinds_as_vars l =
    Name.Set.elements @@ T.Free_vars.kinds l

  let typs ~env ~level constr tys =
    let constr = Simplification.go ~env ~level ~constr tys [] in

    let tyenv = ref Name.Set.empty in
    let kenv = ref Kind.Set.empty in

    (* We built the type skeleton and collect the kindschemes *)
    let tys = List.map (gen_ty ~env ~level ~tyenv ~kenv) tys in
    let tyvars = gen_kschemes ~env ~level ~kenv !tyenv in

    (* Split the constraints that are actually generalized *)
    let constr_no_var, constr = gen_constraint ~level constr in
    let constr_all = Normal.(constr_no_var @ constr) in

    collect_gen_vars ~kenv constr ;
    let kvars = kinds_as_vars @@ Kind.Set.elements !kenv in
    let env = Name.Set.fold (fun ty env -> Env.rm_ty ty env) !tyenv env in

    env, constr_all, List.map (T.tyscheme ~constr ~tyvars ~kvars) tys

  let typ ~env ~level constr ty =
    let env, constrs, tys = typs ~env ~level constr [ty] in
    match tys with
    | [ ty ] -> env, constrs, ty
    | _ -> assert false
  
  let kind ~env ~level constr args k =
    let constr =
      let l = List.map (fun k -> (k, Variance.Neg)) args @ [k, Variance.Pos] in
      Simplification.go ~env ~level ~constr [] l
    in

    let tyenv = ref Name.Set.empty in
    let kenv = ref Kind.Set.empty in

    (* We built the type skeleton and collect the kindschemes *)
    let k = gen_kind ~level ~kenv k in
    let args = List.map (gen_kind ~level ~kenv) args in

    (* Split the constraints that are actually generalized *)
    let constr_no_var, constr = gen_constraint ~level constr in
    let constr_all = Normal.(constr_no_var @ constr) in

    collect_gen_vars ~kenv constr ;
    let kvars = kinds_as_vars @@ Kind.Set.elements !kenv in
    let env = Name.Set.fold (fun ty env -> Env.rm_ty ty env) !tyenv env in

    env, constr_all,
    T.kscheme ~constr ~kvars ~args k

  (** The real generalization function that is aware of the value restriction. *)
  let typ env level generalize constr ty =
    if generalize then
      typ ~env ~level constr ty
    else
      env, constr, T.tyscheme ty
  let typs env level generalize constr tys =
    if generalize then
      typs ~env ~level constr tys
    else
      env, constr, List.map T.tyscheme tys

end

let rec infer_kind ~level ~env = function
  | T.App (f, args) ->
    let constrs, args = infer_kind_many ~level ~env args in
    let constr', kind =
      Instantiate.go_kscheme level ~args @@ Env.find_constr f env
    in
    Normal.(constr' @ constrs), kind
  | T.Tuple args ->
    let constrs, args = infer_kind_many ~level ~env args in
    let _, return_kind = T.kind ~name:"t" level in
    let constr_tup =
      Normal.cand @@ List.map (fun k -> Normal.cleq k return_kind) args
    in
    Normal.(constr_tup @ constrs), return_kind
  | T.Arrow (_, k, _) -> Normal.ctrue, k
  | T.GenericVar n -> Instantiate.go_kscheme level @@ Env.find_ty n env
  | T.Var { contents = T.Unbound (n, _) } ->
    Instantiate.go_kscheme level @@ Env.find_ty n env
  | T.Var { contents = T.Link ty } ->
    infer_kind ~level ~env ty
  | T.Borrow (_, k, _) ->
    Normal.ctrue, k

and infer_kind_many ~level ~env l = 
  List.fold_right
    (fun ty (constrs, args) ->
       let constr, k = infer_kind ~level ~env ty in
       Normal.(constr @ constrs) , k::args)
    l ([], [])

module Unif = struct

  exception Fail of T.typ * T.typ

  let occurs_check_adjust_levels tvar_id tvar_level ty =
    let rec f : T.typ -> _ = function
      | T.Var {contents = T.Link ty} -> f ty
      | T.GenericVar _ -> assert false
      | T.Var ({contents = T.Unbound(other_id, other_level)} as other_tvar) ->
        if other_id = tvar_id then
          fail "Recursive types"
        else
          other_tvar := Unbound(other_id, min tvar_level other_level)
      | T.App(_, ty_args)
      | T.Tuple ty_args ->
        List.iter f ty_args
      | T.Arrow(param_ty, _,return_ty) ->
        f param_ty ;
        f return_ty
      | T.Borrow (_, _, ty) -> f ty
    in
    f ty

  let rec unify env ty1 ty2 = match ty1, ty2 with
    | _, _ when ty1 == ty2 -> Normal.ctrue

    | T.App(ty1, ty_arg1), T.App(ty2, ty_arg2) when Name.equal ty1 ty2 ->
      Normal.cand (List.map2 (unify env) ty_arg1 ty_arg2)

    | T.Borrow (r1, k1, ty1), T.Borrow (r2, k2, ty2) when T.Borrow.equal r1 r2 ->
      Normal.cand [
        Kind.constr k1 k2 ;
        unify env ty1 ty2 ;
      ]

    | T.Arrow(param_ty1, k1, return_ty1), T.Arrow(param_ty2, k2, return_ty2) ->
      Normal.cand [
        Kind.constr k1 k2;
        unify env param_ty2 param_ty1;
        unify env return_ty1 return_ty2;
      ]
    | T.Tuple tys1, Tuple tys2 ->
      List.flatten @@ List.map2 (unify env) tys1 tys2

    | T.Var {contents = Link ty1}, ty2 -> unify env ty1 ty2
    | ty1, T.Var {contents = Link ty2} -> unify env ty1 ty2

    | T.Var {contents = Unbound(id1, _)},
      T.Var {contents = Unbound(id2, _)} when id1 = id2 ->
      (* There is only a single instance of a particular type variable. *)
      assert false

    | (T.Var ({contents = Unbound(id, level)} as tvar) as ty1), (ty as ty2)
    | (ty as ty1), (T.Var ({contents = Unbound(id, level)} as tvar) as ty2) ->
      occurs_check_adjust_levels id level ty ;
      let constr1, k1 = infer_kind ~env ~level ty1 in
      let constr2, k2 = infer_kind ~env ~level ty2 in
      tvar := Link ty ;
      Normal.cand [constr1; constr2; Kind.constr k1 k2; Kind.constr k2 k1]

    | _, _ ->
      raise (Fail (ty1, ty2))

end

module Pat_modifier = struct

  type t =
    | Direct
    | Borrow of borrow * T.kind

  let app m t = match m with
    | Direct -> t
    | Borrow (b, k0) -> T.Borrow (b,k0,t)

  let with_kind m (t,k) = match m with
    | Direct -> (t,k)
    | Borrow (b, k0) -> T.Borrow (b,k0,t), k0

  let from_match_spec ~level : Syntax.match_spec -> _ = function
    | None -> Direct
    | Some b ->
      let _, k = T.kind ~name:"k" level in
      Borrow (b,k)
  
end

let normalize_constr env l =
  let rec unify_all = function
    | T.Eq (t1, t2) -> Unif.unify env t1 t2
    | T.KindLeq (k1, k2) -> Kind.constr k1 k2
    | T.And l -> Normal.cand (List.map unify_all l)
    | T.True -> Normal.ctrue
  in
  Kind.solve @@ unify_all (T.And l)

let normalize (env, constr, ty) = env, normalize_constr env [constr], ty

let constant_scheme = let open T in function
    | Int _ -> tyscheme Builtin.int
    | Y ->
      let name, a = T.gen_var () in
      tyscheme ~tyvars:[name, Kind.un] Builtin.((a @-> a) @-> a)
    | Primitive s ->
      Builtin.(PrimMap.find s primitives)

let constant level env c =
  let e, constr, ty =
    instantiate level env @@ constant_scheme c
  in
  Multiplicity.empty, e, constr, ty

let with_binding env x ty f =
  let env = Env.add x ty env in
  let multis, env, constr, ty = f env in
  let env = Env.rm x env in
  multis, env, constr, ty

let with_type ~name ~env ~level f =
  let var_name, ty = T.var ~name level in
  let _, kind = T.kind ~name level in
  let kind_scheme = T.kscheme kind in
  let env = Env.add_ty var_name kind_scheme env in
  f env ty kind


let rec infer_pattern env level = function
  | PUnit ->
    env, T.True, [], Builtin.unit_ty
  | PAny ->
    with_type ~name:"any" ~env ~level @@ fun env ty k ->
    let constr = C.cand [
        C.(k <= Aff Never) ;
      ]
    in
    env, constr, [], ty
  | PVar n ->
    with_type ~name:n.name ~env ~level @@ fun env ty k ->
    env, T.True, [n, ty, k], ty
  | PConstr (constructor, None) ->
    let env, constructor_constr, constructor_ty =
      instantiate level env @@ Env.find constructor env
    in
    let top_ty = constructor_ty in
    let constr = C.cand [
        C.denormal constructor_constr ;
      ]
    in
    env, constr, [], top_ty
  | PConstr (constructor, Some pat) ->
    let env, constructor_constr, constructor_ty =
      instantiate level env @@ Env.find constructor env
    in
    let param_ty, top_ty = match constructor_ty with
      | Types.Arrow (ty1, T.Un Global, ty2) -> ty1, ty2
      | _ -> assert false
    in
    let env, constr, params, ty = infer_pattern env level pat in
    let constr = C.cand [
        C.(ty <== param_ty) ;
        constr;
        C.denormal constructor_constr ;
      ]
    in
    env, constr, params, top_ty
  | PTuple l ->
    let rec gather_pats (env, constrs, params, tys) = function
      | [] -> env, constrs, List.rev params, List.rev tys
      | pat :: t ->
        let env, constr, param, ty = infer_pattern env level pat in
        gather_pats (env, C.(constr &&& constrs), param@params, ty::tys) t
    in
    let env, constrs, params, tys = gather_pats (env, T.True, [], []) l in
    let ty = T.Tuple tys in
    env, constrs, params, ty

and with_pattern
    ?(pat_modifier=Pat_modifier.Direct) env level generalize pat kont =
  let env, constr, params, pat_ty = infer_pattern env level pat in
  let constr = normalize_constr env [constr] in
  let input_ty = Pat_modifier.app pat_modifier pat_ty in
  let params =
    let f (n,t,k) =
      let (t,k) = Pat_modifier.with_kind pat_modifier (t,k) in (n, t, k)
    in List.map f params
  in
  let tys = List.map (fun (_,t,_) -> t) params in
  let env, constr, schemes = Generalize.typs env level generalize constr tys in
  let rec with_bindings env (params, schemes) kont = match (params, schemes) with
    | [],[] -> kont env constr input_ty
    | (name, _, _)::params, scheme::schemes ->
      with_binding env name scheme @@ fun env ->
      with_bindings env (params, schemes) kont
    | _ -> assert false
  in
  let mults, env, constrs, ty = with_bindings env (params, schemes) kont in
  let mults, weaken_consts =
    List.fold_left (fun (m, c') (n,_,k) ->
        let c, m = Multiplicity.exit_binder m n k in m, C.(c &&& c'))
      (mults, T.True) params
  in
  let constrs = normalize_constr env [
      C.denormal constrs;
      weaken_consts;
    ]
  in
  mults, env, constrs, ty



let rec infer (env : Env.t) level = function
  | Constant c -> constant level env c
  | Lambda(param, body) ->
    let _, arrow_k = T.kind ~name:"ar" level in
    let mults, env, constr, (param_ty, return_ty) =
      infer_lambda env level (param, body)
    in
    let constr = normalize_constr env [
        C.denormal constr;
        Multiplicity.constraint_all mults arrow_k;
      ]
    in
    let ty = T.Arrow (param_ty, arrow_k, return_ty) in
    mults, env, constr, ty
    
  | Array elems -> 
    with_type ~name:"v" ~level ~env @@ fun env array_ty _ ->
    let mults, env, constrs, tys = 
      infer_many env level Multiplicity.empty elems
    in 
    let f elem_ty = C.(elem_ty <== array_ty) in
    let elem_constr = CCList.map f tys in
    let constr = normalize_constr env [
        constrs ;
        C.cand elem_constr ;
      ]
    in
    mults, env, constr, Builtin.array array_ty
  | Tuple elems -> 
    let mults, env, constrs, tys =
      infer_many env level Multiplicity.empty elems
    in
    let constr = normalize_constr env [
        constrs ;
      ]
    in
    mults, env, constr, T.Tuple tys
  | Constructor name ->
    let env, constr1, t = instantiate level env @@ Env.find name env in
    let constr2, k = infer_kind ~level ~env t in
    assert (k = Kind.un) ;
    let constr = normalize_constr env [
        C.denormal constr1;
        C.denormal constr2
      ]
    in
    Multiplicity.empty, env, constr, t

  | Var name ->
    let (name, k), env, constr, ty = infer_var env level name in
    Multiplicity.var name k, env, constr, ty

  | Borrow (r, name) ->
    let _, borrow_k = T.kind ~name:"b" level in
    let (name, _), env, constr, var_ty = infer_var env level name in
    (* let bound_k = match r with
     *   | Mutable -> T.Aff (Region level)
     *   | Immutable ->  T.Un (Region level)
     * in *)
    let mults = Multiplicity.borrow name r borrow_k in 
    let constr = normalize_constr env [
        C.denormal constr;
        (* C.(bound_k <= borrow_k); *)
      ]
    in
    mults, env, constr, T.Borrow (r, borrow_k, var_ty)
  | ReBorrow (r, name) ->
    let _, var_k = T.kind ~name:"v" level in
    let _, borrow_k = T.kind ~name:"b" level in
    let (name, _), env, constr, var_ty = infer_var env level name in
    (* let bound_k = match r with
     *   | Mutable -> T.Aff (Region level)
     *   | Immutable ->  T.Un (Region level)
     * in *)
    with_type ~name:name.name ~env ~level @@ fun env ty _ ->
    let borrow_ty = T.Borrow (Mutable, var_k, ty) in
    let mults = Multiplicity.borrow name r borrow_k in
    let constr = normalize_constr env [
        C.denormal constr;
        C.(var_ty <== borrow_ty);
        (* C.(bound_k <= borrow_k); *)
      ]
    in
    mults, env, constr, T.Borrow (r, borrow_k, ty)
  | Let (NonRec, pattern, expr, body) ->
    let mults1, env, expr_constr, expr_ty =
      infer env (level + 1) expr
    in
    let generalize = is_nonexpansive expr in
    with_pattern env level generalize pattern @@ fun env pat_constr pat_ty ->
    let mults2, env, body_constr, body_ty = infer env level body in
    let mults, constr_merge = Multiplicity.merge mults1 mults2 in
    let constr = normalize_constr env [
        C.(expr_ty <== pat_ty) ;
        C.denormal expr_constr ;
        C.denormal pat_constr ;
        C.denormal body_constr ;
        constr_merge ;
      ]
    in
    mults, env, constr, body_ty
  | Let (Rec, PVar n, expr, body) ->
    with_type ~name:n.name ~env ~level:(level + 1) @@ fun env ty k ->
    with_binding env n (T.tyscheme ty) @@ fun env ->
    let mults1, env, expr_constr, expr_ty =
      infer env (level + 1) expr
    in
    let expr_constr = normalize_constr env [
        C.(k <= Un Never) ;
        C.(expr_ty <== ty) ;
        C.denormal expr_constr
      ]
    in
    let generalize = is_nonexpansive expr in
    let env, remaining_constr, scheme =
      Generalize.typ env level generalize expr_constr ty
    in
    with_binding env n scheme @@ fun env ->
    let mults2, env, body_constr, body_ty = infer env level body in
    let mults, constr_merge = Multiplicity.merge mults1 mults2 in
    let constr = normalize_constr env [
        C.denormal expr_constr ;
        C.denormal remaining_constr ;
        C.denormal body_constr ;
        constr_merge ;
      ]
    in
    mults, env, constr, body_ty
  | Let (Rec, p, _, _) ->
    fail "Such patterns are not allowed on the left hand side of a let rec@ %a"
      Printer.pattern p

  | Match (match_spec, expr, cases) ->
    let mults, env, expr_constrs, match_ty = infer env level expr in
    with_type ~name:"pat" ~env ~level @@ fun env return_ty _ ->
    let pat_modifier = Pat_modifier.from_match_spec ~level match_spec in
    let aux env case =
      let mults, env, constrs, (pattern, body_ty) =
        infer_lambda ~pat_modifier env level case
      in
      let constrs = normalize_constr env [
          C.denormal constrs;
          C.(match_ty <== pattern);
          C.(body_ty <== return_ty);
        ]
      in
      env, (mults, constrs)
    in
    let env, l = CCList.fold_map aux env cases in
    let reduce (m1,c1) (m2,c2) =
      let mults, mult_c = Multiplicity.parallel_merge m1 m2 in
      let constrs = C.cand [mult_c; c1; C.denormal c2] in
      mults, constrs
    in 
    let mults, match_constrs = List.fold_left reduce (mults, T.True) l in
    let constrs = normalize_constr env [
        C.denormal expr_constrs;
        match_constrs ;
      ]
    in
    mults, env, constrs, return_ty
    
  | App(fn_expr, arg) ->
    infer_app env level fn_expr arg

  | Region (vars, expr) ->
    with_type ~name:"r" ~env ~level @@ fun env return_ty return_kind ->
    let mults, env, constr, infered_ty = infer env (level+1) expr in
    let mults, exit_constr = Multiplicity.exit_region vars (level+1) mults in 
    let constr = normalize_constr env [
        C.denormal constr;
        C.(infered_ty <== return_ty);
        Kind.first_class level return_kind;
        exit_constr;
      ]
    in
    mults, env, constr, return_ty

and infer_lambda ?pat_modifier env level (pattern, body_expr) =
  with_pattern ?pat_modifier env level false pattern @@
  fun env param_constr input_ty ->
  let mults, env, constr, return_ty =
    infer env level body_expr
  in
  let constr = normalize_constr env [
      C.denormal constr;
      C.denormal param_constr;
    ]
  in
  mults, env, constr, (input_ty, return_ty)
  
and infer_var env level name =
  let env, constr1, t = instantiate level env @@ Env.find name env in
  let constr2, k = infer_kind ~level ~env t in
  let constr = normalize_constr env [C.denormal constr1; C.denormal constr2] in
  (name, k), env, constr, t

and infer_many (env0 : Env.t) level mult l =
  let rec aux mults0 env0 constr0 tys = function
    | [] -> (mults0, env0, constr0, List.rev tys)
    | expr :: rest ->
      let mults, env, constr, ty = infer env0 level expr in
      let mults, constr_merge = Multiplicity.merge mults mults0 in
      let constr = C.cand [
          C.denormal constr;
          constr0;
          constr_merge;
        ]
      in
      aux mults env constr (ty :: tys) rest
  in aux mult env0 True [] l

and infer_app (env : Env.t) level fn_expr args =
  let f (f_ty, env) param_ty =
    let _, k = T.kind ~name:"a" level in
    with_type ~name:"a" ~level ~env @@ fun env return_ty _ ->
    let constr = C.(f_ty <== T.Arrow (param_ty, k, return_ty)) in
    (return_ty, env), constr
  in
  let mults, env, fn_constr, fn_ty = infer env level fn_expr in
  let mults, env, arg_constr, tys = infer_many env level mults args in
  let (return_ty, env), app_constr = CCList.fold_map f (fn_ty, env) tys in
  let constr = normalize_constr env [
      C.denormal fn_constr ;
      arg_constr ;
      C.cand app_constr ;
    ]
  in
  mults, env, constr, return_ty

let infer_top env _rec_flag n e =
  let _, env, constr, ty =
    let level = 1 in
    with_type ~name:n.Name.name ~env ~level @@ fun env ty _k ->
    with_binding env n (T.tyscheme ty) @@ fun env ->
    infer env level e
  in
  let g = is_nonexpansive e in
  let env, constr, scheme = Generalize.typ env 0 g constr ty in

  (* Check that the residual constraints are satisfiable. *)
  let constr = normalize_constr env [C.denormal @@ Instantiate.go_constr 0 constr] in

  (* Remove unused variables in the environment *)
  let free_vars =
    Name.Map.fold
      (fun _ sch e -> Name.Set.union e @@ T.Free_vars.scheme sch)
      env.vars
      (T.Free_vars.scheme scheme)
  in
  let env = Env.filter_ty (fun n _ -> Name.Set.mem n free_vars) env in

  (* assert (constr = C.True) ; *)
  constr, env, scheme

let make_type_decl ~env ~constr kargs kind typs =
  let constructor_constrs =
    List.map (fun typ ->
        let constr', inferred_k = infer_kind ~env ~level:1 typ in
        C.cand [C.denormal constr' ; C.( inferred_k <= kind ) ]
      ) typs
  in
  (* Format.eprintf "%a@." Printer.kind inferred_k ; *)
  let constr = normalize_constr env [
      C.denormal constr ;
      C.cand constructor_constrs ;
    ]
  in

  (* Format.eprintf "%a@." Printer.constrs constr ; *)
  let env, leftover_constr, kscheme =
    Generalize.kind ~env ~level:0 constr kargs kind
  in
  
  (* Check that the residual constraints are satisfiable. *)
  let _ = normalize_constr env
      [C.denormal @@ Instantiate.go_constr 0 leftover_constr] in

  (* assert (constr = C.True) ; *)
  env, kscheme

let make_type_scheme ~env ~constr typ =
  let constr = normalize_constr env [C.denormal constr ] in
  let env, leftover_constr, tyscheme =
    Generalize.typ env 0 true constr typ
  in
  (* Check that the residual constraints are satisfiable. *)
  let _ = normalize_constr env
      [C.denormal @@ Instantiate.go_constr 0 leftover_constr] in

  (* assert (constr = C.True) ; *)
  env, tyscheme
