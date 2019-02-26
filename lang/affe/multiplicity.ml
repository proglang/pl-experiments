module T = Types

type use =
  | Shadow
  | Borrow of (T.Borrow.t * T.kind list)
  | Normal of T.kind list
type t = use Name.Map.t
let empty = Name.Map.empty
let var x k = Name.Map.singleton x (Normal [k])
let borrow x r k = Name.Map.singleton x (Borrow (r, [k]))

exception Fail of Name.t * use * use
let fail n u1 u2 = raise (Fail (n, u1, u2))

let constr_all_kinds ~bound ks =
  List.map (fun k -> Constraint.(k <= bound)) ks

let merge (e1 : t) (e2 : t) =
  let constr = ref [] in
  let bound = T.Un Never in
  let constr_kinds ks =
    constr := (constr_all_kinds ~bound ks) @ !constr
  in
  let aux x u1 u2 = match u1, u2 with
    | Shadow, u -> Some u
    | Borrow (Read, k1), Borrow (Read, k2) ->
      Some (Borrow (Read, k1@k2))
    | Normal l1, Normal l2 ->
      let l = l1 @ l2 in
      constr_kinds l ;
      Some (Normal l)
    | Borrow _, Borrow (Write, _)
    | Borrow (Write,_), Borrow _
    | _, Shadow
    | Borrow _, Normal _
    | Normal _, Borrow _ -> fail x u1 u2
  in
  let m = Name.Map.union aux e1 e2 in
  m, Constraint.cand !constr

let parallel_merge  (e1 : t) (e2 : t) =
  let aux x u1 u2 = match u1, u2 with
    | Shadow, Shadow -> Some Shadow
    | Borrow (Read as r, k1), Borrow (Read, k2)
    | Borrow (Write as r, k1), Borrow (Write, k2) ->
      Some (Borrow (r, k1@k2))
    | Normal l1, Normal l2 ->
      let l = l1 @ l2 in
      Some (Normal l)
    | Borrow _, Borrow (Write, _)
    | Borrow (Write,_), Borrow _
    | Borrow _, Normal _
    | Shadow, _ | _, Shadow
    | Normal _, Borrow _ -> fail x u1 u2
  in
  let m = Name.Map.union aux e1 e2 in
  m, Constraint.T.True

let constraint_all (e : t) bound : T.constr =
  let aux _ ks l = match ks with
    | Normal ks -> constr_all_kinds ~bound ks @ l
    | Borrow _ | Shadow -> []
  in
  let l = Name.Map.fold aux e [] in
  Constraint.cand l

let exit_scope (e : t) =
  let aux u = match u with
    | Borrow _ -> Shadow
    | _ -> u
  in
  Name.Map.map aux e

let weaken (e : t) x k : T.constr * t =
  let constr = match Name.Map.find_opt x e with
    | Some Shadow
    | Some Borrow _
    | Some Normal [_]
      -> T.True
    | None | Some Normal [] | Some Normal _ ->
      Constraint.(k <= T.Aff Never)
  in
  constr, Name.Map.remove x e
