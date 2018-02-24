(**************************************************************************)
(*     Sail                                                               *)
(*                                                                        *)
(*  Copyright (c) 2013-2017                                               *)
(*    Kathyrn Gray                                                        *)
(*    Shaked Flur                                                         *)
(*    Stephen Kell                                                        *)
(*    Gabriel Kerneis                                                     *)
(*    Robert Norton-Wright                                                *)
(*    Christopher Pulte                                                   *)
(*    Peter Sewell                                                        *)
(*    Alasdair Armstrong                                                  *)
(*    Brian Campbell                                                      *)
(*    Thomas Bauereiss                                                    *)
(*    Anthony Fox                                                         *)
(*    Jon French                                                          *)
(*    Dominic Mulligan                                                    *)
(*    Stephen Kell                                                        *)
(*    Mark Wassell                                                        *)
(*                                                                        *)
(*  All rights reserved.                                                  *)
(*                                                                        *)
(*  This software was developed by the University of Cambridge Computer   *)
(*  Laboratory as part of the Rigorous Engineering of Mainstream Systems  *)
(*  (REMS) project, funded by EPSRC grant EP/K008528/1.                   *)
(*                                                                        *)
(*  Redistribution and use in source and binary forms, with or without    *)
(*  modification, are permitted provided that the following conditions    *)
(*  are met:                                                              *)
(*  1. Redistributions of source code must retain the above copyright     *)
(*     notice, this list of conditions and the following disclaimer.      *)
(*  2. Redistributions in binary form must reproduce the above copyright  *)
(*     notice, this list of conditions and the following disclaimer in    *)
(*     the documentation and/or other materials provided with the         *)
(*     distribution.                                                      *)
(*                                                                        *)
(*  THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS''    *)
(*  AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED     *)
(*  TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A       *)
(*  PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR   *)
(*  CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,          *)
(*  SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT      *)
(*  LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF      *)
(*  USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND   *)
(*  ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,    *)
(*  OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT    *)
(*  OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF    *)
(*  SUCH DAMAGE.                                                          *)
(**************************************************************************)

open Parse_ast
open Ast
open Ast_util
module Big_int = Nat_big_num
open Type_check

let size_set_limit = 64

let optmap v f =
  match v with
  | None -> None
  | Some v -> Some (f v)

let kbindings_from_list = List.fold_left (fun s (v,i) -> KBindings.add v i s) KBindings.empty
let bindings_from_list = List.fold_left (fun s (v,i) -> Bindings.add v i s) Bindings.empty
(* union was introduced in 4.03.0, a bit too recently *)
let bindings_union s1 s2 =
  Bindings.merge (fun _ x y -> match x,y with
  |  _, (Some x) -> Some x
  |  (Some x), _ -> Some x
  |  _,  _ -> None) s1 s2
let kbindings_union s1 s2 =
  KBindings.merge (fun _ x y -> match x,y with
  |  _, (Some x) -> Some x
  |  (Some x), _ -> Some x
  |  _,  _ -> None) s1 s2

let subst_nexp substs nexp =
  let rec s_snexp substs (Nexp_aux (ne,l) as nexp) =
    let re ne = Nexp_aux (ne,l) in
    let s_snexp = s_snexp substs in
    match ne with
    | Nexp_var (Kid_aux (_,l) as kid) ->
       (try KBindings.find kid substs
       with Not_found -> nexp)
    | Nexp_id _
    | Nexp_constant _ -> nexp
    | Nexp_times (n1,n2) -> re (Nexp_times (s_snexp n1, s_snexp n2))
    | Nexp_sum (n1,n2)   -> re (Nexp_sum   (s_snexp n1, s_snexp n2))
    | Nexp_minus (n1,n2) -> re (Nexp_minus (s_snexp n1, s_snexp n2))
    | Nexp_exp ne -> re (Nexp_exp (s_snexp ne))
    | Nexp_neg ne -> re (Nexp_neg (s_snexp ne))
    | Nexp_app (id,args) -> re (Nexp_app (id,List.map s_snexp args))
  in s_snexp substs nexp

let rec subst_nc substs (NC_aux (nc,l) as n_constraint) =
  let snexp nexp = subst_nexp substs nexp in
  let snc nc = subst_nc substs nc in
  let re nc = NC_aux (nc,l) in
  match nc with
  | NC_equal (n1,n2) -> re (NC_equal (snexp n1, snexp n2))
  | NC_bounded_ge (n1,n2) -> re (NC_bounded_ge (snexp n1, snexp n2))
  | NC_bounded_le (n1,n2) -> re (NC_bounded_le (snexp n1, snexp n2))
  | NC_not_equal (n1,n2) -> re (NC_not_equal (snexp n1, snexp n2))
  | NC_set (kid,is) ->
     begin
       match KBindings.find kid substs with
       | Nexp_aux (Nexp_constant i,_) ->
          if List.exists (fun j -> Big_int.equal i j) is then re NC_true else re NC_false
       | nexp -> 
          raise (Reporting_basic.err_general l
                   ("Unable to substitute " ^ string_of_nexp nexp ^
                       " into set constraint " ^ string_of_n_constraint n_constraint))
       | exception Not_found -> n_constraint
     end
  | NC_or (nc1,nc2) -> re (NC_or (snc nc1, snc nc2))
  | NC_and (nc1,nc2) -> re (NC_and (snc nc1, snc nc2))
  | NC_true
  | NC_false
      -> n_constraint



let subst_src_typ substs t =
  let rec s_styp substs ((Typ_aux (t,l)) as ty) =
    let re t = Typ_aux (t,l) in
    match t with
    | Typ_id _
    | Typ_var _
      -> ty
    | Typ_fn (t1,t2,e) -> re (Typ_fn (s_styp substs t1, s_styp substs t2,e))
    | Typ_tup ts -> re (Typ_tup (List.map (s_styp substs) ts))
    | Typ_app (id,tas) -> re (Typ_app (id,List.map (s_starg substs) tas))
    | Typ_exist (kids,nc,t) ->
       let substs = List.fold_left (fun sub v -> KBindings.remove v sub) substs kids in
       re (Typ_exist (kids,nc,s_styp substs t))
  and s_starg substs (Typ_arg_aux (ta,l) as targ) =
    match ta with
    | Typ_arg_nexp ne -> Typ_arg_aux (Typ_arg_nexp (subst_nexp substs ne),l)
    | Typ_arg_typ t -> Typ_arg_aux (Typ_arg_typ (s_styp substs t),l)
    | Typ_arg_order _ -> targ
  in s_styp substs t

let make_vector_lit sz i =
  let f j = if Big_int.equal (Big_int.modulus (Big_int.shift_right i (sz-j-1)) (Big_int.of_int 2)) Big_int.zero then '0' else '1' in
  let s = String.init sz f in
  L_aux (L_bin s,Generated Unknown)

let tabulate f n =
  let rec aux acc n =
    let acc' = f n::acc in
    if Big_int.equal n Big_int.zero then acc' else aux acc' (Big_int.sub n (Big_int.of_int 1))
  in if Big_int.equal n Big_int.zero then [] else aux [] (Big_int.sub n (Big_int.of_int 1))

let make_vectors sz =
  tabulate (make_vector_lit sz) (Big_int.shift_left (Big_int.of_int 1) sz)

let pat_id_is_variable env id =
  match Env.lookup_id id env with
  (* Unbound is returned for both variables and constructors which take
     arguments, but the latter only don't appear in a P_id *)
  | Unbound
  (* Shadowing of immutable locals is allowed; mutable locals and registers
     are rejected by the type checker, so don't matter *)
  | Local _
  | Register _
    -> true
  | Enum _
  | Union _
    -> false

let rec is_value (E_aux (e,(l,annot))) =
  let is_constructor id =
    match annot with
    | None -> 
       (Reporting_basic.print_err false true l "Monomorphisation"
          ("Missing type information for identifier " ^ string_of_id id);
        false) (* Be conservative if we have no info *)
    | Some (env,_,_) ->
       Env.is_union_constructor id env ||
         (match Env.lookup_id id env with
         | Enum _ | Union _ -> true 
         | Unbound | Local _ | Register _ -> false)
  in
  match e with
  | E_id id -> is_constructor id
  | E_lit _ -> true
  | E_tuple es -> List.for_all is_value es
  | E_app (id,es) -> is_constructor id && List.for_all is_value es
  (* We add casts to undefined to keep the type information in the AST *)
  | E_cast (typ,E_aux (E_lit (L_aux (L_undef,_)),_)) -> true
(* TODO: more? *)
  | _ -> false

let is_pure (Effect_opt_aux (e,_)) =
  match e with
  | Effect_opt_pure -> true
  | Effect_opt_effect (Effect_aux (Effect_set [],_)) -> true
  | _ -> false

let rec list_extract f = function
  | [] -> None
  | h::t -> match f h with None -> list_extract f t | Some v -> Some v

let rec cross = function
  | [] -> failwith "cross"
  | [(x,l)] -> List.map (fun y -> [(x,y)]) l
  | (x,l)::t -> 
     let t' = cross t in
     List.concat (List.map (fun y -> List.map (fun l' -> (x,y)::l') t') l)

let rec cross' = function
  | [] -> [[]]
  | (h::t) ->
     let t' = cross' t in
     List.concat (List.map (fun x -> List.map (fun l ->  x::l) t') h)

let rec cross'' = function
  | [] -> [[]]
  | (k,None)::t -> List.map (fun l -> (k,None)::l) (cross'' t)
  | (k,Some h)::t ->
     let t' = cross'' t in
     List.concat (List.map (fun x -> List.map (fun l -> (k,Some x)::l) t') h)

let kidset_bigunion = function
  | [] -> KidSet.empty
  | h::t -> List.fold_left KidSet.union h t

(* TODO: deal with non-set constraints, intersections, etc somehow *)
let extract_set_nc l var nc =
  let rec aux (NC_aux (nc,l)) =
    let re nc = NC_aux (nc,l) in
    match nc with
    | NC_set (id,is) when Kid.compare id var = 0 -> Some (is,re NC_true)
    | NC_and (nc1,nc2) ->
       (match aux nc1, aux nc2 with
       | None, None -> None
       | None, Some (is,nc2') -> Some (is, re (NC_and (nc1,nc2')))
       | Some (is,nc1'), None -> Some (is, re (NC_and (nc1',nc2)))
       | Some _, Some _ ->
          raise (Reporting_basic.err_general l ("Multiple set constraints for " ^ string_of_kid var)))
    | _ -> None
  in match aux nc with
  | Some is -> is
  | None ->
     raise (Reporting_basic.err_general l ("No set constraint for " ^ string_of_kid var))

let rec peel = function
  | [], l -> ([], l)
  | h1::t1, h2::t2 -> let (l1,l2) = peel (t1, t2) in ((h1,h2)::l1,l2)
  | _,_ -> assert false

let rec split_insts = function
  | [] -> [],[]
  | (k,None)::t -> let l1,l2 = split_insts t in l1,k::l2
  | (k,Some v)::t -> let l1,l2 = split_insts t in (k,v)::l1,l2

let apply_kid_insts kid_insts t =
  let kid_insts, kids' = split_insts kid_insts in
  let kid_insts = List.map (fun (v,i) -> (v,Nexp_aux (Nexp_constant i,Generated Unknown))) kid_insts in
  let subst = kbindings_from_list kid_insts in
  kids', subst_src_typ subst t

let rec inst_src_type insts (Typ_aux (ty,l) as typ) =
  match ty with
  | Typ_id _
  | Typ_var _
    -> insts,typ
  | Typ_fn _ ->
     raise (Reporting_basic.err_general l "Function type in constructor")
  | Typ_tup ts ->
     let insts,ts = 
       List.fold_right
         (fun typ (insts,ts) -> let insts,typ = inst_src_type insts typ in insts,typ::ts)
         ts (insts,[])
     in insts, Typ_aux (Typ_tup ts,l)
  | Typ_app (id,args) ->
     let insts,ts = 
       List.fold_right
         (fun arg (insts,args) -> let insts,arg = inst_src_typ_arg insts arg in insts,arg::args)
         args (insts,[])
     in insts, Typ_aux (Typ_app (id,ts),l)
  | Typ_exist (kids, nc, t) ->
     let kid_insts, insts' = peel (kids,insts) in
     let kids', t' = apply_kid_insts kid_insts t in
     (* TODO: subst in nc *)
     match kids' with
     | [] -> insts', t'
     | _ -> insts', Typ_aux (Typ_exist (kids', nc, t'), l)
and inst_src_typ_arg insts (Typ_arg_aux (ta,l) as tyarg) =
  match ta with
  | Typ_arg_nexp _
  | Typ_arg_order _
      -> insts, tyarg
  | Typ_arg_typ typ ->
     let insts', typ' = inst_src_type insts typ in
     insts', Typ_arg_aux (Typ_arg_typ typ',l)

let rec contains_exist (Typ_aux (ty,_)) =
  match ty with
  | Typ_id _
  | Typ_var _
    -> false
  | Typ_fn (t1,t2,_) -> contains_exist t1 || contains_exist t2
  | Typ_tup ts -> List.exists contains_exist ts
  | Typ_app (_,args) -> List.exists contains_exist_arg args
  | Typ_exist _ -> true
and contains_exist_arg (Typ_arg_aux (arg,_)) =
  match arg with
  | Typ_arg_nexp _
  | Typ_arg_order _
      -> false
  | Typ_arg_typ typ -> contains_exist typ

let rec size_nvars_nexp (Nexp_aux (ne,_)) =
  match ne with
  | Nexp_var v -> [v]
  | Nexp_id _
  | Nexp_constant _
    -> []
  | Nexp_times (n1,n2)
  | Nexp_sum (n1,n2)
  | Nexp_minus (n1,n2)
    -> size_nvars_nexp n1 @ size_nvars_nexp n2
  | Nexp_exp n
  | Nexp_neg n
    -> size_nvars_nexp n
  | Nexp_app (_,args) -> List.concat (List.map size_nvars_nexp args)

(* Given a type for a constructor, work out which refinements we ought to produce *)
(* TODO collision avoidance *)
let split_src_type id ty (TypQ_aux (q,ql)) =
  let i = string_of_id id in
  (* This was originally written for the general case, but I cut it down to the
     more manageable prenex-form below *)
  let rec size_nvars_ty (Typ_aux (ty,l) as typ) =
    match ty with
    | Typ_id _
    | Typ_var _
      -> (KidSet.empty,[[],typ])
    | Typ_fn _ ->
       raise (Reporting_basic.err_general l ("Function type in constructor " ^ i))
    | Typ_tup ts ->
       let (vars,tys) = List.split (List.map size_nvars_ty ts) in
       let insttys = List.map (fun x -> let (insts,tys) = List.split x in
                                        List.concat insts, Typ_aux (Typ_tup tys,l)) (cross' tys) in
       (kidset_bigunion vars, insttys)
    | Typ_app (Id_aux (Id "vector",_),
               [Typ_arg_aux (Typ_arg_nexp sz,_);
                _;Typ_arg_aux (Typ_arg_typ (Typ_aux (Typ_id (Id_aux (Id "bit",_)),_)),_)]) ->
       (KidSet.of_list (size_nvars_nexp sz), [[],typ])
    | Typ_app (_, tas) ->
       (KidSet.empty,[[],typ])  (* We only support sizes for bitvectors mentioned explicitly, not any buried
                      inside another type *)
    | Typ_exist (kids, nc, t) ->
       let (vars,tys) = size_nvars_ty t in
       let find_insts k (insts,nc) =
         let inst,nc' =
           if KidSet.mem k vars then
             let is,nc' = extract_set_nc l k nc in
             Some is,nc'
           else None,nc
         in (k,inst)::insts,nc'
       in
       let (insts,nc') = List.fold_right find_insts kids ([],nc) in
       let insts = cross'' insts in
       let ty_and_inst (inst0,ty) inst =
         let kids, ty = apply_kid_insts inst ty in
         let ty =
           (* Typ_exist is not allowed an empty list of kids *)
           match kids with
           | [] -> ty
           | _ -> Typ_aux (Typ_exist (kids, nc', ty),l)
         in inst@inst0, ty
       in
       let tys = List.concat (List.map (fun instty -> List.map (ty_and_inst instty) insts) tys) in
       let free = List.fold_left (fun vars k -> KidSet.remove k vars) vars kids in
       (free,tys)
  in
  (* Only single-variable prenex-form for now *)
  let size_nvars_ty (Typ_aux (ty,l) as typ) =
    match ty with
    | Typ_exist (kids,_,t) ->
       begin
         match snd (size_nvars_ty typ) with
         | [] -> []
         | tys ->
            (* One level of tuple type is stripped off by the type checker, so
               add another here *)
            let tys =
              List.map (fun (x,ty) ->
                x, match ty with
                | Typ_aux (Typ_tup _,_) -> Typ_aux (Typ_tup [ty],Unknown)
                | _ -> ty) tys in
            if contains_exist t then
              raise (Reporting_basic.err_general l
                       "Only prenex types in unions are supported by monomorphisation")
            else if List.length kids > 1 then
              raise (Reporting_basic.err_general l
                       "Only single-variable existential types in unions are currently supported by monomorphisation")
            else tys
       end
    | _ -> []
  in
  (* TODO: reject universally quantification or monomorphise it *)
  let variants = size_nvars_ty ty in
  match variants with
  | [] -> None
  | sample::__ ->
     let () = if List.length variants > size_set_limit then
         raise (Reporting_basic.err_general ql
                  (string_of_int (List.length variants) ^ "variants for constructor " ^ i ^
                     "bigger than limit " ^ string_of_int size_set_limit)) else ()
     in
     let wrap = match id with
       | Id_aux (Id i,l) -> (fun f -> Id_aux (Id (f i),Generated l))
       | Id_aux (DeIid i,l) -> (fun f -> Id_aux (DeIid (f i),l))
     in
     let name_seg = function
       | (_,None) -> ""
       | (k,Some i) -> string_of_kid k ^ Big_int.to_string i
     in
     let name l i = String.concat "_" (i::(List.map name_seg l)) in
     Some (List.map (fun (l,ty) -> (l, wrap (name l),ty)) variants)

let reduce_nexp subst ne =
  let rec eval (Nexp_aux (ne,_) as nexp) =
    match ne with
    | Nexp_constant i -> i
    | Nexp_sum (n1,n2) -> Big_int.add (eval n1) (eval n2)
    | Nexp_minus (n1,n2) -> Big_int.sub (eval n1) (eval n2)
    | Nexp_times (n1,n2) -> Big_int.mul (eval n1) (eval n2)
    | Nexp_exp n -> Big_int.shift_left (eval n) 1
    | Nexp_neg n -> Big_int.negate (eval n)
    | _ ->
       raise (Reporting_basic.err_general Unknown ("Couldn't turn nexp " ^
                                                      string_of_nexp nexp ^ " into concrete value"))
  in eval ne


let typ_of_args args =
  match args with
  | [E_aux (E_tuple args,(_,Some (_,Typ_aux (Typ_exist _,_),_)))] ->
     let tys = List.map Type_check.typ_of args in
     Typ_aux (Typ_tup tys,Unknown)
  | [exp] ->
     Type_check.typ_of exp
  | _ ->
     let tys = List.map Type_check.typ_of args in
     Typ_aux (Typ_tup tys,Unknown)

(* Check to see if we need to monomorphise a use of a constructor.  Currently
   assumes that bitvector sizes are always given as a variable; don't yet handle
   more general cases (e.g., 8 * var) *)

let refine_constructor refinements l env id args =
  match List.find (fun (id',_) -> Id.compare id id' = 0) refinements with
  | (_,irefinements) -> begin
    let (_,constr_ty) = Env.get_val_spec id env in
    match constr_ty with
    | Typ_aux (Typ_fn (constr_ty,_,_),_) -> begin
       let arg_ty = typ_of_args args in
       match Type_check.destruct_exist env constr_ty with
       | None -> None
       | Some (kids,nc,constr_ty) ->
          let (bindings,_,_) = Type_check.unify l env constr_ty arg_ty in
          let find_kid kid = try Some (KBindings.find kid bindings) with Not_found -> None in
          let bindings = List.map find_kid kids in
          let matches_refinement (mapping,_,_) =
            List.for_all2
              (fun v (_,w) ->
                match v,w with
                | _,None -> true
                | Some (U_nexp (Nexp_aux (Nexp_constant n, _))),Some m -> Big_int.equal n m
                | _,_ -> false) bindings mapping
          in
          match List.find matches_refinement irefinements with
          | (_,new_id,_) -> Some (E_app (new_id,args))
          | exception Not_found ->
             (Reporting_basic.print_err false true l "Monomorphisation"
                ("Unable to refine constructor " ^ string_of_id id);
              None)
    end
    | _ -> None
  end
  | exception Not_found -> None


(* Substitute found nexps for variables in an expression, and rename constructors to reflect
   specialisation *)

(* TODO: kid shadowing *)
let nexp_subst_fns substs =

  let s_t t = subst_src_typ substs t in
(*  let s_typschm (TypSchm_aux (TypSchm_ts (q,t),l)) = TypSchm_aux (TypSchm_ts (q,s_t t),l) in
   hopefully don't need this anyway *)(*
  let s_typschm tsh = tsh in*)
  let s_tannot = function
    | None -> None
    | Some (env,t,eff) -> Some (env,s_t t,eff) (* TODO: what about env? *)
  in
  let rec s_pat (P_aux (p,(l,annot))) =
    let re p = P_aux (p,(l,s_tannot annot)) in
    match p with
    | P_lit _ | P_wild | P_id _ -> re p
    | P_var (p',tpat) -> re (P_var (s_pat p',tpat))
    | P_as (p',id) -> re (P_as (s_pat p', id))
    | P_typ (ty,p') -> re (P_typ (s_t ty,s_pat p'))
    | P_app (id,ps) -> re (P_app (id, List.map s_pat ps))
    | P_record (fps,flag) -> re (P_record (List.map s_fpat fps, flag))
    | P_vector ps -> re (P_vector (List.map s_pat ps))
    | P_vector_concat ps -> re (P_vector_concat (List.map s_pat ps))
    | P_tup ps -> re (P_tup (List.map s_pat ps))
    | P_list ps -> re (P_list (List.map s_pat ps))
    | P_cons (p1,p2) -> re (P_cons (s_pat p1, s_pat p2))
  and s_fpat (FP_aux (FP_Fpat (id, p), (l,annot))) =
    FP_aux (FP_Fpat (id, s_pat p), (l,s_tannot annot))
  in
  let rec s_exp (E_aux (e,(l,annot))) =
    let re e = E_aux (e,(l,s_tannot annot)) in
      match e with
      | E_block es -> re (E_block (List.map s_exp es))
      | E_nondet es -> re (E_nondet (List.map s_exp es))
      | E_id _
      | E_lit _
      | E_comment _ -> re e
      | E_sizeof ne -> begin
         let ne' = subst_nexp substs ne in
         match ne' with
         | Nexp_aux (Nexp_constant i,l) -> re (E_lit (L_aux (L_num i,l)))
         | _ -> re (E_sizeof ne')
      end
      | E_constraint nc -> re (E_constraint (subst_nc substs nc))
      | E_internal_exp (l,annot) -> re (E_internal_exp (l, s_tannot annot))
      | E_sizeof_internal (l,annot) -> re (E_sizeof_internal (l, s_tannot annot))
      | E_internal_exp_user ((l1,annot1),(l2,annot2)) ->
         re (E_internal_exp_user ((l1, s_tannot annot1),(l2, s_tannot annot2)))
      | E_cast (t,e') -> re (E_cast (s_t t, s_exp e'))
      | E_app (id,es) -> re (E_app (id, List.map s_exp es))
      | E_app_infix (e1,id,e2) -> re (E_app_infix (s_exp e1,id,s_exp e2))
      | E_tuple es -> re (E_tuple (List.map s_exp es))
      | E_if (e1,e2,e3) -> re (E_if (s_exp e1, s_exp e2, s_exp e3))
      | E_for (id,e1,e2,e3,ord,e4) -> re (E_for (id,s_exp e1,s_exp e2,s_exp e3,ord,s_exp e4))
      | E_loop (loop,e1,e2) -> re (E_loop (loop,s_exp e1,s_exp e2))
      | E_vector es -> re (E_vector (List.map s_exp es))
      | E_vector_access (e1,e2) -> re (E_vector_access (s_exp e1,s_exp e2))
      | E_vector_subrange (e1,e2,e3) -> re (E_vector_subrange (s_exp e1,s_exp e2,s_exp e3))
      | E_vector_update (e1,e2,e3) -> re (E_vector_update (s_exp e1,s_exp e2,s_exp e3))
      | E_vector_update_subrange (e1,e2,e3,e4) -> re (E_vector_update_subrange (s_exp e1,s_exp e2,s_exp e3,s_exp e4))
      | E_vector_append (e1,e2) -> re (E_vector_append (s_exp e1,s_exp e2))
      | E_list es -> re (E_list (List.map s_exp es))
      | E_cons (e1,e2) -> re (E_cons (s_exp e1,s_exp e2))
      | E_record fes -> re (E_record (s_fexps fes))
      | E_record_update (e,fes) -> re (E_record_update (s_exp e, s_fexps fes))
      | E_field (e,id) -> re (E_field (s_exp e,id))
      | E_case (e,cases) -> re (E_case (s_exp e, List.map s_pexp cases))
      | E_let (lb,e) -> re (E_let (s_letbind lb, s_exp e))
      | E_assign (le,e) -> re (E_assign (s_lexp le, s_exp e))
      | E_exit e -> re (E_exit (s_exp e))
      | E_return e -> re (E_return (s_exp e))
      | E_assert (e1,e2) -> re (E_assert (s_exp e1,s_exp e2))
      | E_internal_cast ((l,ann),e) -> re (E_internal_cast ((l,s_tannot ann),s_exp e))
      | E_comment_struc e -> re (E_comment_struc e)
      | E_var (le,e1,e2) -> re (E_var (s_lexp le, s_exp e1, s_exp e2))
      | E_internal_plet (p,e1,e2) -> re (E_internal_plet (s_pat p, s_exp e1, s_exp e2))
      | E_internal_return e -> re (E_internal_return (s_exp e))
      | E_throw e -> re (E_throw (s_exp e))
      | E_try (e,cases) -> re (E_try (s_exp e, List.map s_pexp cases))
    and s_opt_default (Def_val_aux (ed,(l,annot))) =
      match ed with
      | Def_val_empty -> Def_val_aux (Def_val_empty,(l,s_tannot annot))
      | Def_val_dec e -> Def_val_aux (Def_val_dec (s_exp e),(l,s_tannot annot))
    and s_fexps (FES_aux (FES_Fexps (fes,flag), (l,annot))) =
      FES_aux (FES_Fexps (List.map s_fexp fes, flag), (l,s_tannot annot))
    and s_fexp (FE_aux (FE_Fexp (id,e), (l,annot))) =
      FE_aux (FE_Fexp (id,s_exp e),(l,s_tannot annot))
    and s_pexp = function
      | (Pat_aux (Pat_exp (p,e),(l,annot))) ->
         Pat_aux (Pat_exp (s_pat p, s_exp e),(l,s_tannot annot))
      | (Pat_aux (Pat_when (p,e1,e2),(l,annot))) ->
         Pat_aux (Pat_when (s_pat p, s_exp e1, s_exp e2),(l,s_tannot annot))
    and s_letbind (LB_aux (lb,(l,annot))) =
      match lb with
      | LB_val (p,e) -> LB_aux (LB_val (s_pat p,s_exp e), (l,s_tannot annot))
    and s_lexp (LEXP_aux (e,(l,annot))) =
      let re e = LEXP_aux (e,(l,s_tannot annot)) in
      match e with
      | LEXP_id _ -> re e
      | LEXP_cast (typ,id) -> re (LEXP_cast (s_t typ, id))
      | LEXP_memory (id,es) -> re (LEXP_memory (id,List.map s_exp es))
      | LEXP_tup les -> re (LEXP_tup (List.map s_lexp les))
      | LEXP_vector (le,e) -> re (LEXP_vector (s_lexp le, s_exp e))
      | LEXP_vector_range (le,e1,e2) -> re (LEXP_vector_range (s_lexp le, s_exp e1, s_exp e2))
      | LEXP_field (le,id) -> re (LEXP_field (s_lexp le, id))
  in (s_pat,s_exp)
let nexp_subst_pat substs = fst (nexp_subst_fns substs)
let nexp_subst_exp substs = snd (nexp_subst_fns substs)

let bindings_from_pat p =
  let rec aux_pat (P_aux (p,(l,annot))) =
    let env = Type_check.env_of_annot (l, annot) in
    match p with
    | P_lit _
    | P_wild
      -> []
    | P_as (p,id) -> id::(aux_pat p)
    | P_typ (_,p) -> aux_pat p
    | P_id id ->
       if pat_id_is_variable env id then [id] else []
    | P_var (p,kid) -> aux_pat p
    | P_vector ps
    | P_vector_concat ps
    | P_app (_,ps)
    | P_tup ps
    | P_list ps
      -> List.concat (List.map aux_pat ps)
    | P_record (fps,_) -> List.concat (List.map aux_fpat fps)
    | P_cons (p1,p2) -> aux_pat p1 @ aux_pat p2
  and aux_fpat (FP_aux (FP_Fpat (_,p), _)) = aux_pat p
  in aux_pat p

let remove_bound (substs,ksubsts) pat =
  let bound = bindings_from_pat pat in
  List.fold_left (fun sub v -> Bindings.remove v sub) substs bound, ksubsts

(* Attempt simple pattern matches *)
let lit_match = function
  | (L_zero | L_false), (L_zero | L_false) -> true
  | (L_one  | L_true ), (L_one  | L_true ) -> true
  | L_num i1, L_num i2 -> Big_int.equal i1 i2
  | l1,l2 -> l1 = l2

(* There's no undefined nexp, so replace undefined sizes with a plausible size.
   32 is used as a sensible default. *)

let fabricate_nexp_exist env l typ kids nc typ' =
  match kids,nc,Env.expand_synonyms env typ' with
  | ([kid],NC_aux (NC_set (kid',i::_),_),
     Typ_aux (Typ_app (Id_aux (Id "atom",_),
                       [Typ_arg_aux (Typ_arg_nexp (Nexp_aux (Nexp_var kid'',_)),_)]),_))
      when Kid.compare kid kid' = 0 && Kid.compare kid kid'' = 0 ->
     Nexp_aux (Nexp_constant i,Unknown)
  | ([kid],NC_aux (NC_true,_),
     Typ_aux (Typ_app (Id_aux (Id "atom",_),
                       [Typ_arg_aux (Typ_arg_nexp (Nexp_aux (Nexp_var kid'',_)),_)]),_))
      when Kid.compare kid kid'' = 0 ->
     nint 32
  | ([kid],NC_aux (NC_set (kid',i::_),_),
     Typ_aux (Typ_app (Id_aux (Id "range",_),
                       [Typ_arg_aux (Typ_arg_nexp (Nexp_aux (Nexp_var kid'',_)),_);
                        Typ_arg_aux (Typ_arg_nexp (Nexp_aux (Nexp_var kid''',_)),_)]),_))
      when Kid.compare kid kid' = 0 && Kid.compare kid kid'' = 0 &&
        Kid.compare kid kid''' = 0 ->
     Nexp_aux (Nexp_constant i,Unknown)
  | ([kid],NC_aux (NC_true,_),
     Typ_aux (Typ_app (Id_aux (Id "range",_),
                       [Typ_arg_aux (Typ_arg_nexp (Nexp_aux (Nexp_var kid'',_)),_);
                        Typ_arg_aux (Typ_arg_nexp (Nexp_aux (Nexp_var kid''',_)),_)]),_))
      when Kid.compare kid kid'' = 0 &&
        Kid.compare kid kid''' = 0 ->
     nint 32
  | _ -> raise (Reporting_basic.err_general l
                  ("Undefined value at unsupported type " ^ string_of_typ typ))

let fabricate_nexp l = function
  | None -> nint 32
  | Some (env,typ,_) ->
     match Type_check.destruct_exist env typ with
     | None -> nint 32
     | Some (kids,nc,typ') -> fabricate_nexp_exist env l typ kids nc typ'

let atom_typ_kid kid = function
  | Typ_aux (Typ_app (Id_aux (Id "atom",_),
                      [Typ_arg_aux (Typ_arg_nexp (Nexp_aux (Nexp_var kid',_)),_)]),_) ->
     Kid.compare kid kid' = 0
  | _ -> false

(* We reduce casts in a few cases, in particular to ensure that where the
   type checker has added a ({'n, true. atom('n)}) ex_int(...) cast we can
   fill in the 'n.  For undefined we fabricate a suitable value for 'n. *)

let reduce_cast typ exp l annot =
  let env = env_of_annot (l,annot) in
  let replace_typ typ = function
    | Some (env,_,eff) -> Some (env,typ,eff)
    | None -> None
  in
  let typ' = Env.base_typ_of env typ in
  match exp, destruct_exist env typ' with
  | E_aux (E_lit (L_aux (L_num n,_)),_), Some ([kid],nc,typ'') when atom_typ_kid kid typ'' ->
     let nc_env = Env.add_typ_var kid BK_nat env in
     let nc_env = Env.add_constraint (nc_eq (nvar kid) (nconstant n)) nc_env in
     if prove nc_env nc
     then exp
     else raise (Reporting_basic.err_unreachable l
                   ("Constant propagation error: literal " ^ Big_int.to_string n ^
                       " does not satisfy constraint " ^ string_of_n_constraint nc))
  | E_aux (E_lit (L_aux (L_undef,_)),_), Some ([kid],nc,typ'') when atom_typ_kid kid typ'' ->
     let nexp = fabricate_nexp_exist env Unknown typ [kid] nc typ'' in
     let newtyp = subst_src_typ (KBindings.singleton kid nexp) typ'' in
     E_aux (E_cast (newtyp, exp), (Generated l,replace_typ newtyp annot))
  | E_aux (E_cast (_,
                   (E_aux (E_lit (L_aux (L_undef,_)),_) as exp)),_),
     Some ([kid],nc,typ'') when atom_typ_kid kid typ'' ->
     let nexp = fabricate_nexp_exist env Unknown typ [kid] nc typ'' in
     let newtyp = subst_src_typ (KBindings.singleton kid nexp) typ'' in
     E_aux (E_cast (newtyp, exp), (Generated l,replace_typ newtyp annot))
  | _ -> E_aux (E_cast (typ,exp),(l,annot))

(* Used for constant propagation in pattern matches *)
type 'a matchresult =
  | DoesMatch of 'a
  | DoesNotMatch
  | GiveUp

(* Remove top-level casts from an expression.  Useful when we need to look at
   subexpressions to reduce something, but could break type-checking if we used
   it everywhere. *)
let rec drop_casts = function
  | E_aux (E_cast (_,e),_) -> drop_casts e
  | exp -> exp

let int_of_str_lit = function
  | L_hex hex -> Big_int.of_string ("0x" ^ hex)
  | L_bin bin -> Big_int.of_string ("0b" ^ bin)
  | _ -> assert false

let bits_of_lit = function
  | L_bin bin -> bin
  | L_hex hex -> hex_to_bin hex
  | _ -> assert false

let slice_lit (L_aux (lit,ll)) i len (Ord_aux (ord,_)) =
  let i = Big_int.to_int i in
  let len = Big_int.to_int len in
  match match ord with
  | Ord_inc -> Some i
  | Ord_dec -> Some (len - i)
  | Ord_var _ -> None
  with
  | None -> None
  | Some i ->
     match lit with
     | L_bin bin -> Some (L_aux (L_bin (String.sub bin i len),Generated ll))
     | _ -> assert false

let concat_vec lit1 lit2 =
  let bits1 = bits_of_lit lit1 in
  let bits2 = bits_of_lit lit2 in
  L_bin (bits1 ^ bits2)

let lit_eq (L_aux (l1,_)) (L_aux (l2,_)) =
  match l1,l2 with
  | (L_zero|L_false), (L_zero|L_false)
  | (L_one |L_true ), (L_one |L_true)
    -> Some true
  | (L_hex _| L_bin _), (L_hex _|L_bin _)
    -> Some (Big_int.equal (int_of_str_lit l1) (int_of_str_lit l2))
  | L_undef, _ | _, L_undef -> None
  | L_num i1, L_num i2 -> Some (Big_int.equal i1 i2)
  | _ -> Some (l1 = l2)

let try_app (l,ann) (id,args) =
  let new_l = Generated l in
  let env = env_of_annot (l,ann) in
  let get_overloads f = List.map string_of_id
    (Env.get_overloads (Id_aux (Id f, Parse_ast.Unknown)) env @
    Env.get_overloads (Id_aux (DeIid f, Parse_ast.Unknown)) env) in
  let is_id f = List.mem (string_of_id id) (f :: get_overloads f) in
  if is_id "==" || is_id "!=" then
    match args with
    | [E_aux (E_lit l1,_); E_aux (E_lit l2,_)] ->
       let lit b = if b then L_true else L_false in
       let lit b = lit (if is_id "==" then b else not b) in
       (match lit_eq l1 l2 with
       | None -> None
       | Some b -> Some (E_aux (E_lit (L_aux (lit b,new_l)),(l,ann))))
    | _ -> None
  else if is_id "cast_bit_bool" then
    match args with
    | [E_aux (E_lit L_aux (L_zero,_),_)] -> Some (E_aux (E_lit (L_aux (L_false,new_l)),(l,ann)))
    | [E_aux (E_lit L_aux (L_one ,_),_)] -> Some (E_aux (E_lit (L_aux (L_true ,new_l)),(l,ann)))
    | _ -> None
  else if is_id "UInt" then
    match args with
    | [E_aux (E_lit L_aux ((L_hex _| L_bin _) as lit,_), _)] ->
       Some (E_aux (E_lit (L_aux (L_num (int_of_str_lit lit),new_l)),(l,ann)))
    | _ -> None
  else if is_id "slice" then
    match args with
    | [E_aux (E_lit (L_aux ((L_hex _| L_bin _),_) as lit),
              (_,Some (_,Typ_aux (Typ_app (_,[_;Typ_arg_aux (Typ_arg_order ord,_);_]),_),_)));
       E_aux (E_lit L_aux (L_num i,_), _);
       E_aux (E_lit L_aux (L_num len,_), _)] ->
       (match slice_lit lit i len ord with
       | Some lit' -> Some (E_aux (E_lit lit',(l,ann)))
       | None -> None)
    | _ -> None
  else if is_id "bitvector_concat" then
    match args with
    | [E_aux (E_lit L_aux ((L_hex _| L_bin _) as lit1,_), _);
       E_aux (E_lit L_aux ((L_hex _| L_bin _) as lit2,_), _)] ->
       Some (E_aux (E_lit (L_aux (concat_vec lit1 lit2,new_l)),(l,ann)))
    | _ -> None
  else if is_id "shl_int" then
    match args with
    | [E_aux (E_lit L_aux (L_num i,_),_); E_aux (E_lit L_aux (L_num j,_),_)] ->
       Some (E_aux (E_lit (L_aux (L_num (Big_int.shift_left i (Big_int.to_int j)),new_l)),(l,ann)))
    | _ -> None
  else if is_id "mult_int" || is_id "mult_range" then
    match args with
    | [E_aux (E_lit L_aux (L_num i,_),_); E_aux (E_lit L_aux (L_num j,_),_)] ->
       Some (E_aux (E_lit (L_aux (L_num (Big_int.mul i j),new_l)),(l,ann)))
    | _ -> None
  else if is_id "quotient_nat" then
    match args with
    | [E_aux (E_lit L_aux (L_num i,_),_); E_aux (E_lit L_aux (L_num j,_),_)] ->
       Some (E_aux (E_lit (L_aux (L_num (Big_int.div i j),new_l)),(l,ann)))
    | _ -> None
  else if is_id "add_range" then
    match args with
    | [E_aux (E_lit L_aux (L_num i,_),_); E_aux (E_lit L_aux (L_num j,_),_)] ->
       Some (E_aux (E_lit (L_aux (L_num (Big_int.add i j),new_l)),(l,ann)))
    | _ -> None
  else if is_id "negate_range" then
    match args with
    | [E_aux (E_lit L_aux (L_num i,_),_)] ->
       Some (E_aux (E_lit (L_aux (L_num (Big_int.negate i),new_l)),(l,ann)))
    | _ -> None
  else if is_id "ex_int" then
    match args with
    | [E_aux (E_lit lit,(l,_))] -> Some (E_aux (E_lit lit,(l,ann)))
    | [E_aux (E_cast (_,(E_aux (E_lit (L_aux (L_undef,_)),_) as e)),(l,_))] ->
       Some (reduce_cast (typ_of_annot (l,ann)) e l ann)
    | _ -> None
  else if is_id "vector_access" || is_id "bitvector_access" then
    match args with
    | [E_aux (E_lit L_aux ((L_hex _ | L_bin _) as lit,_),_);
       E_aux (E_lit L_aux (L_num i,_),_)] ->
       let v = int_of_str_lit lit in
       let b = Big_int.bitwise_and (Big_int.shift_right v (Big_int.to_int i)) (Big_int.of_int 1) in
       let lit' = if Big_int.equal b (Big_int.of_int 1) then L_one else L_zero in
       Some (E_aux (E_lit (L_aux (lit',new_l)),(l,ann)))
    | _ -> None
  else None


let construct_lit_vector args =
  let rec aux l = function
    | [] -> Some (L_aux (L_bin (String.concat "" (List.rev l)),Unknown))
    | E_aux (E_lit (L_aux ((L_zero | L_one) as lit,_)),_)::t ->
       aux ((if lit = L_zero then "0" else "1")::l) t
    | _ -> None
  in aux [] args

type pat_choice = Parse_ast.l * (int * int * (id * tannot exp) list)

(* We may need to split up a pattern match if (1) we've been told to case split
   on a variable by the user or analysis, or (2) we monomorphised a constructor that's used
   in the pattern. *)
type split =
  | NoSplit
  | VarSplit of (tannot pat *        (* pattern for this case *)
      (id * tannot Ast.exp) list *   (* substitutions for arguments *)
      pat_choice list * (* optional locations of constraints/case expressions to reduce *)
      (kid * nexp) list)             (* substitutions for type variables *)
      list
  | ConstrSplit of (tannot pat * nexp KBindings.t) list

let threaded_map f state l =
  let l',state' =
    List.fold_left (fun (tl,state) element -> let (el',state') = f state element in (el'::tl,state'))
      ([],state) l
  in List.rev l',state'

let isubst_minus subst subst' =
  Bindings.merge (fun _ x y -> match x,y with (Some a), None -> Some a | _, _ -> None) subst subst'

let isubst_minus_set subst set =
  IdSet.fold Bindings.remove set subst

let assigned_vars exp =
  fst (Rewriter.fold_exp
         { (Rewriter.compute_exp_alg IdSet.empty IdSet.union) with
           Rewriter.lEXP_id = (fun id -> IdSet.singleton id, LEXP_id id);
           Rewriter.lEXP_cast = (fun (ty,id) -> IdSet.singleton id, LEXP_cast (ty,id)) }
         exp)

let assigned_vars_in_fexps (FES_aux (FES_Fexps (fes,_), _)) =
  List.fold_left
    (fun vs (FE_aux (FE_Fexp (_,e),_)) -> IdSet.union vs (assigned_vars e))
    IdSet.empty
    fes

let assigned_vars_in_pexp (Pat_aux (p,_)) =
  match p with
  | Pat_exp (_,e) -> assigned_vars e
  | Pat_when (p,e1,e2) -> IdSet.union (assigned_vars e1) (assigned_vars e2)

let rec assigned_vars_in_lexp (LEXP_aux (le,_)) =
  match le with
  | LEXP_id id
  | LEXP_cast (_,id) -> IdSet.singleton id
  | LEXP_tup lexps -> List.fold_left (fun vs le -> IdSet.union vs (assigned_vars_in_lexp le)) IdSet.empty lexps
  | LEXP_memory (_,es) -> List.fold_left (fun vs e -> IdSet.union vs (assigned_vars e)) IdSet.empty es
  | LEXP_vector (le,e) -> IdSet.union (assigned_vars_in_lexp le) (assigned_vars e)
  | LEXP_vector_range (le,e1,e2) ->
     IdSet.union (assigned_vars_in_lexp le) (IdSet.union (assigned_vars e1) (assigned_vars e2))
  | LEXP_field (le,_) -> assigned_vars_in_lexp le

(* Add a cast to undefined so that it retains its type, otherwise it can't be
   substituted safely *)
let keep_undef_typ value =
  match value with
  | E_aux (E_lit (L_aux (L_undef,lann)),eann) ->
     E_aux (E_cast (typ_of_annot eann,value),(Generated Unknown,snd eann))
  | _ -> value

let rec flatten_constraints = function
  | [] -> []
  | (NC_aux (NC_and (nc1,nc2),_))::t -> flatten_constraints (nc1::nc2::t)
  | h::t -> h::(flatten_constraints t)

(* NB: this only looks for direct equalities with the given kid.  It would be
   better in principle to find the entire set of equal kids, but it isn't
   necessary to deal with the fresh kids produced by the type checker while
   checking P_var patterns, so we don't do it for now. *)
let equal_kids env kid =
  let is_eq = function
    | NC_aux (NC_equal (Nexp_aux (Nexp_var var1,_), Nexp_aux (Nexp_var var2,_)),_) ->
       if Kid.compare kid var1 == 0 then Some var2 else
         if Kid.compare kid var2 == 0 then Some var1 else
           None
    | _ -> None
  in
  let ncs = flatten_constraints (Env.get_constraints env) in
  let kids = Util.map_filter is_eq ncs in
  List.fold_left (fun s k -> KidSet.add k s) (KidSet.singleton kid) kids

let freshen_id =
  let counter = ref 0 in
  fun id ->
    let n = !counter in
    let () = counter := n + 1 in
    match id with
    | Id_aux (Id x, l) -> Id_aux (Id (x ^ "#m" ^ string_of_int n),Generated l)
    | Id_aux (DeIid x, l) -> Id_aux (DeIid (x ^ "#m" ^ string_of_int n),Generated l)

(* TODO: only freshen bindings that might be shadowed *)
let rec freshen_pat_bindings p =
  let rec aux (P_aux (p,(l,annot)) as pat) =
    let mkp p = P_aux (p,(Generated l, annot)) in
    match p with
    | P_lit _
    | P_wild -> pat, []
    | P_as (p,_) -> aux p
    | P_typ (typ,p) -> let p',vs = aux p in mkp (P_typ (typ,p')),vs
    | P_id id -> let id' = freshen_id id in mkp (P_id id'),[id,E_aux (E_id id',(Generated Unknown,None))]
    | P_var (p,_) -> aux p
    | P_app (id,args) ->
       let args',vs = List.split (List.map aux args) in
       mkp (P_app (id,args')),List.concat vs
    | P_record (fpats,flag) ->
       let fpats,vs = List.split (List.map auxr fpats) in
       mkp (P_record (fpats,flag)),List.concat vs
    | P_vector ps ->
       let ps,vs = List.split (List.map aux ps) in
       mkp (P_vector ps),List.concat vs
    | P_vector_concat ps ->
       let ps,vs = List.split (List.map aux ps) in
       mkp (P_vector_concat ps),List.concat vs
    | P_tup ps ->
       let ps,vs = List.split (List.map aux ps) in
       mkp (P_tup ps),List.concat vs
    | P_list ps ->
       let ps,vs = List.split (List.map aux ps) in
       mkp (P_list ps),List.concat vs
    | P_cons (p1,p2) ->
       let p1,vs1 = aux p1 in
       let p2,vs2 = aux p2 in
       mkp (P_cons (p1, p2)), vs1@vs2
  and auxr (FP_aux (FP_Fpat (id,p),(l,annot))) =
    let p,vs = aux p in
    FP_aux (FP_Fpat (id, p),(Generated l,annot)), vs
  in aux p

(* This cuts off function bodies at false assertions that we may have produced
   in a wildcard pattern match.  It should handle the same assertions that
   find_set_assertions does. *)
let stop_at_false_assertions e =
  let dummy_value_of_typ typ =
    let l = Generated Unknown in
    E_aux (E_exit (E_aux (E_lit (L_aux (L_unit,l)),(l,None))),(l,None))
  in
  let rec nc_false (NC_aux (nc,_)) =
    match nc with
    | NC_false -> true
    | NC_and (nc1,nc2) -> nc_false nc1 || nc_false nc2
    | _ -> false
  in
  let rec exp_false (E_aux (e,_)) =
    match e with
    | E_constraint nc -> nc_false nc
    | E_lit (L_aux (L_false,_)) -> true
    | E_app (Id_aux (Id "and_bool",_),[e1;e2]) ->
       exp_false e1 || exp_false e2
    | _ -> false
  in
  let rec exp (E_aux (e,ann) as ea) =
    match e with
    | E_block es ->
       let rec aux = function
         | [] -> [], None
         | e::es -> let e,stop = exp e in
                    match stop with
                    | Some _ -> [e],stop
                    | None ->
                       let es',stop = aux es in
                       e::es',stop
       in let es,stop = aux es in begin
          match stop with
          | None -> E_aux (E_block es,ann), stop
          | Some typ ->
             let typ' = typ_of_annot ann in
             if Type_check.alpha_equivalent (env_of_annot ann) typ typ'
             then E_aux (E_block es,ann), stop
             else E_aux (E_block (es@[dummy_value_of_typ typ']),ann), Some typ'
       end
    | E_nondet es ->
       let es,stops = List.split (List.map exp es) in
       let stop = List.exists (function Some _ -> true | _ -> false) stops in
       let stop = if stop then Some (typ_of_annot ann) else None in
       E_aux (E_nondet es,ann), stop
    | E_cast (typ,e) -> let e,stop = exp e in
                        let stop = match stop with Some _ -> Some typ | None -> None in
                        E_aux (E_cast (typ,e),ann),stop
    | E_let (LB_aux (LB_val (p,e1),lbann),e2) ->
       let e1,stop = exp e1 in begin
       match stop with
       | Some _ -> e1,stop
       | None -> 
          let e2,stop = exp e2 in
          E_aux (E_let (LB_aux (LB_val (p,e1),lbann),e2),ann), stop
       end
    | E_assert (e1,_) when exp_false e1 ->
       ea, Some (typ_of_annot ann)
    | _ -> ea, None
  in fst (exp e)

(* Use the location pairs in choices to reduce case expressions at the first
   location to the given case at the second. *)
let apply_pat_choices choices =
  let rec rewrite_ncs (NC_aux (nc,l) as nconstr) =
    match nc with
    | NC_set (kid,is) -> begin
      match List.assoc l choices with
      | choice,max,_ ->
         NC_aux ((if choice < max then NC_true else NC_false), Generated l)
      | exception Not_found -> nconstr
      end
    | NC_and (nc1,nc2) -> begin
      match rewrite_ncs nc1, rewrite_ncs nc2 with
      | NC_aux (NC_false,l), _
      | _, NC_aux (NC_false,l) -> NC_aux (NC_false,l)
      | nc1,nc2 -> NC_aux (NC_and (nc1,nc2),l)
      end
    | _ -> nconstr
  in
  let rec rewrite_assert_cond (E_aux (e,(l,ann)) as exp) =
    match List.assoc l choices with
    | choice,max,_ ->
       E_aux (E_lit (L_aux ((if choice < max then L_true else L_false (* wildcard *)),
         Generated l)),(Generated l,ann))
    | exception Not_found ->
       match e with
       | E_constraint nc -> E_aux (E_constraint (rewrite_ncs nc),(l,ann))
       | E_app (Id_aux (Id "and_bool",andl), [e1;e2]) ->
          E_aux (E_app (Id_aux (Id "and_bool",andl),
                        [rewrite_assert_cond e1;
                         rewrite_assert_cond e2]),(l,ann))
       | _ -> exp
  in
  let rewrite_assert (e1,e2) =
    E_assert (rewrite_assert_cond e1, e2)
  in
  let rewrite_case (e,cases) =
    match List.assoc (exp_loc e) choices with
    | choice,max,subst ->
       (match List.nth cases choice with
       | Pat_aux (Pat_exp (p,E_aux (e,_)),_) ->
          let dummyannot = (Generated Unknown,None) in
          (* TODO: use a proper substitution *)
          List.fold_left (fun e (id,e') ->
            E_let (LB_aux (LB_val (P_aux (P_id id, dummyannot),e'),dummyannot),E_aux (e,dummyannot))) e subst
       | Pat_aux (Pat_when _,(l,_)) ->
          raise (Reporting_basic.err_unreachable l
                   "Pattern acquired a guard after analysis!")
       | exception Not_found ->
          raise (Reporting_basic.err_unreachable (exp_loc e)
                   "Unable to find case I found earlier!"))
    | exception Not_found -> E_case (e,cases)
  in
  let open Rewriter in
  fold_exp { id_exp_alg with
    e_assert = rewrite_assert;
    e_case = rewrite_case }

(* Check whether the current environment with the given kid assignments is
   inconsistent (and hence whether the code is dead) *)
let is_env_inconsistent env ksubsts =
  let env = KBindings.fold (fun k nexp env ->
    Env.add_constraint (nc_eq (nvar k) nexp) env) ksubsts env in
  prove env nc_false

let split_defs all_errors splits defs =
  let no_errors_happened = ref true in
  let split_constructors (Defs defs) =
    let sc_type_union q (Tu_aux (tu,l) as tua) =
      match tu with
      | Tu_id id -> [],[tua]
      | Tu_ty_id (ty,id) ->
         (match split_src_type id ty q with
         | None -> ([],[Tu_aux (Tu_ty_id (ty,id),l)])
         | Some variants ->
            ([(id,variants)],
             List.map (fun (insts, id', ty) -> Tu_aux (Tu_ty_id (ty,id'),Generated l)) variants))
    in
    let sc_type_def ((TD_aux (tda,annot)) as td) =
      match tda with
      | TD_variant (id,nscm,quant,tus,flag) ->
         let (refinements, tus') = List.split (List.map (sc_type_union quant) tus) in
         (List.concat refinements, TD_aux (TD_variant (id,nscm,quant,List.concat tus',flag),annot))
      | _ -> ([],td)
    in
    let sc_def d =
      match d with
    | DEF_type td -> let (refinements,td') = sc_type_def td in (refinements, DEF_type td')
    | _ -> ([], d)
    in
    let (refinements, defs') = List.split (List.map sc_def defs)
    in (List.concat refinements, Defs defs')
  in

  let (refinements, defs') = split_constructors defs in

  (* COULD DO: dead code is only eliminated at if expressions, but we could
     also cut out impossible case branches and code after assertions. *)

  (* Constant propogation.
     Takes maps of immutable/mutable variables to subsitute.
     The substs argument also contains the current type-level kid refinements
     so that we can check for dead code.
     Extremely conservative about evaluation order of assignments in
     subexpressions, dropping assignments rather than committing to
     any particular order *)
  let rec const_prop_exp substs assigns ((E_aux (e,(l,annot))) as exp) =
    (* Functions to treat lists and tuples of subexpressions as possibly
       non-deterministic: that is, we stop making any assumptions about
       variables that are assigned to in any of the subexpressions *)
    let non_det_exp_list es =
      let assigned_in =
        List.fold_left (fun vs exp -> IdSet.union vs (assigned_vars exp))
          IdSet.empty es in
      let assigns = isubst_minus_set assigns assigned_in in
      let es' = List.map (fun e -> fst (const_prop_exp substs assigns e)) es in
      es',assigns
    in
    let non_det_exp_2 e1 e2 =
       let assigned_in_e12 = IdSet.union (assigned_vars e1) (assigned_vars e2) in
       let assigns = isubst_minus_set assigns assigned_in_e12 in
       let e1',_ = const_prop_exp substs assigns e1 in
       let e2',_ = const_prop_exp substs assigns e2 in
       e1',e2',assigns
    in
    let non_det_exp_3 e1 e2 e3 =
       let assigned_in_e12 = IdSet.union (assigned_vars e1) (assigned_vars e2) in
       let assigned_in_e123 = IdSet.union assigned_in_e12 (assigned_vars e3) in
       let assigns = isubst_minus_set assigns assigned_in_e123 in
       let e1',_ = const_prop_exp substs assigns e1 in
       let e2',_ = const_prop_exp substs assigns e2 in
       let e3',_ = const_prop_exp substs assigns e3 in
       e1',e2',e3',assigns
    in
    let non_det_exp_4 e1 e2 e3 e4 =
       let assigned_in_e12 = IdSet.union (assigned_vars e1) (assigned_vars e2) in
       let assigned_in_e123 = IdSet.union assigned_in_e12 (assigned_vars e3) in
       let assigned_in_e1234 = IdSet.union assigned_in_e123 (assigned_vars e4) in
       let assigns = isubst_minus_set assigns assigned_in_e1234 in
       let e1',_ = const_prop_exp substs assigns e1 in
       let e2',_ = const_prop_exp substs assigns e2 in
       let e3',_ = const_prop_exp substs assigns e3 in
       let e4',_ = const_prop_exp substs assigns e4 in
       e1',e2',e3',e4',assigns
    in
    let re e assigns = E_aux (e,(l,annot)),assigns in
    match e with
      (* TODO: are there more circumstances in which we should get rid of these? *)
    | E_block [e] -> const_prop_exp substs assigns e
    | E_block es ->
       let es',assigns = threaded_map (const_prop_exp substs) assigns es in
       re (E_block es') assigns
    | E_nondet es ->
       let es',assigns = non_det_exp_list es in
       re (E_nondet es') assigns
    | E_id id ->
       let env = Type_check.env_of_annot (l, annot) in
       (try
         match Env.lookup_id id env with
         | Local (Immutable,_) -> Bindings.find id (fst substs)
         | Local (Mutable,_)   -> Bindings.find id assigns
         | _ -> exp
       with Not_found -> exp),assigns
    | E_lit _
    | E_sizeof _
    | E_internal_exp _
    | E_sizeof_internal _
    | E_internal_exp_user _
    | E_comment _
    | E_constraint _
      -> exp,assigns
    | E_cast (t,e') ->
       let e'',assigns = const_prop_exp substs assigns e' in
       if is_value e''
       then reduce_cast t e'' l annot, assigns
       else re (E_cast (t, e'')) assigns
    | E_app (id,es) ->
       let es',assigns = non_det_exp_list es in
       let env = Type_check.env_of_annot (l, annot) in
       (match try_app (l,annot) (id,es') with
       | None ->
          (match const_prop_try_fn l env (id,es') with
          | None -> re (E_app (id,es')) assigns
          | Some r -> r,assigns)
       | Some r -> r,assigns)
    | E_tuple es ->
       let es',assigns = non_det_exp_list es in
       re (E_tuple es') assigns
    | E_if (e1,e2,e3) ->
       let e1',assigns = const_prop_exp substs assigns e1 in
       let e1_no_casts = drop_casts e1' in
       (match e1_no_casts with
       | E_aux (E_lit (L_aux ((L_true|L_false) as lit ,_)),_) ->
          (match lit with
          | L_true -> const_prop_exp substs assigns e2
          |  _     -> const_prop_exp substs assigns e3)
       | _ ->
          (* If the guard is an equality check, propagate the value. *)
          let env1 = env_of e1_no_casts in
          let is_equal id =
            List.exists (fun id' -> Id.compare id id' == 0)
              (Env.get_overloads (Id_aux (DeIid "==", Parse_ast.Unknown))
                 env1)
          in
          let substs_true =
            match e1_no_casts with
            | E_aux (E_app (id, [E_aux (E_id var,_); vl]),_)
            | E_aux (E_app (id, [vl; E_aux (E_id var,_)]),_)
                when is_equal id ->
               if is_value vl then
                 (match Env.lookup_id var env1 with
                 | Local (Immutable,_) -> Bindings.add var vl (fst substs),snd substs
                 | _ -> substs)
               else substs
            | _ -> substs
          in
          (* Discard impossible branches *)
          if is_env_inconsistent (env_of e2) (snd substs) then
            const_prop_exp substs assigns e3
          else if is_env_inconsistent (env_of e3) (snd substs) then
            const_prop_exp substs_true assigns e2
          else
            let e2',assigns2 = const_prop_exp substs_true assigns e2 in
            let e3',assigns3 = const_prop_exp substs assigns e3 in
            let assigns = isubst_minus_set assigns (assigned_vars e2) in
            let assigns = isubst_minus_set assigns (assigned_vars e3) in
            re (E_if (e1',e2',e3')) assigns)
    | E_for (id,e1,e2,e3,ord,e4) ->
       (* Treat e1, e2 and e3 (from, to and by) as a non-det tuple *)
       let e1',e2',e3',assigns = non_det_exp_3 e1 e2 e3 in
       let assigns = isubst_minus_set assigns (assigned_vars e4) in
       let e4',_ = const_prop_exp (Bindings.remove id (fst substs),snd substs) assigns e4 in
       re (E_for (id,e1',e2',e3',ord,e4')) assigns
    | E_loop (loop,e1,e2) ->
       let assigns = isubst_minus_set assigns (IdSet.union (assigned_vars e1) (assigned_vars e2)) in
       let e1',_ = const_prop_exp substs assigns e1 in
       let e2',_ = const_prop_exp substs assigns e2 in
       re (E_loop (loop,e1',e2')) assigns
    | E_vector es ->
       let es',assigns = non_det_exp_list es in
       begin
         match construct_lit_vector es' with
         | None -> re (E_vector es') assigns
         | Some lit -> re (E_lit lit) assigns
       end
    | E_vector_access (e1,e2) ->
       let e1',e2',assigns = non_det_exp_2 e1 e2 in
       re (E_vector_access (e1',e2')) assigns
    | E_vector_subrange (e1,e2,e3) ->
       let e1',e2',e3',assigns = non_det_exp_3 e1 e2 e3 in
       re (E_vector_subrange (e1',e2',e3')) assigns
    | E_vector_update (e1,e2,e3) ->
       let e1',e2',e3',assigns = non_det_exp_3 e1 e2 e3 in
       re (E_vector_update (e1',e2',e3')) assigns
    | E_vector_update_subrange (e1,e2,e3,e4) ->
       let e1',e2',e3',e4',assigns = non_det_exp_4 e1 e2 e3 e4 in
       re (E_vector_update_subrange (e1',e2',e3',e4')) assigns
    | E_vector_append (e1,e2) ->
       let e1',e2',assigns = non_det_exp_2 e1 e2 in
       re (E_vector_append (e1',e2')) assigns
    | E_list es ->
       let es',assigns = non_det_exp_list es in
       re (E_list es') assigns
    | E_cons (e1,e2) ->
       let e1',e2',assigns = non_det_exp_2 e1 e2 in
       re (E_cons (e1',e2')) assigns
    | E_record fes ->
       let assigned_in_fes = assigned_vars_in_fexps fes in
       let assigns = isubst_minus_set assigns assigned_in_fes in
       re (E_record (const_prop_fexps substs assigns fes)) assigns
    | E_record_update (e,fes) ->
       let assigned_in = IdSet.union (assigned_vars_in_fexps fes) (assigned_vars e) in
       let assigns = isubst_minus_set assigns assigned_in in
       let e',_ = const_prop_exp substs assigns e in
       re (E_record_update (e', const_prop_fexps substs assigns fes)) assigns
    | E_field (e,id) ->
       let e',assigns = const_prop_exp substs assigns e in
       re (E_field (e',id)) assigns
    | E_case (e,cases) ->
       let e',assigns = const_prop_exp substs assigns e in
       (match can_match e' cases substs assigns with
       | None ->
          let assigned_in =
            List.fold_left (fun vs pe -> IdSet.union vs (assigned_vars_in_pexp pe))
              IdSet.empty cases
          in
          let assigns' = isubst_minus_set assigns assigned_in in
          re (E_case (e', List.map (const_prop_pexp substs assigns) cases)) assigns'
       | Some (E_aux (_,(_,annot')) as exp,newbindings,kbindings) ->
          let exp = nexp_subst_exp (kbindings_from_list kbindings) exp in
          let newbindings_env = bindings_from_list newbindings in
          let substs' = bindings_union (fst substs) newbindings_env, snd substs in
          const_prop_exp substs' assigns exp)
    | E_let (lb,e2) ->
       begin
         match lb with
         | LB_aux (LB_val (p,e), annot) ->
            let e',assigns = const_prop_exp substs assigns e in
            let substs' = remove_bound substs p in
            let plain () =
              let e2',assigns = const_prop_exp substs' assigns e2 in
              re (E_let (LB_aux (LB_val (p,e'), annot),
                         e2')) assigns in
            if is_value e' && not (is_value e) then
              match can_match e' [Pat_aux (Pat_exp (p,e2),(Unknown,None))] substs assigns with
              | None -> plain ()
              | Some (e'',bindings,kbindings) ->
                 let e'' = nexp_subst_exp (kbindings_from_list kbindings) e'' in
                 let bindings = bindings_from_list bindings in
                 let substs'' = bindings_union (fst substs') bindings, snd substs' in
                 const_prop_exp substs'' assigns e''
            else plain ()
       end
    (* TODO maybe - tuple assignments *)
    | E_assign (le,e) ->
       let env = Type_check.env_of_annot (l, annot) in
       let assigned_in = IdSet.union (assigned_vars_in_lexp le) (assigned_vars e) in
       let assigns = isubst_minus_set assigns assigned_in in
       let le',idopt = const_prop_lexp substs assigns le in
       let e',_ = const_prop_exp substs assigns e in
       let assigns =
         match idopt with
         | Some id ->
            begin
              match Env.lookup_id id env with
              | Local (Mutable,_) | Unbound ->
                 if is_value e'
                 then Bindings.add id (keep_undef_typ e') assigns
                 else Bindings.remove id assigns
              | _ -> assigns
            end
         | None -> assigns
       in
       re (E_assign (le', e')) assigns
    | E_exit e ->
       let e',_ = const_prop_exp substs assigns e in
       re (E_exit e') Bindings.empty
    | E_throw e ->
       let e',_ = const_prop_exp substs assigns e in
       re (E_throw e') Bindings.empty
    | E_try (e,cases) ->
       (* TODO: try and preserve *any* assignment info *)
       let e',_ = const_prop_exp substs assigns e in
       re (E_case (e', List.map (const_prop_pexp substs Bindings.empty) cases)) Bindings.empty
    | E_return e ->
       let e',_ = const_prop_exp substs assigns e in
       re (E_return e') Bindings.empty
    | E_assert (e1,e2) ->
       let e1',e2',assigns = non_det_exp_2 e1 e2 in
       re (E_assert (e1',e2')) assigns
    | E_internal_cast (ann,e) ->
       let e',assigns = const_prop_exp substs assigns e in
       re (E_internal_cast (ann,e')) assigns
    (* TODO: should I substitute or anything here?  Is it even used? *)
    | E_comment_struc e -> re (E_comment_struc e) assigns

    | E_app_infix _
    | E_var _
    | E_internal_plet _
    | E_internal_return _
      -> raise (Reporting_basic.err_unreachable l
                  ("Unexpected expression encountered in monomorphisation: " ^ string_of_exp exp))
  and const_prop_fexps substs assigns (FES_aux (FES_Fexps (fes,flag), annot)) =
    FES_aux (FES_Fexps (List.map (const_prop_fexp substs assigns) fes, flag), annot)
  and const_prop_fexp substs assigns (FE_aux (FE_Fexp (id,e), annot)) =
    FE_aux (FE_Fexp (id,fst (const_prop_exp substs assigns e)),annot)
  and const_prop_pexp substs assigns = function
    | (Pat_aux (Pat_exp (p,e),l)) ->
       Pat_aux (Pat_exp (p,fst (const_prop_exp (remove_bound substs p) assigns e)),l)
    | (Pat_aux (Pat_when (p,e1,e2),l)) ->
       let substs' = remove_bound substs p in
       let e1',assigns = const_prop_exp substs' assigns e1 in
       Pat_aux (Pat_when (p, e1', fst (const_prop_exp substs' assigns e2)),l)
  and const_prop_lexp substs assigns ((LEXP_aux (e,annot)) as le) =
    let re e = LEXP_aux (e,annot), None in
    match e with
    | LEXP_id id (* shouldn't end up substituting here *)
    | LEXP_cast (_,id)
      -> le, Some id
    | LEXP_memory (id,es) ->
       re (LEXP_memory (id,List.map (fun e -> fst (const_prop_exp substs assigns e)) es)) (* or here *)
    | LEXP_tup les -> re (LEXP_tup (List.map (fun le -> fst (const_prop_lexp substs assigns le)) les))
    | LEXP_vector (le,e) -> re (LEXP_vector (fst (const_prop_lexp substs assigns le), fst (const_prop_exp substs assigns e)))
    | LEXP_vector_range (le,e1,e2) ->
       re (LEXP_vector_range (fst (const_prop_lexp substs assigns le),
                              fst (const_prop_exp substs assigns e1),
                              fst (const_prop_exp substs assigns e2)))
    | LEXP_field (le,id) -> re (LEXP_field (fst (const_prop_lexp substs assigns le), id))
  (* Reduce a function when
     1. all arguments are values,
     2. the function is pure,
     3. the result is a value
     (and 4. the function is not scattered, but that's not terribly important)
     to try and keep execution time and the results managable.
  *)
  and const_prop_try_fn l env (id,args) =
    if not (List.for_all is_value args) then
      None
    else
      let Defs ds = defs in
      match list_extract (function
      | (DEF_fundef (FD_aux (FD_function (_,_,eff,((FCL_aux (FCL_Funcl (id',_),_))::_ as fcls)),_)))
        -> if Id.compare id id' = 0 then Some (eff,fcls) else None
      | _ -> None) ds with
      | None -> None
      | Some (eff,_) when not (is_pure eff) -> None
      | Some (_,fcls) ->
         let arg = match args with
           | [] -> E_aux (E_lit (L_aux (L_unit,Generated l)),(Generated l,None))
           | [e] -> e
           | _ -> E_aux (E_tuple args,(Generated l,None)) in
         let cases = List.map (function
           | FCL_aux (FCL_Funcl (_,pexp), ann) -> pexp)
           fcls in
         match can_match_with_env env arg cases (Bindings.empty,KBindings.empty) Bindings.empty with
         | Some (exp,bindings,kbindings) ->
            let substs = bindings_from_list bindings, kbindings_from_list kbindings in
            let result,_ = const_prop_exp substs Bindings.empty exp in
            let result = match result with
              | E_aux (E_return e,_) -> e
              | _ -> result
            in
            if is_value result then Some result else None
         | None -> None

  and can_match_with_env env (E_aux (e,(l,annot)) as exp0) cases (substs,ksubsts) assigns =
    let rec findpat_generic check_pat description assigns = function
      | [] -> (Reporting_basic.print_err false true l "Monomorphisation"
                 ("Failed to find a case for " ^ description); None)
      | [Pat_aux (Pat_exp (P_aux (P_wild,_),exp),_)] -> Some (exp,[],[])
      | (Pat_aux (Pat_exp (P_aux (P_typ (_,p),_),exp),ann))::tl ->
         findpat_generic check_pat description assigns ((Pat_aux (Pat_exp (p,exp),ann))::tl)
      | (Pat_aux (Pat_exp (P_aux (P_id id',_),exp),_))::tlx
          when pat_id_is_variable env id' ->
         Some (exp, [(id', exp0)], [])
      | (Pat_aux (Pat_when (P_aux (P_id id',_),guard,exp),_))::tl
          when pat_id_is_variable env id' -> begin
            let substs = Bindings.add id' exp0 substs, ksubsts in
            let (E_aux (guard,_)),assigns = const_prop_exp substs assigns guard in
            match guard with
            | E_lit (L_aux (L_true,_)) -> Some (exp,[(id',exp0)],[])
            | E_lit (L_aux (L_false,_)) -> findpat_generic check_pat description assigns tl
            | _ -> None
          end
      | (Pat_aux (Pat_when (p,guard,exp),_))::tl -> begin
        match check_pat p with
        | DoesNotMatch -> findpat_generic check_pat description assigns tl
        | DoesMatch (vsubst,ksubst) -> begin
          let guard = nexp_subst_exp (kbindings_from_list ksubst) guard in
          let substs = bindings_union substs (bindings_from_list vsubst),
                       kbindings_union ksubsts (kbindings_from_list ksubst) in
          let (E_aux (guard,_)),assigns = const_prop_exp substs assigns guard in
          match guard with
          | E_lit (L_aux (L_true,_)) -> Some (exp,vsubst,ksubst)
          | E_lit (L_aux (L_false,_)) -> findpat_generic check_pat description assigns tl
          | _ -> None
        end
        | GiveUp -> None
      end
      | (Pat_aux (Pat_exp (p,exp),_))::tl ->
         match check_pat p with
         | DoesNotMatch -> findpat_generic check_pat description assigns tl
         | DoesMatch (subst,ksubst) -> Some (exp,subst,ksubst)
         | GiveUp -> None
    in
    match e with
    | E_id id ->
       (match Env.lookup_id id env with
       | Enum _ ->
          let checkpat = function
            | P_aux (P_id id',_)
            | P_aux (P_app (id',[]),_) ->
               if Id.compare id id' = 0 then DoesMatch ([],[]) else DoesNotMatch
            | P_aux (_,(l',_)) ->
               (Reporting_basic.print_err false true l' "Monomorphisation"
                  "Unexpected kind of pattern for enumeration"; GiveUp)
          in findpat_generic checkpat (string_of_id id) assigns cases
       | _ -> None)
    | E_lit (L_aux (lit_e, lit_l)) ->
       let checkpat = function
         | P_aux (P_lit (L_aux (lit_p, _)),_) ->
            if lit_match (lit_e,lit_p) then DoesMatch ([],[]) else DoesNotMatch
         | P_aux (P_var (P_aux (P_id id,p_id_annot), TP_aux (TP_var kid, _)),_) ->
            begin
              match lit_e with
              | L_num i ->
                 DoesMatch ([id, E_aux (e,(l,annot))],
                            [kid,Nexp_aux (Nexp_constant i,Unknown)])
              (* For undefined we fix the type-level size (because there's no good
                 way to construct an undefined size), but leave the term as undefined
                 to make the meaning clear. *)
              | L_undef ->
                 let nexp = fabricate_nexp l annot in
                 let typ = subst_src_typ (KBindings.singleton kid nexp) (typ_of_annot p_id_annot) in
                 DoesMatch ([id, E_aux (E_cast (typ,E_aux (e,(l,None))),(l,None))],
                            [kid,nexp])
              | _ ->
                 (Reporting_basic.print_err false true lit_l "Monomorphisation"
                    "Unexpected kind of literal for var match"; GiveUp)
            end
         | P_aux (_,(l',_)) ->
            (Reporting_basic.print_err false true l' "Monomorphisation"
               "Unexpected kind of pattern for literal"; GiveUp)
       in findpat_generic checkpat "literal" assigns cases
    | E_cast (undef_typ, (E_aux (E_lit (L_aux (L_undef, lit_l)),_) as e_undef)) ->
       let checkpat = function
         | P_aux (P_lit (L_aux (lit_p, _)),_) -> DoesNotMatch
         | P_aux (P_var (P_aux (P_id id,p_id_annot), TP_aux (TP_var kid, _)),_) ->
              (* For undefined we fix the type-level size (because there's no good
                 way to construct an undefined size), but leave the term as undefined
                 to make the meaning clear. *)
            let nexp = fabricate_nexp l annot in
            let kids = equal_kids (env_of_annot p_id_annot) kid in
            let ksubst = KidSet.fold (fun k b -> KBindings.add k nexp b) kids KBindings.empty in
            let typ = subst_src_typ ksubst (typ_of_annot p_id_annot) in
            DoesMatch ([id, E_aux (E_cast (typ,e_undef),(l,None))],
                       KBindings.bindings ksubst)
         | P_aux (_,(l',_)) ->
            (Reporting_basic.print_err false true l' "Monomorphisation"
               "Unexpected kind of pattern for literal"; GiveUp)
       in findpat_generic checkpat "literal" assigns cases
    | _ -> None

  and can_match exp =
    let env = Type_check.env_of exp in
    can_match_with_env env exp
  in

  let subst_exp substs ksubsts exp =
    let substs = bindings_from_list substs, ksubsts in
    fst (const_prop_exp substs Bindings.empty exp)
  in
    
  (* Split a variable pattern into every possible value *)

  let split var pat_l annot =
    let v = string_of_id var in
    let env = Type_check.env_of_annot (pat_l, annot) in
    let typ = Type_check.typ_of_annot (pat_l, annot) in
    let typ = Env.expand_synonyms env typ in
    let Typ_aux (ty,l) = typ in
    let new_l = Generated l in
    let renew_id (Id_aux (id,l)) = Id_aux (id,new_l) in
    let cannot msg =
      let open Reporting_basic in
      let error =
        Err_general (pat_l,
                     ("Cannot split type " ^ string_of_typ typ ^ " for variable " ^ v ^ ": " ^ msg))
      in if all_errors
        then (no_errors_happened := false;
              print_error error;
              [P_aux (P_id var,(pat_l,annot)),[],[],[]])
        else raise (Fatal_error error)
    in
    match ty with
    | Typ_id (Id_aux (Id "bool",_)) ->
       [P_aux (P_lit (L_aux (L_true,new_l)),(l,annot)),[var, E_aux (E_lit (L_aux (L_true,new_l)),(new_l,annot))],[],[];
        P_aux (P_lit (L_aux (L_false,new_l)),(l,annot)),[var, E_aux (E_lit (L_aux (L_false,new_l)),(new_l,annot))],[],[]]

    | Typ_id id ->
       (try
         (* enumerations *)
         let ns = Env.get_enum id env in
         List.map (fun n -> (P_aux (P_id (renew_id n),(l,annot)),
                             [var,E_aux (E_id (renew_id n),(new_l,annot))],[],[])) ns
       with Type_error _ ->
         match id with
         | Id_aux (Id "bit",_) ->
            List.map (fun b ->
              P_aux (P_lit (L_aux (b,new_l)),(l,annot)),
              [var,E_aux (E_lit (L_aux (b,new_l)),(new_l, annot))],[],[])
              [L_zero; L_one]
         | _ -> cannot ("don't know about type " ^ string_of_id id))

    | Typ_app (Id_aux (Id "vector",_), [Typ_arg_aux (Typ_arg_nexp len,_);_;Typ_arg_aux (Typ_arg_typ (Typ_aux (Typ_id (Id_aux (Id "bit",_)),_)),_)]) ->
       (match len with
       | Nexp_aux (Nexp_constant sz,_) ->
          let lits = make_vectors (Big_int.to_int sz) in
          List.map (fun lit ->
            P_aux (P_lit lit,(l,annot)),
            [var,E_aux (E_lit lit,(new_l,annot))],[],[]) lits
       | _ ->
          cannot ("length not constant, " ^ string_of_nexp len)
       )
    (* set constrained numbers *)
    | Typ_app (Id_aux (Id "atom",_), [Typ_arg_aux (Typ_arg_nexp (Nexp_aux (value,_) as nexp),_)]) ->
       begin
         let mk_lit kid i =
            let lit = L_aux (L_num i,new_l) in
            P_aux (P_lit lit,(l,annot)),
            [var,E_aux (E_lit lit,(new_l,annot))],[],
            match kid with None -> [] | Some k -> [(k,nconstant i)]
         in
         match value with
         | Nexp_constant i -> [mk_lit None i]
         | Nexp_var kvar ->
           let ncs = Env.get_constraints env in
           let nc = List.fold_left nc_and nc_true ncs in
           (match extract_set_nc l kvar nc with
           | (is,_) -> List.map (mk_lit (Some kvar)) is
           | exception Reporting_basic.Fatal_error (Reporting_basic.Err_general (_,msg)) -> cannot msg)
         | _ -> cannot ("unsupport atom nexp " ^ string_of_nexp nexp)
       end
    | _ -> cannot ("unsupported type " ^ string_of_typ typ)
  in
  

  (* Split variable patterns at the given locations *)

  let map_locs ls (Defs defs) =
    let rec match_l = function
      | Unknown
      | Int _ -> []
      | Generated l -> [] (* Could do match_l l, but only want to split user-written patterns *)
      | Range (p,q) ->
         let matches =
           List.filter (fun ((filename,line),_,_) ->
             p.Lexing.pos_fname = filename &&
               p.Lexing.pos_lnum <= line && line <= q.Lexing.pos_lnum) ls
         in List.map (fun (_,var,optpats) -> (var,optpats)) matches
    in 

    let split_pat vars p =
      let id_match = function
        | Id_aux (Id x,_) -> (try Some (List.assoc x vars) with Not_found -> None)
        | Id_aux (DeIid x,_) -> (try Some (List.assoc x vars) with Not_found -> None)
      in

      let rec list f = function
        | [] -> None
        | h::t ->
           let t' =
             match list f t with
             | None -> [t,[],[],[]]
             | Some t' -> t'
           in
           let h' =
             match f h with
             | None -> [h,[],[],[]]
             | Some ps -> ps
           in
           Some (List.concat
                   (List.map (fun (h,hsubs,hpchoices,hksubs) ->
                     List.map (fun (t,tsubs,tpchoices,tksubs) ->
                       (h::t, hsubs@tsubs, hpchoices@tpchoices, hksubs@tksubs)) t') h'))
      in
      let rec spl (P_aux (p,(l,annot))) =
        let relist f ctx ps =
          optmap (list f ps) 
            (fun ps ->
              List.map (fun (ps,sub,pchoices,ksub) -> P_aux (ctx ps,(l,annot)),sub,pchoices,ksub) ps)
        in
        let re f p =
          optmap (spl p)
            (fun ps -> List.map (fun (p,sub,pchoices,ksub) -> (P_aux (f p,(l,annot)), sub, pchoices, ksub)) ps)
        in
        let fpat (FP_aux ((FP_Fpat (id,p),annot))) =
          optmap (spl p)
            (fun ps -> List.map (fun (p,sub,pchoices,ksub) -> FP_aux (FP_Fpat (id,p), annot), sub, pchoices, ksub) ps)
        in
        match p with
        | P_lit _
        | P_wild
          -> None
        | P_as (p',id) when id_match id <> None ->
           raise (Reporting_basic.err_general l
                    ("Cannot split " ^ string_of_id id ^ " on 'as' pattern"))
        | P_as (p',id) ->
           re (fun p -> P_as (p,id)) p'
        | P_typ (t,p') -> re (fun p -> P_typ (t,p)) p'
        | P_var (p', (TP_aux (TP_var kid,_) as tp)) ->
           (match spl p' with
           | None -> None
           | Some ps ->
              let kids = equal_kids (pat_env_of p') kid in
              Some (List.map (fun (p,sub,pchoices,ksub) ->
                P_aux (P_var (p,tp),(l,annot)), sub, pchoices,
                List.concat
                  (List.map
                     (fun (k,nexp) -> if KidSet.mem k kids then [(kid,nexp);(k,nexp)] else [(k,nexp)])
                     ksub)) ps))
        | P_var (p',tp) -> re (fun p -> P_var (p,tp)) p'
        | P_id id ->
           (match id_match id with
           | None -> None
           (* Total case split *)
           | Some None -> Some (split id l annot)
           (* Where the analysis proposed a specific case split, propagate a
              literal as normal, but perform a more careful transformation
              otherwise *)
           | Some (Some (pats,l)) ->
              let max = List.length pats - 1 in
              Some (List.mapi (fun i p ->
                match p with
                | P_aux (P_lit lit,(pl,pannot))
                    when (match lit with L_aux (L_undef,_) -> false | _ -> true) ->
                   let orig_typ = Env.base_typ_of (env_of_annot (l,annot)) (typ_of_annot (l,annot)) in
                   let kid_subst = match lit, orig_typ with
                     | L_aux (L_num i,_),
                       Typ_aux
                         (Typ_app (Id_aux (Id "atom",_),
                                   [Typ_arg_aux (Typ_arg_nexp
                                                   (Nexp_aux (Nexp_var var,_)),_)]),_) ->
                        [var,nconstant i]
                     | _ -> []
                   in
                   p,[id,E_aux (E_lit lit,(Generated pl,pannot))],[l,(i,max,[])],kid_subst
                | _ ->
                   let p',subst = freshen_pat_bindings p in
                   match p' with
                   | P_aux (P_wild,_) ->
                      P_aux (P_id id,(l,annot)),[],[l,(i,max,subst)],[]
                   | _ ->
                      P_aux (P_as (p',id),(l,annot)),[],[l,(i,max,subst)],[])
                      pats)
           )
        | P_app (id,ps) ->
           relist spl (fun ps -> P_app (id,ps)) ps
        | P_record (fps,flag) ->
           relist fpat (fun fps -> P_record (fps,flag)) fps
        | P_vector ps ->
           relist spl (fun ps -> P_vector ps) ps
        | P_vector_concat ps ->
           relist spl (fun ps -> P_vector_concat ps) ps
        | P_tup ps ->
           relist spl (fun ps -> P_tup ps) ps
        | P_list ps ->
           relist spl (fun ps -> P_list ps) ps
        | P_cons (p1,p2) ->
           match spl p1, spl p2 with
           | None, None -> None
           | p1', p2' ->
              let p1' = match p1' with None -> [p1,[],[],[]] | Some p1' -> p1' in
              let p2' = match p2' with None -> [p2,[],[],[]] | Some p2' -> p2' in
              let ps = List.map (fun (p1',subs1,pchoices1,ksub1) -> List.map (fun (p2',subs2,pchoices2,ksub2) ->
                P_aux (P_cons (p1',p2'),(l,annot)),subs1@subs2,pchoices1@pchoices2,ksub1@ksub2) p2') p1' in
              Some (List.concat ps)
      in spl p
    in

    let map_pat_by_loc (P_aux (p,(l,_)) as pat) =
      match match_l l with
      | [] -> None
      | vars -> split_pat vars pat
    in
    let map_pat (P_aux (p,(l,tannot)) as pat) =
      match map_pat_by_loc pat with
      | Some l -> VarSplit l
      | None ->
         match p with
         | P_app (id,args) ->
            begin
              let kid,kid_annot =
                match args with
                | [P_aux (P_var (_, TP_aux (TP_var kid, _)),ann)] -> kid,ann
                | _ -> 
                   raise (Reporting_basic.err_general l
                            "Pattern match not currently supported by monomorphisation")
              in match List.find (fun (id',_) -> Id.compare id id' = 0) refinements with
              | (_,variants) ->
                 let map_inst (insts,id',_) =
                   let insts =
                     match insts with [(v,Some i)] -> [(kid,Nexp_aux (Nexp_constant i, Generated l))]
                     | _ -> assert false
                   in
(*
                   let insts,_ = split_insts insts in
                   let insts = List.map (fun (v,i) ->
                     (??,
                      Nexp_aux (Nexp_constant i,Generated l)))
                     insts in
  P_aux (P_app (id',args),(Generated l,tannot)),
*)
                   P_aux (P_app (id',[P_aux (P_id (id_of_kid kid),kid_annot)]),(Generated l,tannot)),
                   kbindings_from_list insts
                 in
                 ConstrSplit (List.map map_inst variants)
              | exception Not_found -> NoSplit
            end
         | _ -> NoSplit
    in

    let check_single_pat (P_aux (_,(l,annot)) as p) =
      match match_l l with
      | [] -> p
      | lvs ->
         let pvs = bindings_from_pat p in
         let pvs = List.map string_of_id pvs in
         let overlap = List.exists (fun (v,_) -> List.mem v pvs) lvs in
         let () =
           if overlap then
             Reporting_basic.print_err false true l "Monomorphisation"
               "Splitting a singleton pattern is not possible"
         in p
    in

    let check_split_size lst l =
      let size = List.length lst in
      if size > size_set_limit then
        let open Reporting_basic in
        let error =
          Err_general (l, "Case split is too large (" ^ string_of_int size ^
            " > limit " ^ string_of_int size_set_limit ^ ")")
        in if all_errors
          then (no_errors_happened := false;
                print_error error; false)
          else raise (Fatal_error error)
      else true
    in

    let rec map_exp ((E_aux (e,annot)) as ea) =
      let re e = E_aux (e,annot) in
      match e with
      | E_block es -> re (E_block (List.map map_exp es))
      | E_nondet es -> re (E_nondet (List.map map_exp es))
      | E_id _
      | E_lit _
      | E_sizeof _
      | E_internal_exp _
      | E_sizeof_internal _
      | E_internal_exp_user _
      | E_comment _
      | E_constraint _
        -> ea
      | E_cast (t,e') -> re (E_cast (t, map_exp e'))
      | E_app (id,es) ->
         let es' = List.map map_exp es in
         let env = env_of_annot annot in
         begin
           match Env.is_union_constructor id env, refine_constructor refinements (fst annot) env id es' with
           | true, Some exp -> re exp
           | _,_ -> re (E_app (id,es'))
         end
      | E_app_infix (e1,id,e2) -> re (E_app_infix (map_exp e1,id,map_exp e2))
      | E_tuple es -> re (E_tuple (List.map map_exp es))
      | E_if (e1,e2,e3) -> re (E_if (map_exp e1, map_exp e2, map_exp e3))
      | E_for (id,e1,e2,e3,ord,e4) -> re (E_for (id,map_exp e1,map_exp e2,map_exp e3,ord,map_exp e4))
      | E_loop (loop,e1,e2) -> re (E_loop (loop,map_exp e1,map_exp e2))
      | E_vector es -> re (E_vector (List.map map_exp es))
      | E_vector_access (e1,e2) -> re (E_vector_access (map_exp e1,map_exp e2))
      | E_vector_subrange (e1,e2,e3) -> re (E_vector_subrange (map_exp e1,map_exp e2,map_exp e3))
      | E_vector_update (e1,e2,e3) -> re (E_vector_update (map_exp e1,map_exp e2,map_exp e3))
      | E_vector_update_subrange (e1,e2,e3,e4) -> re (E_vector_update_subrange (map_exp e1,map_exp e2,map_exp e3,map_exp e4))
      | E_vector_append (e1,e2) -> re (E_vector_append (map_exp e1,map_exp e2))
      | E_list es -> re (E_list (List.map map_exp es))
      | E_cons (e1,e2) -> re (E_cons (map_exp e1,map_exp e2))
      | E_record fes -> re (E_record (map_fexps fes))
      | E_record_update (e,fes) -> re (E_record_update (map_exp e, map_fexps fes))
      | E_field (e,id) -> re (E_field (map_exp e,id))
      | E_case (e,cases) -> re (E_case (map_exp e, List.concat (List.map map_pexp cases)))
      | E_let (lb,e) -> re (E_let (map_letbind lb, map_exp e))
      | E_assign (le,e) -> re (E_assign (map_lexp le, map_exp e))
      | E_exit e -> re (E_exit (map_exp e))
      | E_throw e -> re (E_throw e)
      | E_try (e,cases) -> re (E_try (map_exp e, List.concat (List.map map_pexp cases)))
      | E_return e -> re (E_return (map_exp e))
      | E_assert (e1,e2) -> re (E_assert (map_exp e1,map_exp e2))
      | E_internal_cast (ann,e) -> re (E_internal_cast (ann,map_exp e))
      | E_comment_struc e -> re (E_comment_struc e)
      | E_var (le,e1,e2) -> re (E_var (map_lexp le, map_exp e1, map_exp e2))
      | E_internal_plet (p,e1,e2) -> re (E_internal_plet (check_single_pat p, map_exp e1, map_exp e2))
      | E_internal_return e -> re (E_internal_return (map_exp e))
    and map_opt_default ((Def_val_aux (ed,annot)) as eda) =
      match ed with
      | Def_val_empty -> eda
      | Def_val_dec e -> Def_val_aux (Def_val_dec (map_exp e),annot)
    and map_fexps (FES_aux (FES_Fexps (fes,flag), annot)) =
      FES_aux (FES_Fexps (List.map map_fexp fes, flag), annot)
    and map_fexp (FE_aux (FE_Fexp (id,e), annot)) =
      FE_aux (FE_Fexp (id,map_exp e),annot)
    and map_pexp = function
      | Pat_aux (Pat_exp (p,e),l) ->
         let nosplit = [Pat_aux (Pat_exp (p,map_exp e),l)] in
         (match map_pat p with
         | NoSplit -> nosplit
         | VarSplit patsubsts ->
            if check_split_size patsubsts (pat_loc p) then
              List.map (fun (pat',substs,pchoices,ksubsts) ->
                let ksubsts = kbindings_from_list ksubsts in
                let exp' = nexp_subst_exp ksubsts e in
                let exp' = subst_exp substs ksubsts exp' in
                let exp' = apply_pat_choices pchoices exp' in
                let exp' = stop_at_false_assertions exp' in
                Pat_aux (Pat_exp (pat', map_exp exp'),l))
                patsubsts
            else nosplit
         | ConstrSplit patnsubsts ->
            List.map (fun (pat',nsubst) ->
              let pat' = nexp_subst_pat nsubst pat' in
              let exp' = nexp_subst_exp nsubst e in
              Pat_aux (Pat_exp (pat', map_exp exp'),l)
            ) patnsubsts)
      | Pat_aux (Pat_when (p,e1,e2),l) ->
         let nosplit = [Pat_aux (Pat_when (p,map_exp e1,map_exp e2),l)] in
         (match map_pat p with
         | NoSplit -> nosplit
         | VarSplit patsubsts ->
            if check_split_size patsubsts (pat_loc p) then
              List.map (fun (pat',substs,pchoices,ksubsts) ->
                let ksubsts = kbindings_from_list ksubsts in
                let exp1' = nexp_subst_exp ksubsts e1 in
                let exp1' = subst_exp substs ksubsts exp1' in
                let exp1' = apply_pat_choices pchoices exp1' in
                let exp2' = nexp_subst_exp ksubsts e2 in
                let exp2' = subst_exp substs ksubsts exp2' in
                let exp2' = apply_pat_choices pchoices exp2' in
                let exp2' = stop_at_false_assertions exp2' in
                Pat_aux (Pat_when (pat', map_exp exp1', map_exp exp2'),l))
                patsubsts
            else nosplit
         | ConstrSplit patnsubsts ->
            List.map (fun (pat',nsubst) ->
              let pat' = nexp_subst_pat nsubst pat' in
              let exp1' = nexp_subst_exp nsubst e1 in
              let exp2' = nexp_subst_exp nsubst e2 in
              Pat_aux (Pat_when (pat', map_exp exp1', map_exp exp2'),l)
            ) patnsubsts)
    and map_letbind (LB_aux (lb,annot)) =
      match lb with
      | LB_val (p,e) -> LB_aux (LB_val (check_single_pat p,map_exp e), annot)
    and map_lexp ((LEXP_aux (e,annot)) as le) =
      let re e = LEXP_aux (e,annot) in
      match e with
      | LEXP_id _
      | LEXP_cast _
        -> le
      | LEXP_memory (id,es) -> re (LEXP_memory (id,List.map map_exp es))
      | LEXP_tup les -> re (LEXP_tup (List.map map_lexp les))
      | LEXP_vector (le,e) -> re (LEXP_vector (map_lexp le, map_exp e))
      | LEXP_vector_range (le,e1,e2) -> re (LEXP_vector_range (map_lexp le, map_exp e1, map_exp e2))
      | LEXP_field (le,id) -> re (LEXP_field (map_lexp le, id))
    in

    let map_funcl (FCL_aux (FCL_Funcl (id,pexp),annot)) =
      List.map (fun pexp -> FCL_aux (FCL_Funcl (id,pexp),annot)) (map_pexp pexp)
    in

    let map_fundef (FD_aux (FD_function (r,t,e,fcls),annot)) =
      FD_aux (FD_function (r,t,e,List.concat (List.map map_funcl fcls)),annot)
    in
    let map_scattered_def sd =
      match sd with
      | SD_aux (SD_scattered_funcl fcl, annot) ->
         List.map (fun fcl' -> SD_aux (SD_scattered_funcl fcl', annot)) (map_funcl fcl)
      | _ -> [sd]
    in
    let map_def d =
      match d with
      | DEF_kind _
      | DEF_type _
      | DEF_spec _
      | DEF_default _
      | DEF_reg_dec _
      | DEF_comm _
      | DEF_overload _
      | DEF_fixity _
      | DEF_internal_mutrec _
        -> [d]
      | DEF_fundef fd -> [DEF_fundef (map_fundef fd)]
      | DEF_val lb -> [DEF_val (map_letbind lb)]
      | DEF_scattered sd -> List.map (fun x -> DEF_scattered x) (map_scattered_def sd)
    in
    Defs (List.concat (List.map map_def defs))
  in
  let defs'' = map_locs splits defs' in
  !no_errors_happened, defs''



(* The next section of code turns atom('n) types into itself('n) types, which
   survive into the Lem output, so can be used to parametrise functions over
   internal bitvector lengths (such as datasize and regsize in ARM specs *)

module AtomToItself =
struct

let findi f =
  let rec aux n = function
    | [] -> None
    | h::t -> match f h with Some x -> Some (n,x) | _ -> aux (n+1) t
  in aux 0

let mapat f is xs =
  let rec aux n = function
    | [] -> []
    | h::t when Util.IntSet.mem n is ->
       let h' = f h in
       let t' = aux (n+1) t in
       h'::t'
    | h::t ->
       let t' = aux (n+1) t in
       h::t'
  in aux 0 xs

let mapat_extra f is xs =
  let rec aux n = function
    | [] -> [], []
    | h::t when Util.IntSet.mem n is ->
       let h',x = f h in
       let t',xs = aux (n+1) t in
       h'::t',x::xs
    | h::t ->
       let t',xs = aux (n+1) t in
       h::t',xs
  in aux 0 xs

let tyvars_bound_in_pat pat =
  let open Rewriter in
  fst (fold_pat
         { (compute_pat_alg KidSet.empty KidSet.union) with
           p_var = (fun ((s,pat), (TP_aux (TP_var kid, _) as tpat)) ->
                     KidSet.add kid s, P_var (pat, tpat)) }
         pat)
let tyvars_bound_in_lb (LB_aux (LB_val (pat,_),_)) = tyvars_bound_in_pat pat

let rec sizes_of_typ (Typ_aux (t,l)) =
  match t with
  | Typ_id _
  | Typ_var _
    -> KidSet.empty
  | Typ_fn _ -> raise (Reporting_basic.err_general l
                         "Function type on expressinon")
  | Typ_tup typs -> kidset_bigunion (List.map sizes_of_typ typs)
  | Typ_exist (kids,_,typ) ->
     List.fold_left (fun s k -> KidSet.remove k s) (sizes_of_typ typ) kids
  | Typ_app (Id_aux (Id "vector",_),
             [Typ_arg_aux (Typ_arg_nexp size,_);
              _;Typ_arg_aux (Typ_arg_typ (Typ_aux (Typ_id (Id_aux (Id "bit",_)),_)),_)]) ->
     KidSet.of_list (size_nvars_nexp size)
  | Typ_app (_,tas) ->
     kidset_bigunion (List.map sizes_of_typarg tas)
and sizes_of_typarg (Typ_arg_aux (ta,_)) =
  match ta with
    Typ_arg_nexp _
  | Typ_arg_order _
    -> KidSet.empty
  | Typ_arg_typ typ -> sizes_of_typ typ

let sizes_of_annot = function
  | _,None -> KidSet.empty
  | _,Some (env,typ,_) -> sizes_of_typ (Env.base_typ_of env typ)

let change_parameter_pat = function
  | P_aux (P_id var, (l,Some (env,typ,_)))
  | P_aux (P_typ (_,P_aux (P_id var, (l,Some (env,typ,_)))),_) ->
     P_aux (P_id var, (l,None)), var
  | P_aux (_,(l,_)) -> raise (Reporting_basic.err_unreachable l
                                "Expected variable pattern")

(* We add code to change the itself('n) parameter into the corresponding
   integer. *)
let add_var_rebind exp var =
  let l = Generated Unknown in
  let annot = (l,None) in
  E_aux (E_let (LB_aux (LB_val (P_aux (P_id var,annot),
                                E_aux (E_app (mk_id "size_itself_int",[E_aux (E_id var,annot)]),annot)),annot),exp),annot)

(* atom('n) arguments to function calls need to be rewritten *)
let replace_with_the_value bound_nexps (E_aux (_,(l,_)) as exp) =
  let env = env_of exp in
  let typ, wrap = match typ_of exp with
    | Typ_aux (Typ_exist (kids,nc,typ),l) -> typ, fun t -> Typ_aux (Typ_exist (kids,nc,t),l)
    | typ -> typ, fun x -> x
  in
  let typ = Env.expand_synonyms env typ in
  let replace_size size = 
    (* TODO: pick simpler nexp when there's a choice (also in pretty printer) *)
    let is_equal nexp =
      prove env (NC_aux (NC_equal (size,nexp), Parse_ast.Unknown))
    in
    if is_nexp_constant size then size else
      match List.find is_equal bound_nexps with
      | nexp -> nexp
      | exception Not_found -> size
  in
  let mk_exp nexp l l' =
    let nexp = replace_size nexp in
    E_aux (E_cast (wrap (Typ_aux (Typ_app (Id_aux (Id "itself",Generated Unknown),
                                           [Typ_arg_aux (Typ_arg_nexp nexp,l')]),Generated Unknown)),
                   E_aux (E_app (Id_aux (Id "make_the_value",Generated Unknown),[exp]),(Generated l,None))),
           (Generated l,None))
  in
  match typ with
  | Typ_aux (Typ_app (Id_aux (Id "range",_),
                      [Typ_arg_aux (Typ_arg_nexp nexp,l');Typ_arg_aux (Typ_arg_nexp nexp',_)]),_)
    when nexp_identical nexp nexp' ->
     mk_exp nexp l l'
  | Typ_aux (Typ_app (Id_aux (Id "atom",_),
                      [Typ_arg_aux (Typ_arg_nexp nexp,l')]),_) ->
     mk_exp nexp l l'
  | _ -> raise (Reporting_basic.err_unreachable l
                  "atom stopped being an atom?")

let replace_type env typ =
  let Typ_aux (t,l) = Env.expand_synonyms env typ in
  match t with
  | Typ_app (Id_aux (Id "range",_),
             [Typ_arg_aux (Typ_arg_nexp nexp,l');Typ_arg_aux (Typ_arg_nexp _,_)]) ->
     Typ_aux (Typ_app (Id_aux (Id "itself",Generated Unknown),
                       [Typ_arg_aux (Typ_arg_nexp nexp,l')]),Generated l)
  | Typ_app (Id_aux (Id "atom",_),
                      [Typ_arg_aux (Typ_arg_nexp nexp,l')]) ->
     Typ_aux (Typ_app (Id_aux (Id "itself",Generated Unknown),
                       [Typ_arg_aux (Typ_arg_nexp nexp,l')]),Generated l)
  | _ -> raise (Reporting_basic.err_unreachable l
                  "atom stopped being an atom?")


let rewrite_size_parameters env (Defs defs) =
  let open Rewriter in
  let open Util in

  let sizes_funcl fsizes (FCL_aux (FCL_Funcl (id,pexp),(l,_))) =
    let pat,guard,exp,pannot = destruct_pexp pexp in
    let parameters = match pat with
      | P_aux (P_tup ps,_) -> ps
      | _ -> [pat]
    in
    let add_parameter (i,nmap) (P_aux (_,(_,Some (env,typ,_)))) =
      let nmap =
        match Env.base_typ_of env typ with
          Typ_aux (Typ_app(Id_aux (Id "range",_),
                           [Typ_arg_aux (Typ_arg_nexp nexp,_);
                            Typ_arg_aux (Typ_arg_nexp nexp',_)]),_)
            when Nexp.compare nexp nexp' = 0 && not (NexpMap.mem nexp nmap) ->
              NexpMap.add nexp i nmap
        | Typ_aux (Typ_app(Id_aux (Id "atom", _),
                           [Typ_arg_aux (Typ_arg_nexp nexp,_)]), _)
            when not (NexpMap.mem nexp nmap) ->
           NexpMap.add nexp i nmap
        | _ -> nmap
      in (i+1,nmap)
    in
    let (_,nexp_map) = List.fold_left add_parameter (0,NexpMap.empty) parameters in
    let nexp_list = NexpMap.bindings nexp_map in
    let parameters_for = function
      | Some (env,typ,_) ->
         begin match Env.base_typ_of env typ with
         | Typ_aux (Typ_app (Id_aux (Id "vector",_), [Typ_arg_aux (Typ_arg_nexp size,_);_;_]),_)
             when not (is_nexp_constant size) ->
            begin
              match NexpMap.find size nexp_map with
              | i -> IntSet.singleton i
              | exception Not_found ->
                 (* Look for equivalent nexps, but only in consistent type env *)
                 if prove env (NC_aux (NC_false,Unknown)) then IntSet.empty else
                   match List.find (fun (nexp,i) -> 
                     prove env (NC_aux (NC_equal (nexp,size),Unknown))) nexp_list with
                   | _, i -> IntSet.singleton i
                   | exception Not_found -> IntSet.empty
          end
         | _ -> IntSet.empty
         end
      | None -> IntSet.empty
    in
    let parameters_to_rewrite =
      fst (fold_pexp
             { (compute_exp_alg IntSet.empty IntSet.union) with
               e_aux = (fun ((s,e),(l,annot)) -> IntSet.union s (parameters_for annot),E_aux (e,(l,annot)))
             } pexp)
    in
    let new_nexps = NexpSet.of_list (List.map fst
      (List.filter (fun (nexp,i) -> IntSet.mem i parameters_to_rewrite) nexp_list)) in
    match Bindings.find id fsizes with
    | old,old_nexps -> Bindings.add id (IntSet.union old parameters_to_rewrite,
                                        NexpSet.union old_nexps new_nexps) fsizes
    | exception Not_found -> Bindings.add id (parameters_to_rewrite, new_nexps) fsizes
  in
  let sizes_def fsizes = function
    | DEF_fundef (FD_aux (FD_function (_,_,_,funcls),_)) ->
       List.fold_left sizes_funcl fsizes funcls
    | _ -> fsizes
  in
  let fn_sizes = List.fold_left sizes_def Bindings.empty defs in

  let rewrite_funcl (FCL_aux (FCL_Funcl (id,pexp),(l,annot))) =
    let pat,guard,body,(pl,_) = destruct_pexp pexp in
    let pat,guard,body, nexps =
      (* Update pattern and add itself -> nat wrapper to body *)
      match Bindings.find id fn_sizes with
      | to_change,nexps ->
         let pat, vars =
           match pat with
             P_aux (P_tup pats,(l,_)) ->
               let pats, vars = mapat_extra change_parameter_pat to_change pats in
               P_aux (P_tup pats,(l,None)), vars
           | P_aux (_,(l,_)) ->
              begin
                if IntSet.is_empty to_change then pat, []
                else
                   let pat, var = change_parameter_pat pat in
                   pat, [var]
              end
         in
         (* TODO: only add bindings that are necessary (esp for guards) *)
         let body = List.fold_left add_var_rebind body vars in
         let guard = match guard with
           | None -> None
           | Some exp -> Some (List.fold_left add_var_rebind exp vars)
         in
         pat,guard,body,nexps
      | exception Not_found -> pat,guard,body,NexpSet.empty
    in
    (* Update function applications *)
    let funcl_typ = typ_of_annot (l,annot) in
    let already_visible_nexps =
      NexpSet.union
         (Pretty_print_lem.lem_nexps_of_typ funcl_typ)
         (Pretty_print_lem.typeclass_nexps funcl_typ)
    in
    let bound_nexps = NexpSet.elements (NexpSet.union nexps already_visible_nexps) in
    let rewrite_e_app (id,args) =
      match Bindings.find id fn_sizes with
      | to_change,_ ->
         let args' = mapat (replace_with_the_value bound_nexps) to_change args in
         E_app (id,args')
      | exception Not_found -> E_app (id,args)
    in
    let body = fold_exp { id_exp_alg with e_app = rewrite_e_app } body in
    let guard = match guard with
      | None -> None
      | Some exp -> Some (fold_exp { id_exp_alg with e_app = rewrite_e_app } exp) in
    FCL_aux (FCL_Funcl (id,construct_pexp (pat,guard,body,(pl,None))),(l,None))
  in
  let rewrite_def = function
    | DEF_fundef (FD_aux (FD_function (recopt,tannopt,effopt,funcls),(l,_))) ->
       (* TODO rewrite tannopt? *)
       DEF_fundef (FD_aux (FD_function (recopt,tannopt,effopt,List.map rewrite_funcl funcls),(l,None)))
    | DEF_spec (VS_aux (VS_val_spec (typschm,id,extern,cast),(l,annot))) as spec ->
       begin
         match Bindings.find id fn_sizes with
         | to_change,_ when not (IntSet.is_empty to_change) ->
            let typschm = match typschm with
              | TypSchm_aux (TypSchm_ts (tq,typ),l) ->
                 let typ = match typ with
                   | Typ_aux (Typ_fn (Typ_aux (Typ_tup ts,l),t2,eff),l2) ->
                      Typ_aux (Typ_fn (Typ_aux (Typ_tup (mapat (replace_type env) to_change ts),l),t2,eff),l2)
                   | Typ_aux (Typ_fn (typ,t2,eff),l2) ->
                      Typ_aux (Typ_fn (replace_type env typ,t2,eff),l2)
                   | _ -> replace_type env typ
                 in TypSchm_aux (TypSchm_ts (tq,typ),l)
            in
            DEF_spec (VS_aux (VS_val_spec (typschm,id,extern,cast),(l,None)))
         | _ -> spec
         | exception Not_found -> spec
       end
    | def -> def
  in
(*
  Bindings.iter (fun id args ->
    print_endline (string_of_id id ^ " needs " ^
                     String.concat ", " (List.map string_of_int args))) fn_sizes
*)
  Defs (List.map rewrite_def defs)

end


let is_id env id =
  let ids = Env.get_overloads (Id_aux (id,Parse_ast.Unknown)) env in
  let ids = id :: List.map (fun (Id_aux (id,_)) -> id) ids in
  fun (Id_aux (x,_)) -> List.mem x ids

(* Type-agnostic pattern comparison for merging below *)

let lit_eq' (L_aux (l1,_)) (L_aux (l2,_)) =
  match l1, l2 with
  | L_num n1, L_num n2 -> Big_int.equal n1 n2
  | _,_ -> l1 = l2

let forall2 p x y =
  try List.for_all2 p x y with Invalid_argument _ -> false

let rec typ_pat_eq (TP_aux (tp1, _)) (TP_aux (tp2, _)) =
  match tp1, tp2 with
  | TP_wild, TP_wild -> true
  | TP_var kid1, TP_var kid2 -> Kid.compare kid1 kid2 = 0
  | TP_app (f1, args1), TP_app (f2, args2) when List.length args1 = List.length args2 ->
     Id.compare f1 f2 = 0 && List.for_all2 typ_pat_eq args1 args2
  | _, _ -> false
                                           
let rec pat_eq (P_aux (p1,_)) (P_aux (p2,_)) =
  match p1, p2 with
  | P_lit lit1, P_lit lit2 -> lit_eq' lit1 lit2
  | P_wild, P_wild -> true
  | P_as (p1',id1), P_as (p2',id2) -> Id.compare id1 id2 == 0 && pat_eq p1' p2'
  | P_typ (_,p1'), P_typ (_,p2') -> pat_eq p1' p2'
  | P_id id1, P_id id2 -> Id.compare id1 id2 == 0
  | P_var (p1', tpat1), P_var (p2', tpat2) -> typ_pat_eq tpat1 tpat2 && pat_eq p1' p2'
  | P_app (id1,args1), P_app (id2,args2) ->
     Id.compare id1 id2 == 0 && forall2 pat_eq args1 args2
  | P_record (fpats1, flag1), P_record (fpats2, flag2) ->
     flag1 == flag2 && forall2 fpat_eq fpats1 fpats2
  | P_vector ps1, P_vector ps2
  | P_vector_concat ps1, P_vector_concat ps2
  | P_tup ps1, P_tup ps2
  | P_list ps1, P_list ps2 -> List.for_all2 pat_eq ps1 ps2
  | P_cons (p1',p1''), P_cons (p2',p2'') -> pat_eq p1' p2' && pat_eq p1'' p2''
  | _,_ -> false
and fpat_eq (FP_aux (FP_Fpat (id1,p1),_)) (FP_aux (FP_Fpat (id2,p2),_)) =
  Id.compare id1 id2 == 0 && pat_eq p1 p2



module Analysis =
struct

type loc = string * int (* filename, line *)

let string_of_loc (s,l) = s ^ "." ^ string_of_int l

let id_pair_compare (id,l) (id',l') =
    match Id.compare id id' with
    | 0 -> compare l l'
    | x -> x

(* Usually we do a full case split on an argument, but sometimes we find a
   case expression in the function body that suggests a more compact case
   splitting. *)
type match_detail =
  | Total
  | Partial of tannot pat list * Parse_ast.l

(* Arguments that we might split on *)
module ArgSplits = Map.Make (struct
  type t = id * loc
  let compare = id_pair_compare
end)
type arg_splits = match_detail ArgSplits.t

(* Function id, funcl loc for adding splits on sizes in the body when
   there's no corresponding argument *)
module ExtraSplits = Map.Make (struct
  type t = id * Parse_ast.l
  let compare (id,l) (id',l') =
    let x = Id.compare id id' in
    if x <> 0 then x else
      compare l l'
end)
type extra_splits = (match_detail KBindings.t) ExtraSplits.t

(* Arguments that we should look at in callers *)
module CallerArgSet = Set.Make (struct
  type t = id * int
  let compare = id_pair_compare
end)

(* Type variables that we should look at in callers *)
module CallerKidSet = Set.Make (struct
  type t = id * kid
  let compare (id,kid) (id',kid') =
    match Id.compare id id' with
    | 0 -> Kid.compare kid kid'
    | x -> x
end)

(* Map from locations to string sets *)
module Failures = Map.Make (struct
  type t = Parse_ast.l
  let compare = compare
end)
module StringSet = Set.Make (struct
  type t = string
  let compare = compare
end)

type dependencies =
  | Have of arg_splits * extra_splits
  | Unknown of Parse_ast.l * string

let string_of_match_detail = function
  | Total -> "[total]"
  | Partial (pats,_) -> "[" ^ String.concat " | " (List.map string_of_pat pats) ^ "]"

let string_of_argsplits s =
  String.concat ", "
    (List.map (fun ((id,l),detail) ->
      string_of_id id ^ "." ^ string_of_loc l ^ string_of_match_detail detail)
                        (ArgSplits.bindings s))

let string_of_lx lx =
  let open Lexing in
  Printf.sprintf "%s,%d,%d,%d" lx.pos_fname lx.pos_lnum lx.pos_bol lx.pos_cnum

let rec simple_string_of_loc = function
  | Parse_ast.Unknown -> "Unknown"
  | Parse_ast.Int (s,None) -> "Int(" ^ s ^ ",None)"
  | Parse_ast.Int (s,Some l) -> "Int(" ^ s ^ ",Some("^simple_string_of_loc l^"))"
  | Parse_ast.Generated l -> "Generated(" ^ simple_string_of_loc l ^ ")"
  | Parse_ast.Range (lx1,lx2) -> "Range(" ^ string_of_lx lx1 ^ "->" ^ string_of_lx lx2 ^ ")"

let string_of_extra_splits s =
  String.concat ", "
    (List.map (fun ((id,l),ks) ->
      string_of_id id ^ "." ^ simple_string_of_loc l ^ ":" ^
        (String.concat "," (List.map (fun (kid,detail) ->
          string_of_kid kid ^ "." ^ string_of_match_detail detail)
                              (KBindings.bindings ks))))
       (ExtraSplits.bindings s))

let string_of_callerset s =
  String.concat ", " (List.map (fun (id,arg) -> string_of_id id ^ "." ^ string_of_int arg)
                        (CallerArgSet.elements s))

let string_of_callerkidset s =
  String.concat ", " (List.map (fun (id,kid) -> string_of_id id ^ "." ^ string_of_kid kid)
                        (CallerKidSet.elements s))

let string_of_dep = function
  | Have (args,extras) ->
     "Have (" ^ string_of_argsplits args ^ ";" ^ string_of_extra_splits extras ^ ")"
  | Unknown (l,msg) -> "Unknown " ^ msg ^ " at " ^ Reporting_basic.loc_to_string l

(* If a callee uses a type variable as a size, does it need to be split in the
   current function, or is it also a parameter?  (Note that there may be multiple
   calls, so more than one parameter can be involved) *)
type call_dep =
  | InFun of dependencies
  | Parents of CallerKidSet.t

(* Result of analysing the body of a function.  The split field gives
   the arguments to split based on the body alone, the extra_splits
   field where we want to case split on a size type variable but
   there's no corresponding argument so we introduce a case
   expression, and the failures field where we couldn't do anything.
   The other fields are used at the end for the interprocedural
   phase. *)

type result = {
  split : arg_splits;
  extra_splits : extra_splits;
  failures : StringSet.t Failures.t;
  (* Dependencies for type variables of each fn called, so that
     if the fn uses one for a bitvector size we can track it back *)
  split_on_call : (call_dep KBindings.t) Bindings.t; (* kids per fn *)
  kid_in_caller : CallerKidSet.t
}

let empty = {
  split = ArgSplits.empty;
  extra_splits = ExtraSplits.empty;
  failures = Failures.empty;
  split_on_call = Bindings.empty;
  kid_in_caller = CallerKidSet.empty
}

let merge_detail _ x y =
  match x,y with
  | None, x -> x
  | x, None -> x
  | Some (Partial (ps1,l1)), Some (Partial (ps2,l2))
    when l1 = l2 && forall2 pat_eq ps1 ps2 -> x
  | _ -> Some Total

let opt_merge f _ x y =
  match x,y with
  | None, _ -> y
  | _, None -> x
  | Some x, Some y -> Some (f x y)

let merge_extras = ExtraSplits.merge (opt_merge (KBindings.merge merge_detail))

let dmerge x y =
  match x,y with
  | Unknown (l,s), _ -> Unknown (l,s)
  | _, Unknown (l,s) -> Unknown (l,s)
  | Have (args,extras), Have (args',extras') ->
     Have (ArgSplits.merge merge_detail args args',
           merge_extras extras extras')

let dempty = Have (ArgSplits.empty, ExtraSplits.empty)

let dep_bindings_merge a1 a2 =
  Bindings.merge (opt_merge dmerge) a1 a2

let dep_kbindings_merge a1 a2 =
  KBindings.merge (opt_merge dmerge) a1 a2

let call_kid_merge k x y =
  match x, y with
  | None, x -> x
  | x, None -> x
  | Some (InFun deps), Some (Parents _)
  | Some (Parents _), Some (InFun deps)
    -> Some (InFun deps)
  | Some (InFun deps), Some (InFun deps')
    -> Some (InFun (dmerge deps deps'))
  | Some (Parents fns), Some (Parents fns')
    -> Some (Parents (CallerKidSet.union fns fns'))

let call_arg_merge k args args' =
  match args, args' with
  | None, x -> x
  | x, None -> x
  | Some kdep, Some kdep'
    -> Some (KBindings.merge call_kid_merge kdep kdep')

let failure_merge _ x y =
  match x, y with
  | None, x -> x
  | x, None -> x
  | Some x, Some y -> Some (StringSet.union x y)

let merge rs rs' = {
  split = ArgSplits.merge merge_detail rs.split rs'.split;
  extra_splits = merge_extras rs.extra_splits rs'.extra_splits;
  failures = Failures.merge failure_merge rs.failures rs'.failures;
  split_on_call = Bindings.merge call_arg_merge rs.split_on_call rs'.split_on_call;
  kid_in_caller = CallerKidSet.union rs.kid_in_caller rs'.kid_in_caller
}

type env = {
  top_kids : kid list;
  var_deps : dependencies Bindings.t;
  kid_deps : dependencies KBindings.t
}

let rec split3 = function
  | [] -> [],[],[]
  | ((h1,h2,h3)::t) ->
     let t1,t2,t3 = split3 t in
     (h1::t1,h2::t2,h3::t3)

let is_kid_in_env env kid =
  match Env.get_typ_var kid env with
  | _ -> true
  | exception _ -> false

let rec kids_bound_by_typ_pat (TP_aux (tp,_)) =
  match tp with
  | TP_wild -> KidSet.empty
  | TP_var kid -> KidSet.singleton kid
  | TP_app (_,pats) ->
     kidset_bigunion (List.map kids_bound_by_typ_pat pats)

(* We need both the explicitly bound kids from the AST, and any freshly
   generated kids from the typechecker. *)
let kids_bound_by_pat pat =
  let open Rewriter in
  fst (fold_pat ({ (compute_pat_alg KidSet.empty KidSet.union)
    with p_aux =
      (function ((s,(P_var (P_aux (_,(_,Some (_,typ,_))),tpat) as p)), (_,Some (env,_,_) as ann)) ->
        let kids = tyvars_of_typ typ in
        let new_kids = KidSet.filter (fun kid -> not (is_kid_in_env env kid)) kids in
        let tpat_kids = kids_bound_by_typ_pat tpat in
        KidSet.union s (KidSet.union new_kids tpat_kids), P_aux (p, ann)
      | ((s,p),ann) -> s, P_aux (p,ann))
    }) pat)

(* Add bound variables from a pattern to the environment with the given dependency. *)

let update_env env deps pat =
  let bound = bindings_from_pat pat in
  let var_deps = List.fold_left (fun ds v -> Bindings.add v deps ds) env.var_deps bound in
  let kbound = kids_bound_by_pat pat in
  let kid_deps = KidSet.fold (fun v ds -> KBindings.add v deps ds) kbound env.kid_deps in
  { env with var_deps = var_deps; kid_deps = kid_deps }

let assigned_vars_exps es =
  List.fold_left (fun vs exp -> IdSet.union vs (assigned_vars exp))
    IdSet.empty es

(* For adding control dependencies to mutable variables *)

let add_dep_to_assigned dep assigns es =
  let assigned = assigned_vars_exps es in
  Bindings.mapi (fun id d -> if IdSet.mem id assigned then dmerge dep d else d) assigns

(* Functions to give dependencies for type variables in nexps, constraints, types and
   unification variables.  For function calls we also supply a list of dependencies for
   arguments so that we can find dependencies for existentially bound sizes. *)

let deps_of_tyvars kid_deps arg_deps kids =
  let check kid deps =
    match KBindings.find kid kid_deps with
    | deps' -> dmerge deps deps'
    | exception Not_found ->
       match kid with
       | Kid_aux (Var kidstr, l) ->
          let unknown = Unknown (l, "Unknown type variable " ^ string_of_kid kid) in
          (* Tyvars from existentials in arguments have a special format *)
          if String.length kidstr > 5 && String.sub kidstr 0 4 = "'arg" then
            try
              let i = String.index kidstr '#' in
              let n = String.sub kidstr 4 (i-4) in
              let arg = int_of_string n in
              List.nth arg_deps arg
            with Not_found | Failure _ -> unknown
          else unknown
  in
  KidSet.fold check kids dempty

let deps_of_nexp kid_deps arg_deps nexp =
  let kids = nexp_frees nexp in
  deps_of_tyvars kid_deps arg_deps kids

let rec deps_of_nc kid_deps (NC_aux (nc,l)) =
  match nc with
  | NC_equal (nexp1,nexp2)
  | NC_bounded_ge (nexp1,nexp2)
  | NC_bounded_le (nexp1,nexp2)
  | NC_not_equal (nexp1,nexp2)
    -> dmerge (deps_of_nexp kid_deps [] nexp1) (deps_of_nexp kid_deps [] nexp2)
  | NC_set (kid,_) ->
     (match KBindings.find kid kid_deps with
     | deps -> deps
     | exception Not_found -> Unknown (l, "Unknown type variable " ^ string_of_kid kid))
  | NC_or (nc1,nc2)
  | NC_and (nc1,nc2)
    -> dmerge (deps_of_nc kid_deps nc1) (deps_of_nc kid_deps nc2)
  | NC_true
  | NC_false
    -> dempty

let deps_of_typ kid_deps arg_deps typ =
  deps_of_tyvars kid_deps arg_deps (tyvars_of_typ typ)

let deps_of_uvar fn_id env arg_deps = function
  | U_nexp (Nexp_aux (Nexp_var kid,_))
      when List.exists (fun k -> Kid.compare kid k == 0) env.top_kids ->
     Parents (CallerKidSet.singleton (fn_id,kid))
  | U_nexp nexp -> InFun (deps_of_nexp env.kid_deps arg_deps nexp)
  | U_order _ -> InFun dempty
  | U_typ typ -> InFun (deps_of_typ env.kid_deps arg_deps typ)

let mk_subrange_pattern vannot vstart vend =
  let (_,len,ord,typ) = vector_typ_args_of (Env.base_typ_of (env_of_annot vannot) (typ_of_annot vannot)) in
  match ord with
  | Ord_aux (Ord_var _,_) -> None
  | Ord_aux (ord',_) ->
     let vstart,vend = if ord' = Ord_inc then vstart,vend else vend,vstart
     in
     let dummyl = Generated Unknown in
     match len with
     | Nexp_aux (Nexp_constant len,_) -> 
        Some (fun pat ->
          let end_len = Big_int.pred (Big_int.sub len vend) in
          (* Wrap pat in its type; in particular the type checker won't
             manage P_wild in the middle of a P_vector_concat *)
          let pat = P_aux (P_typ (pat_typ_of pat, pat),(Generated (pat_loc pat),None)) in
          let pats = if Big_int.greater end_len Big_int.zero then
              [pat;P_aux (P_typ (vector_typ (nconstant end_len) ord typ,
                                 P_aux (P_wild,(dummyl,None))),(dummyl,None))]
            else [pat]
          in
          let pats = if Big_int.greater vstart Big_int.zero then
              (P_aux (P_typ (vector_typ (nconstant vstart) ord typ,
                             P_aux (P_wild,(dummyl,None))),(dummyl,None)))::pats
            else pats
          in
          let pats = if ord' = Ord_inc then pats else List.rev pats
          in
          P_aux (P_vector_concat pats,(Generated (fst vannot),None)))
     | _ -> None

(* If the expression matched on in a case expression is a function argument,
   and has no other dependencies, we can try to use the pattern match directly
   rather than doing a full case split. *)
let refine_dependency env (E_aux (e,(l,annot)) as exp) pexps =
  let check_dep id ctx =
    match Bindings.find id env.var_deps with
    | Have (args,extras) -> begin
      match ArgSplits.bindings args, ExtraSplits.bindings extras with
      | [(id',loc),Total], [] when Id.compare id id' == 0 ->
         (match Util.map_all (function
         | Pat_aux (Pat_exp (pat,_),_) -> Some (ctx pat)
         | Pat_aux (Pat_when (_,_,_),_) -> None) pexps
          with
          | Some pats ->
             if l = Parse_ast.Unknown then
               (Reporting_basic.print_error
                  (Reporting_basic.Err_general
                     (l, "No location for pattern match: " ^ string_of_exp exp));
                None)
             else
               Some (Have (ArgSplits.singleton (id,loc) (Partial (pats,l)),
                           ExtraSplits.empty))
          | None -> None)
      | _ -> None
    end
    | Unknown _ -> None
    | exception Not_found -> None
  in
  match e with
  | E_id id -> check_dep id (fun x -> x)
  | E_app (fn_id, [E_aux (E_id id,vannot);
                   E_aux (E_lit (L_aux (L_num vstart,_)),_);
                   E_aux (E_lit (L_aux (L_num vend,_)),_)])
      when is_id (env_of exp) (Id "vector_subrange") fn_id ->
     (match mk_subrange_pattern vannot vstart vend with
     | Some mk_pat -> check_dep id mk_pat
     | None -> None)
  | _ -> None

let simplify_size_nexp env typ_env (Nexp_aux (ne,l) as nexp) =
  let is_equal kid =
    prove typ_env (NC_aux (NC_equal (Nexp_aux (Nexp_var kid,Unknown), nexp),Unknown))
  in
  match ne with
  | Nexp_var _
  | Nexp_constant _ -> nexp
  | _ ->
     match List.find is_equal env.top_kids with
     | kid -> Nexp_aux (Nexp_var kid,Generated l)
     | exception Not_found -> nexp

(* Takes an environment of dependencies on vars, type vars, and flow control,
   and dependencies on mutable variables.  The latter are quite conservative,
   we currently drop variables assigned inside loops, for example. *)

let rec analyse_exp fn_id env assigns (E_aux (e,(l,annot)) as exp) =
  let remove_assigns es message =
    let assigned = assigned_vars_exps es in
    IdSet.fold
      (fun id asn ->
        Bindings.add id (Unknown (l, string_of_id id ^ message)) asn)
      assigned assigns
  in
  let non_det es =
    let assigns = remove_assigns es " assigned in non-deterministic expressions" in
    let deps, _, rs = split3 (List.map (analyse_exp fn_id env assigns) es) in
    (deps, assigns, List.fold_left merge empty rs)
  in
  let merge_deps deps = List.fold_left dmerge dempty deps in
  let deps, assigns, r =
    match e with
    | E_block es ->
       let rec aux assigns = function
         | [] -> (dempty, assigns, empty)
         | [e] -> analyse_exp fn_id env assigns e
         | e::es ->
            let _, assigns, r' = analyse_exp fn_id env assigns e in
            let d, assigns, r = aux assigns es in
            d, assigns, merge r r'
       in
       aux assigns es
    | E_nondet es ->
       let _, assigns, r = non_det es in
       (dempty, assigns, r)
    | E_id id ->
       begin 
         match Bindings.find id env.var_deps with
         | args -> (args,assigns,empty)
         | exception Not_found ->
            match Bindings.find id assigns with
            | args -> (args,assigns,empty)
            | exception Not_found ->
               match Env.lookup_id id (Type_check.env_of_annot (l,annot)) with
               | Enum _ | Union _ -> dempty,assigns,empty
               | Register _ -> Unknown (l, string_of_id id ^ " is a register"),assigns,empty
               | _ ->
                  Unknown (l, string_of_id id ^ " is not in the environment"),assigns,empty
       end
    | E_lit _ -> (dempty,assigns,empty)
    | E_cast (_,e) -> analyse_exp fn_id env assigns e
    | E_app (id,args) ->
       let deps, assigns, r = non_det args in
       let (_,fn_typ) = Env.get_val_spec id (env_of_annot (l,annot)) in
       let fn_effect = match fn_typ with
         | Typ_aux (Typ_fn (_,_,eff),_) -> eff
         | _ -> Effect_aux (Effect_set [],Unknown)
       in
       let eff_dep = match fn_effect with
         | Effect_aux (Effect_set ([] | [BE_aux (BE_undef,_)]),_) -> dempty
         | _ -> Unknown (l, "Effects from function application")
       in
       let kid_inst = instantiation_of exp in
       (* Change kids in instantiation to the canonical ones from the type signature *)
       let kid_inst = KBindings.fold (fun kid -> KBindings.add (orig_kid kid)) kid_inst KBindings.empty in
       let kid_deps = KBindings.map (deps_of_uvar fn_id env deps) kid_inst in
       let rdep,r' =
         if Id.compare fn_id id == 0 then
           let bad = Unknown (l,"Recursive call of " ^ string_of_id id) in
           let kid_deps = KBindings.map (fun _ -> InFun bad) kid_deps in
           bad, { empty with split_on_call = Bindings.singleton id kid_deps }
         else
           dempty, { empty with split_on_call = Bindings.singleton id kid_deps } in
       (merge_deps (rdep::eff_dep::deps), assigns, merge r r')
    | E_tuple es
    | E_list es ->
       let deps, assigns, r = non_det es in
       (merge_deps deps, assigns, r)
    | E_if (e1,e2,e3) ->
       let d1,assigns,r1 = analyse_exp fn_id env assigns e1 in
       let d2,a2,r2 = analyse_exp fn_id env assigns e2 in
       let d3,a3,r3 = analyse_exp fn_id env assigns e3 in
       let assigns = add_dep_to_assigned d1 (dep_bindings_merge a2 a3) [e2;e3] in
       (dmerge d1 (dmerge d2 d3), assigns, merge r1 (merge r2 r3))
    | E_loop (_,e1,e2) ->
       (* We remove all of the variables assigned in the loop, so we don't
          need to add control dependencies *)
       let assigns = remove_assigns [e1;e2] " assigned in a loop" in
       let d1,a1,r1 = analyse_exp fn_id env assigns e1 in
       let d2,a2,r2 = analyse_exp fn_id env assigns e2 in
     (dempty, assigns, merge r1 r2)
    | E_for (var,efrom,eto,eby,ord,body) ->
       let d1,assigns,r1 = non_det [efrom;eto;eby] in
       let assigns = remove_assigns [body] " assigned in a loop" in
       let d = merge_deps d1 in
       let loop_kid = mk_kid ("loop_" ^ string_of_id var) in
       let env' = { env with
         kid_deps = KBindings.add loop_kid d env.kid_deps} in
       let d2,a2,r2 = analyse_exp fn_id env' assigns body in
       (dempty, assigns, merge r1 r2)
    | E_vector es ->
       let ds, assigns, r = non_det es in
       (merge_deps ds, assigns, r)
    | E_vector_access (e1,e2)
    | E_vector_append (e1,e2)
    | E_cons (e1,e2) ->
       let ds, assigns, r = non_det [e1;e2] in
       (merge_deps ds, assigns, r)
    | E_vector_subrange (e1,e2,e3)
    | E_vector_update (e1,e2,e3) ->
       let ds, assigns, r = non_det [e1;e2;e3] in
       (merge_deps ds, assigns, r)
    | E_vector_update_subrange (e1,e2,e3,e4) ->
       let ds, assigns, r = non_det [e1;e2;e3;e4] in
       (merge_deps ds, assigns, r)
    | E_record (FES_aux (FES_Fexps (fexps,_),_)) ->
       let es = List.map (function (FE_aux (FE_Fexp (_,e),_)) -> e) fexps in
       let ds, assigns, r = non_det es in
       (merge_deps ds, assigns, r)
    | E_record_update (e,FES_aux (FES_Fexps (fexps,_),_)) ->
       let es = List.map (function (FE_aux (FE_Fexp (_,e),_)) -> e) fexps in
       let ds, assigns, r = non_det (e::es) in
       (merge_deps ds, assigns, r)
    | E_field (e,_) -> analyse_exp fn_id env assigns e
    | E_case (e,cases) ->
       let deps,assigns,r = analyse_exp fn_id env assigns e in
       let deps = match refine_dependency env e cases with
         | Some deps -> deps
         | None -> deps
       in
       let analyse_case (Pat_aux (pexp,_)) =
         match pexp with
         | Pat_exp (pat,e1) ->
            let env = update_env env deps pat in
            let d,assigns,r = analyse_exp fn_id env assigns e1 in
            let assigns = add_dep_to_assigned deps assigns [e1] in
            (d,assigns,r)
         | Pat_when (pat,e1,e2) ->
            let env = update_env env deps pat in
            let d1,assigns,r1 = analyse_exp fn_id env assigns e1 in
            let d2,assigns,r2 = analyse_exp fn_id env assigns e2 in
            let assigns = add_dep_to_assigned deps assigns [e1;e2] in
            (dmerge d1 d2, assigns, merge r1 r2)
       in
       let ds,assigns,rs = split3 (List.map analyse_case cases) in
       (merge_deps (deps::ds),
        List.fold_left dep_bindings_merge Bindings.empty assigns,
        List.fold_left merge r rs)
    | E_let (LB_aux (LB_val (pat,e1),_),e2) ->
       let d1,assigns,r1 = analyse_exp fn_id env assigns e1 in
       let env = update_env env d1 pat in
       let d2,assigns,r2 = analyse_exp fn_id env assigns e2 in
       (d2,assigns,merge r1 r2)
    | E_assign (lexp,e1) ->
       let d1,assigns,r1 = analyse_exp fn_id env assigns e1 in
       let assigns,r2 = analyse_lexp fn_id env assigns d1 lexp in
       (dempty, assigns, merge r1 r2)
    | E_sizeof nexp ->
       (deps_of_nexp env.kid_deps [] nexp, assigns, empty)
    | E_return e
    | E_exit e
    | E_throw e ->
       let _, _, r = analyse_exp fn_id env assigns e in
       (dempty, Bindings.empty, r)
    | E_try (e,cases) ->
       let deps,_,r = analyse_exp fn_id env assigns e in
       let assigns = remove_assigns [e] " assigned in try expression" in
       let analyse_handler (Pat_aux (pexp,_)) =
         match pexp with
         | Pat_exp (pat,e1) ->
            let env = update_env env (Unknown (l,"Exception")) pat in
            let d,assigns,r = analyse_exp fn_id env assigns e1 in
            let assigns = add_dep_to_assigned deps assigns [e1] in
            (d,assigns,r)
         | Pat_when (pat,e1,e2) ->
            let env = update_env env (Unknown (l,"Exception")) pat in
            let d1,assigns,r1 = analyse_exp fn_id env assigns e1 in
            let d2,assigns,r2 = analyse_exp fn_id env assigns e2 in
            let assigns = add_dep_to_assigned deps assigns [e1;e2] in
            (dmerge d1 d2, assigns, merge r1 r2)
       in
       let ds,assigns,rs = split3 (List.map analyse_handler cases) in
       (merge_deps (deps::ds),
        List.fold_left dep_bindings_merge Bindings.empty assigns,
        List.fold_left merge r rs)
    | E_assert (e1,_) -> analyse_exp fn_id env assigns e1

    | E_app_infix _
    | E_internal_cast _
    | E_internal_exp _
    | E_sizeof_internal _
    | E_internal_exp_user _
    | E_comment _
    | E_comment_struc _
    | E_internal_plet _
    | E_internal_return _
      -> raise (Reporting_basic.err_unreachable l
                  ("Unexpected expression encountered in monomorphisation: " ^ string_of_exp exp))
       
    | E_var (lexp,e1,e2) ->
       (* Really we ought to remove the assignment after e2 *)
       let d1,assigns,r1 = analyse_exp fn_id env assigns e1 in
       let assigns,r' = analyse_lexp fn_id env assigns d1 lexp in
       let d2,assigns,r2 = analyse_exp fn_id env assigns e2 in
       (dempty, assigns, merge r1 (merge r' r2))
    | E_constraint nc ->
       (deps_of_nc env.kid_deps nc, assigns, empty)
  in
  let r =
    (* Check for bitvector types with parametrised sizes *)
    match annot with
    | None -> r
    | Some (tenv,typ,_) ->
       let typ = Env.base_typ_of tenv typ in
       let env, typ =
         match destruct_exist tenv typ with
         | None -> env, typ
         | Some (kids, nc, typ) ->
            { env with kid_deps =
                List.fold_left (fun kds kid -> KBindings.add kid deps kds) env.kid_deps kids },
            typ
       in
       if is_bitvector_typ typ then
         let _,size,_,_ = vector_typ_args_of typ in
         let Nexp_aux (size,_) as size_nexp = simplify_size_nexp env tenv size in
         let is_tyvar_parameter v =
           List.exists (fun k -> Kid.compare k v == 0) env.top_kids
         in
         match size with
         | Nexp_constant _ -> r
         | Nexp_var v when is_tyvar_parameter v ->
             { r with kid_in_caller = CallerKidSet.add (fn_id,v) r.kid_in_caller }
         | _ ->
             match deps_of_nexp env.kid_deps [] size_nexp with
             | Have (args,extras) ->
                { r with
                  split = ArgSplits.merge merge_detail r.split args;
                  extra_splits = merge_extras r.extra_splits extras
                }
             | Unknown (l,msg) ->
                { r with
                  failures =
                    Failures.add l (StringSet.singleton ("Unable to monomorphise " ^ string_of_nexp size_nexp ^ ": " ^ msg))
                      r.failures }
       else
         r
  in (deps, assigns, r)


and analyse_lexp fn_id env assigns deps (LEXP_aux (lexp,_)) =
 (* TODO: maybe subexps and sublexps should be non-det (and in const_prop_lexp, too?) *)
 match lexp with
  | LEXP_id id
  | LEXP_cast (_,id) ->
     Bindings.add id deps assigns, empty
  | LEXP_memory (id,es) ->
     let _, assigns, r = analyse_exp fn_id env assigns (E_aux (E_tuple es,(Unknown,None))) in
     assigns, r
  | LEXP_tup lexps ->
      List.fold_left (fun (assigns,r) lexp ->
       let assigns,r' = analyse_lexp fn_id env assigns deps lexp
       in assigns,merge r r') (assigns,empty) lexps
  | LEXP_vector (lexp,e) ->
     let _, assigns, r1 = analyse_exp fn_id env assigns e in
     let assigns, r2 = analyse_lexp fn_id env assigns deps lexp in
     assigns, merge r1 r2
  | LEXP_vector_range (lexp,e1,e2) ->
     let _, assigns, r1 = analyse_exp fn_id env assigns e1 in
     let _, assigns, r2 = analyse_exp fn_id env assigns e2 in
     let assigns, r3 = analyse_lexp fn_id env assigns deps lexp in
     assigns, merge r3 (merge r1 r2)
  | LEXP_field (lexp,_) -> analyse_lexp fn_id env assigns deps lexp


let rec translate_loc l =
  match l with
  | Range (pos,_) -> Some (pos.Lexing.pos_fname,pos.Lexing.pos_lnum)
  | Generated l -> translate_loc l
  | _ -> None

let initial_env fn_id fn_l (TypQ_aux (tq,_)) pat set_assertions =
  let pats = 
    match pat with
    | P_aux (P_tup pats,_) -> pats
    | _ -> [pat]
  in
  (* For the type in an annotation, produce the corresponding tyvar (if any),
     and a default case split (a set if there's one, a full case split if not). *)
  let kids_of_annot annot =
    let env = env_of_annot annot in
    let Typ_aux (typ,_) = Env.base_typ_of env (typ_of_annot annot) in
    match typ with
    | Typ_app (Id_aux (Id "atom",_),[Typ_arg_aux (Typ_arg_nexp (Nexp_aux (Nexp_var kid,_)),_)]) ->
       equal_kids env kid
    | _ -> KidSet.empty
  in
  let default_split annot kids =
    let kids = KidSet.elements kids in
    let try_kid kid = try Some (KBindings.find kid set_assertions) with Not_found -> None in
    match Util.option_first try_kid kids with
    | Some (l,is) ->
       let l' = Generated l in
       let pats = List.map (fun n -> P_aux (P_lit (L_aux (L_num n,l')),(l',annot))) is in
       let pats = pats @ [P_aux (P_wild,(l',annot))] in
       Partial (pats,l)
    | None -> Total
  in
  let arg i pat =
    let rec aux (P_aux (p,(l,annot))) =
      let of_list pats =
        let ss,vs,ks = split3 (List.map aux pats) in
        let s = List.fold_left (ArgSplits.merge merge_detail) ArgSplits.empty ss in
        let v = List.fold_left dep_bindings_merge Bindings.empty vs in
        let k = List.fold_left dep_kbindings_merge KBindings.empty ks in
        s,v,k
      in
      match p with
      | P_lit _
      | P_wild
        -> ArgSplits.empty,Bindings.empty,KBindings.empty
      | P_as (pat,id) ->
         begin
           let s,v,k = aux pat in
           match translate_loc (id_loc id) with
           | Some loc ->
              ArgSplits.add (id,loc) Total s,
              Bindings.add id (Have (ArgSplits.singleton (id,loc) Total, ExtraSplits.empty)) v,
              k
           | None ->
              s,
              Bindings.add id (Unknown (l, ("Unable to give location for " ^ string_of_id id))) v,
              k
         end
      | P_typ (_,pat) -> aux pat
      | P_id id ->
         begin
         match translate_loc (id_loc id) with
         | Some loc ->
            let kids = kids_of_annot (l,annot) in
            let split = default_split annot kids in
            let s = ArgSplits.singleton (id,loc) split in
            s,
            Bindings.singleton id (Have (s, ExtraSplits.empty)),
            KidSet.fold (fun kid k -> KBindings.add kid (Have (s, ExtraSplits.empty)) k) kids KBindings.empty
         | None ->
            ArgSplits.empty,
            Bindings.singleton id (Unknown (l, ("Unable to give location for " ^ string_of_id id))),
            KBindings.empty
         end
      | P_var (pat, TP_aux (TP_var kid, _)) ->
         let s,v,k = aux pat in
         let kids = equal_kids (env_of_annot (l,annot)) kid in
         s,v,KidSet.fold (fun kid k -> KBindings.add kid (Have (s, ExtraSplits.empty)) k) kids k
      | P_app (_,pats) -> of_list pats
      | P_record (fpats,_) -> of_list (List.map (fun (FP_aux (FP_Fpat (_,p),_)) -> p) fpats)
      | P_vector pats
      | P_vector_concat pats
      | P_tup pats
      | P_list pats
        -> of_list pats
      | P_cons (p1,p2) -> of_list [p1;p2]
    in aux pat
  in
  let quant = function
    | QI_aux (QI_id (KOpt_aux ((KOpt_none kid | KOpt_kind (_,kid)),_)),_) ->
       Some kid
    | QI_aux (QI_const _,_) -> None
  in
  let top_kids =
    match tq with
    | TypQ_no_forall -> []
    | TypQ_tq qs -> Util.map_filter quant qs
  in
  let _,var_deps,kid_deps = split3 (List.mapi arg pats) in
  let var_deps = List.fold_left dep_bindings_merge Bindings.empty var_deps in
  let kid_deps = List.fold_left dep_kbindings_merge KBindings.empty kid_deps in
  let note_no_arg kid_deps kid =
    if KBindings.mem kid kid_deps then kid_deps
    else
      (* When there's no argument to case split on for a kid, we'll add a
         case expression instead *)
      let env = pat_env_of pat in
      let split = default_split (Some (env,int_typ,no_effect)) (KidSet.singleton kid) in
      let extra_splits = ExtraSplits.singleton (fn_id, fn_l)
        (KBindings.singleton kid split) in
      KBindings.add kid (Have (ArgSplits.empty, extra_splits)) kid_deps
  in
  let kid_deps = List.fold_left note_no_arg kid_deps top_kids in
  { top_kids = top_kids; var_deps = var_deps; kid_deps = kid_deps }

(* When there's more than one pick the first *)
let merge_set_asserts _ x y =
  match x, y with
  | None, _ -> y
  | _, _ -> x
let merge_set_asserts_by_kid sets1 sets2 =
  KBindings.merge merge_set_asserts sets1 sets2

(* Set constraints in assertions don't always use the set syntax, so we also
   handle assert('N == 1 | ...) style set constraints *)
let rec sets_from_assert e =
  let set_from_or_exps (E_aux (_,(l,_)) as e) =
    let mykid = ref None in
    let check_kid kid =
      match !mykid with
      | None -> mykid := Some kid
      | Some kid' -> if Kid.compare kid kid' == 0 then ()
        else raise Not_found
    in
    let rec aux (E_aux (e,_)) =
      match e with
      | E_app (Id_aux (Id "or_bool",_),[e1;e2]) ->
         aux e1 @ aux e2
      | E_app (Id_aux (Id "eq_atom",_),
               [E_aux (E_sizeof (Nexp_aux (Nexp_var kid,_)),_);
                E_aux (E_lit (L_aux (L_num i,_)),_)]) ->
         (check_kid kid; [i])
      | _ -> raise Not_found
    in try
         let is = aux e in
         match !mykid with
         | None -> KBindings.empty
         | Some kid -> KBindings.singleton kid (l,is)
      with Not_found -> KBindings.empty
  in
  let rec sets_from_nc (NC_aux (nc,l)) =
    match nc with
    | NC_and (nc1,nc2) -> merge_set_asserts_by_kid (sets_from_nc nc1) (sets_from_nc nc2)
    | NC_set (kid,is) -> KBindings.singleton kid (l,is)
    | _ -> KBindings.empty
  in
  match e with
  | E_aux (E_app (Id_aux (Id "and_bool",_),[e1;e2]),_) ->
     merge_set_asserts_by_kid (sets_from_assert e1) (sets_from_assert e2)
  | E_aux (E_constraint nc,_) -> sets_from_nc nc
  | _ -> set_from_or_exps e

(* Find all the easily reached set assertions in a function body, to use as
   case splits.  Note that this should be mirrored in stop_at_false_assertions,
   above. *)
let rec find_set_assertions (E_aux (e,_)) =
  match e with
  | E_block es
  | E_nondet es ->
     List.fold_left merge_set_asserts_by_kid KBindings.empty (List.map find_set_assertions es)
  | E_cast (_,e) -> find_set_assertions e
  | E_let (LB_aux (LB_val (p,e1),_),e2) ->
     let sets1 = find_set_assertions e1 in
     let sets2 = find_set_assertions e2 in
     let kbound = kids_bound_by_pat p in
     let sets2 = KBindings.filter (fun kid _ -> not (KidSet.mem kid kbound)) sets2 in
     merge_set_asserts_by_kid sets1 sets2
  | E_assert (exp1,_) -> sets_from_assert exp1
  | _ -> KBindings.empty

let print_set_assertions set_assertions =
  if KBindings.is_empty set_assertions then
    print_endline "No top-level set assertions found."
  else begin
    print_endline "Top-level set assertions found:";
    KBindings.iter (fun k (l,is) ->
      print_endline (string_of_kid k ^ " " ^
                       String.concat "," (List.map Big_int.to_string is)))
      set_assertions
  end

let print_result r =
  let _ = print_endline ("  splits: " ^ string_of_argsplits r.split) in
  let print_kbinding kid dep =
    let s = match dep with
      | InFun dep -> "InFun " ^ string_of_dep dep
      | Parents cks -> string_of_callerkidset cks
    in
    let _ = print_endline ("      " ^ string_of_kid kid ^ ": " ^ s) in
    ()
  in
  let print_binding id kdep =
    let _ = print_endline ("    " ^ string_of_id id ^ ":") in
    let _ = KBindings.iter print_kbinding kdep in
    ()
  in
  let _ = print_endline "  split_on_call: " in
  let _ = Bindings.iter print_binding r.split_on_call in
  let _ = print_endline ("  kid_in_caller: " ^ string_of_callerkidset r.kid_in_caller) in
  let _ = print_endline ("  failures: \n    " ^
                            (String.concat "\n    "
                               (List.map (fun (l,s) -> Reporting_basic.loc_to_string l ^ ":\n     " ^
                                 String.concat "\n      " (StringSet.elements s))
                                  (Failures.bindings r.failures)))) in
  ()

let analyse_funcl debug tenv (FCL_aux (FCL_Funcl (id,pexp),(l,_))) =
  let _ = if debug > 2 then print_endline (string_of_id id) else () in
  let pat,guard,body,_ = destruct_pexp pexp in
  let (tq,_) = Env.get_val_spec id tenv in
  let set_assertions = find_set_assertions body in
  let _ = if debug > 2 then print_set_assertions set_assertions in
  let aenv = initial_env id l tq pat set_assertions in
  let _,_,r = analyse_exp id aenv Bindings.empty body in
  let r = match guard with
    | None -> r
    | Some exp -> let _,_,r' = analyse_exp id aenv Bindings.empty exp in
                  let r' =
                    if ExtraSplits.is_empty r'.extra_splits
                    then r'
                    else merge r' { empty with failures =
                        Failures.singleton l (StringSet.singleton
                                                "Case splitting size tyvars in guards not supported") }
                  in
                  merge r r'
  in
  let _ = if debug > 2 then print_result r else ()
  in r

let analyse_def debug env = function
  | DEF_fundef (FD_aux (FD_function (_,_,_,funcls),_)) ->
     List.fold_left (fun r f -> merge r (analyse_funcl debug env f)) empty funcls

  | _ -> empty

let detail_to_split = function
  | Total -> None
  | Partial (pats,l) -> Some (pats,l)

let argset_to_list splits =
  let l = ArgSplits.bindings splits in
  let argelt  = function
    | ((id,(file,loc)),detail) -> ((file,loc),string_of_id id,detail_to_split detail)
  in
  List.map argelt l

let analyse_defs debug env (Defs defs) =
  let r = List.fold_left (fun r d -> merge r (analyse_def debug env d)) empty defs in

  (* Resolve the interprocedural dependencies *)

  let rec separate_deps = function
    | Have (splits, extras) ->
       splits, extras, Failures.empty
    | Unknown (l,msg) ->
       ArgSplits.empty, ExtraSplits.empty,
      Failures.singleton l (StringSet.singleton ("Unable to monomorphise dependency: " ^ msg))
  and chase_kid_caller (id,kid) =
    match Bindings.find id r.split_on_call with
    | kid_deps -> begin
      match KBindings.find kid kid_deps with
      | InFun deps -> separate_deps deps
      | Parents fns -> CallerKidSet.fold add_kid fns (ArgSplits.empty, ExtraSplits.empty, Failures.empty)
      | exception Not_found -> ArgSplits.empty,ExtraSplits.empty,Failures.empty
    end
    | exception Not_found -> ArgSplits.empty,ExtraSplits.empty,Failures.empty
  and add_kid k (splits,extras,fails) =
    let splits',extras',fails' = chase_kid_caller k in
    ArgSplits.merge merge_detail splits splits',
    merge_extras extras extras',
    Failures.merge failure_merge fails fails'
  in
  let _ = if debug > 1 then print_result r else () in
  let splits,extras,fails = CallerKidSet.fold add_kid r.kid_in_caller (r.split,r.extra_splits,r.failures) in
  let _ =
    if debug > 0 then
      (print_endline "Final splits:";
       print_endline (string_of_argsplits splits);
       print_endline (string_of_extra_splits extras))
    else ()
  in
  let splits = argset_to_list splits in
  if Failures.is_empty fails 
  then (true,splits,extras) else
    begin
      Failures.iter (fun l msgs ->
        Reporting_basic.print_err false false l "Monomorphisation" (String.concat "\n" (StringSet.elements msgs)))
        fails;
      (false, splits,extras)
    end

end

let fresh_sz_var =
  let counter = ref 0 in
  fun () ->
    let n = !counter in
    let () = counter := n+1 in
    mk_id ("sz#" ^ string_of_int n)

let add_extra_splits extras (Defs defs) =
  let success = ref true in
  let add_to_body extras (E_aux (_,(l,annot)) as e) =
    let l' = Generated l in
    KBindings.fold (fun kid detail (exp,split_list) ->
         let nexp = Nexp_aux (Nexp_var kid,l) in
         let var = fresh_sz_var () in
         let size_annot = Some (env_of e,atom_typ nexp,no_effect) in
         let loc = match Analysis.translate_loc l with
           | Some l -> l
           | None ->
              (Reporting_basic.print_err false false l "Monomorphisation"
                 "Internal error: bad location for added case";
               ("",0))
         in
         let pexps = [Pat_aux (Pat_exp (P_aux (P_id var,(l,size_annot)),exp),(l',annot))] in
         E_aux (E_case (E_aux (E_sizeof nexp, (l',size_annot)), pexps),(l',annot)),
         ((loc, string_of_id var, Analysis.detail_to_split detail)::split_list)
    ) extras (e,[])
  in
  let add_to_funcl (FCL_aux (FCL_Funcl (id,Pat_aux (pexp,peannot)),(l,annot))) =
    let pexp, splits = 
      match Analysis.ExtraSplits.find (id,l) extras with
      | extras ->
         (match pexp with
         | Pat_exp (p,e) -> let e',sp = add_to_body extras e in Pat_exp (p,e'), sp
         | Pat_when (p,g,e) -> let e',sp = add_to_body extras e in Pat_when (p,g,e'), sp)
      | exception Not_found -> pexp, []
    in FCL_aux (FCL_Funcl (id,Pat_aux (pexp,peannot)),(l,annot)), splits
  in
  let add_to_def = function
    | DEF_fundef (FD_aux (FD_function (re,ta,ef,funcls),annot)) ->
       let funcls,splits = List.split (List.map add_to_funcl funcls) in
       DEF_fundef (FD_aux (FD_function (re,ta,ef,funcls),annot)), List.concat splits
    | d -> d, []
  in 
  let defs, splits = List.split (List.map add_to_def defs) in
  !success, Defs defs, List.concat splits

module MonoRewrites =
struct

let is_constant_range = function
  | E_aux (E_lit _,_), E_aux (E_lit _,_) -> true
  | _ -> false

let is_constant = function
  | E_aux (E_lit _,_) -> true
  | _ -> false

let is_constant_vec_typ env typ =
  let typ = Env.base_typ_of env typ in
  match destruct_vector env typ with
  | Some (size,_,_) ->
     (match nexp_simp size with
     | Nexp_aux (Nexp_constant _,_) -> true
     | _ -> false)
  | _ -> false

(* We have to add casts in here with appropriate length information so that the
   type checker knows the expected return types. *)

let rewrite_app env typ (id,args) =
  let is_append = is_id env (Id "append") in
  if is_append id then
    let is_subrange = is_id env (Id "vector_subrange") in
    let is_slice = is_id env (Id "slice") in
    let is_zeros = is_id env (Id "Zeros") in
    match args with
      (* (known-size-vector @ variable-vector) @ variable-vector *)
    | [E_aux (E_app (append,
              [e1;
               E_aux (E_app (subrange1,
                             [vector1; start1; end1]),_)]),_);
       E_aux (E_app (subrange2,
                     [vector2; start2; end2]),_)]
        when is_append append && is_subrange subrange1 && is_subrange subrange2 &&
          is_constant_vec_typ env (typ_of e1) &&
          not (is_constant_range (start1, end1) || is_constant_range (start2, end2)) ->
       let (start,size,order,bittyp) = vector_typ_args_of (Env.base_typ_of env typ) in
       let (_,size1,_,_) = vector_typ_args_of (Env.base_typ_of env (typ_of e1)) in
       let midsize = nminus size size1 in
       let midtyp = vector_typ midsize order bittyp in
       E_app (append,
              [e1;
               E_aux (E_cast (midtyp,
                              E_aux (E_app (mk_id "subrange_subrange_concat",
                                            [vector1; start1; end1; vector2; start2; end2]),
                                     (Unknown,None))),(Unknown,None))])
    | [E_aux (E_app (append,
              [e1;
               E_aux (E_app (slice1,
                             [vector1; start1; length1]),_)]),_);
       E_aux (E_app (slice2,
                     [vector2; start2; length2]),_)]
        when is_append append && is_slice slice1 && is_slice slice2 &&
          is_constant_vec_typ env (typ_of e1) &&
          not (is_constant length1 || is_constant length2) ->
       let (start,size,order,bittyp) = vector_typ_args_of (Env.base_typ_of env typ) in
       let (_,size1,_,_) = vector_typ_args_of (Env.base_typ_of env (typ_of e1)) in
       let midsize = nminus size size1 in
       let midtyp = vector_typ midsize order bittyp in
       E_app (append,
              [e1;
               E_aux (E_cast (midtyp,
                              E_aux (E_app (mk_id "slice_slice_concat",
                                            [vector1; start1; length1; vector2; start2; length2]),
                                     (Unknown,None))),(Unknown,None))])

    (* variable-range @ variable-range *)
    | [E_aux (E_app (subrange1,
                     [vector1; start1; end1]),_);
       E_aux (E_app (subrange2,
                     [vector2; start2; end2]),_)]
        when is_subrange subrange1 && is_subrange subrange2 &&
          not (is_constant_range (start1, end1) || is_constant_range (start2, end2)) ->
       E_cast (typ,
               E_aux (E_app (mk_id "subrange_subrange_concat",
                             [vector1; start1; end1; vector2; start2; end2]),
                      (Unknown,None)))

    (* variable-slice @ variable-slice *)
    | [E_aux (E_app (slice1,
                     [vector1; start1; length1]),_);
       E_aux (E_app (slice2,
                     [vector2; start2; length2]),_)]
        when is_slice slice1 && is_slice slice2 &&
          not (is_constant length1 || is_constant length2) ->
       E_cast (typ,
               E_aux (E_app (mk_id "slice_slice_concat",
                             [vector1; start1; length1; vector2; start2; length2]),(Unknown,None)))

    | [E_aux (E_app (append1,
                     [e1;
                      E_aux (E_app (slice1, [vector1; start1; length1]),_)]),_);
       E_aux (E_app (zeros1, [length2]),_)]
        when is_append append1 && is_slice slice1 && is_zeros zeros1 &&
          is_constant_vec_typ env (typ_of e1) &&
          not (is_constant length1 || is_constant length2) ->
       let (start,size,order,bittyp) = vector_typ_args_of (Env.base_typ_of env typ) in
       let (_,size1,_,_) = vector_typ_args_of (Env.base_typ_of env (typ_of e1)) in
       let midsize = nminus size size1 in
       let midtyp = vector_typ midsize order bittyp in
       E_cast (typ,
               E_aux (E_app (mk_id "append",
                             [e1;
                              E_aux (E_cast (midtyp,
                                             E_aux (E_app (mk_id "slice_zeros_concat",
                                                           [vector1; start1; length1; length2]),(Unknown,None))),(Unknown,None))]),
                      (Unknown,None)))

    | _ -> E_app (id,args)

  else if is_id env (Id "eq_vec") id then
    (* variable-range == variable_range *)
    let is_subrange = is_id env (Id "vector_subrange") in
    match args with
    | [E_aux (E_app (subrange1,
                     [vector1; start1; end1]),_);
       E_aux (E_app (subrange2,
                     [vector2; start2; end2]),_)]
        when is_subrange subrange1 && is_subrange subrange2 &&
          not (is_constant_range (start1, end1) || is_constant_range (start2, end2)) ->
       E_app (mk_id "subrange_subrange_eq",
              [vector1; start1; end1; vector2; start2; end2])
    | _ -> E_app (id,args)

  else if is_id env (Id "IsZero") id then
    match args with
    | [E_aux (E_app (subrange1, [vector1; start1; end1]),_)]
        when is_id env (Id "vector_subrange") subrange1 &&
          not (is_constant_range (start1,end1)) ->
       E_app (mk_id "is_zero_subrange",
              [vector1; start1; end1])
    | _ -> E_app (id,args)

  else if is_id env (Id "IsOnes") id then
    match args with
    | [E_aux (E_app (subrange1, [vector1; start1; end1]),_)]
        when is_id env (Id "vector_subrange") subrange1 &&
          not (is_constant_range (start1,end1)) ->
       E_app (mk_id "is_ones_subrange",
              [vector1; start1; end1])
    | _ -> E_app (id,args)

  else if is_id env (Id "Extend") id || is_id env (Id "ZeroExtend") id then
    let is_subrange = is_id env (Id "vector_subrange") in
    let is_slice = is_id env (Id "slice") in
    let is_zeros = is_id env (Id "Zeros") in
    match args with
    | (E_aux (E_app (append1,
                     [E_aux (E_app (subrange1, [vector1; start1; end1]), _);
                      E_aux (E_app (zeros1, [len1]),_)]),_))::
        ([] | [_;E_aux (E_id (Id_aux (Id "unsigned",_)),_)])
        when is_subrange subrange1 && is_zeros zeros1 && is_append append1
      -> E_app (mk_id "place_subrange",
                [vector1; start1; end1; len1])

    | (E_aux (E_app (append1,
                     [E_aux (E_app (slice1, [vector1; start1; length1]), _);
                      E_aux (E_app (zeros1, [length2]),_)]),_))::
        ([] | [_;E_aux (E_id (Id_aux (Id "unsigned",_)),_)])
        when is_slice slice1 && is_zeros zeros1 && is_append append1
      -> E_app (mk_id "place_slice",
                [vector1; start1; length1; length2])

    (* If we've already rewritten to slice_slice_concat, we can just drop the
       zero extension because it can do it *)
    | (E_aux (E_cast (_, (E_aux (E_app (Id_aux (Id "slice_slice_concat",_), args),_))),_))::
        ([] | [_;E_aux (E_id (Id_aux (Id "unsigned",_)),_)])
      -> E_app (mk_id "slice_slice_concat", args)

    | [E_aux (E_app (slice1, [vector1; start1; length1]),_)]
        when is_slice slice1 && not (is_constant length1) ->
       E_app (mk_id "zext_slice", [vector1; start1; length1])

    | [E_aux (E_app (ones, [len1]),_);
       _ (* unnecessary ZeroExtend length *)] ->
       E_app (mk_id "zext_ones", [len1])

    | _ -> E_app (id,args)

  else if is_id env (Id "SignExtend") id then
    let is_slice = is_id env (Id "slice") in
    match args with
    | [E_aux (E_app (slice1, [vector1; start1; length1]),_)]
        when is_slice slice1 && not (is_constant length1) ->
       E_app (mk_id "sext_slice", [vector1; start1; length1])

    | _ -> E_app (id,args)

  else if is_id env (Id "UInt") id then
    let is_slice = is_id env (Id "slice") in
    let is_subrange = is_id env (Id "vector_subrange") in
    match args with
    | [E_aux (E_app (slice1, [vector1; start1; length1]),_)]
        when is_slice slice1 && not (is_constant length1) ->
       E_app (mk_id "UInt_slice", [vector1; start1; length1])
    | [E_aux (E_app (subrange1, [vector1; start1; end1]),_)]
        when is_subrange subrange1 && not (is_constant_range (start1,end1)) ->
       E_app (mk_id "UInt_subrange", [vector1; start1; end1])

    | _ -> E_app (id,args)

  else E_app (id,args)

let rewrite_aux = function
  | (E_app (id,args),((_,Some (env,ty,_)) as annot)) ->
     E_aux (rewrite_app env ty (id,args),annot)
  | exp,annot -> E_aux (exp,annot)

let mono_rewrite defs =
  let open Rewriter in
  rewrite_defs_base
    { rewriters_base with
      rewrite_exp = fun _ -> fold_exp { id_exp_alg with e_aux = rewrite_aux } }
    defs
end

module BitvectorSizeCasts =
struct

(* These functions add cast functions across case splits, so that when a
   bitvector size becomes known in sail, the generated Lem code contains a
   function call to change mword 'n to (say) mword ty16, and vice versa. *)
let make_bitvector_cast_fns env src_typ target_typ =
  let genunk = Generated Unknown in
  let fresh =
    let counter = ref 0 in
    fun () ->
      let n = !counter in
      let () = counter := n+1 in
      mk_id ("cast#" ^ string_of_int n)
  in
  let required = ref false in
  let rec aux (Typ_aux (src_t,src_l) as src_typ) (Typ_aux (tar_t,tar_l) as tar_typ) =
    let src_ann = Some (env,src_typ,no_effect) in
    let tar_ann = Some (env,tar_typ,no_effect) in
    match src_t, tar_t with
    | Typ_tup typs, Typ_tup typs' ->
       let ps,es = List.split (List.map2 aux typs typs') in
       P_aux (P_tup ps,(Generated src_l, src_ann)),
       E_aux (E_tuple es,(Generated tar_l, tar_ann))
    | Typ_app (Id_aux (Id "vector",_),
               [Typ_arg_aux (Typ_arg_nexp size,_); _;
                Typ_arg_aux (Typ_arg_typ (Typ_aux (Typ_id (Id_aux (Id "bit",_)),_)),_)]),
      Typ_app (Id_aux (Id "vector",_),
               [Typ_arg_aux (Typ_arg_nexp size',_); _;
                Typ_arg_aux (Typ_arg_typ (Typ_aux (Typ_id (Id_aux (Id "bit",_)),_)),_)])
        when Nexp.compare size size' <> 0 ->
       let () = required := true in
       let var = fresh () in
       P_aux (P_id var,(Generated src_l,src_ann)),
       E_aux
         (E_cast (tar_typ,
                  E_aux (E_app (Id_aux (Id "bitvector_cast", genunk),
                                [E_aux (E_id var, (genunk, src_ann))]), (genunk, tar_ann))),
          (genunk, tar_ann))
    | _ ->
       let var = fresh () in
       P_aux (P_id var,(Generated src_l,src_ann)),
       E_aux (E_id var,(Generated src_l,tar_ann))
  in
  let src_typ' = Env.base_typ_of env src_typ in
  let target_typ' = Env.base_typ_of env target_typ in
  let pat, e' = aux src_typ' target_typ' in
  if !required
  then
    let src_ann = Some (env,src_typ,no_effect) in
    let tar_ann = Some (env,target_typ,no_effect) in
    match src_typ' with
      (* Simple case with just the bitvector; don't need to pull apart value *)
    | Typ_aux (Typ_app _,_) ->
       (fun var exp ->
         let exp_ann = Some (env,typ_of exp,effect_of exp) in
         E_aux (E_let (LB_aux (LB_val (P_aux (P_typ (target_typ, P_aux (P_id var,(genunk,tar_ann))),(genunk,tar_ann)),
                                       E_aux (E_app (Id_aux (Id "bitvector_cast",genunk),
                                                     [E_aux (E_id var,(genunk,src_ann))]),(genunk,tar_ann))),(genunk,tar_ann)),
                       exp),(genunk,exp_ann))),
      (fun (E_aux (_,(exp_l,exp_ann)) as exp) ->
        E_aux (E_cast (target_typ,
                       E_aux (E_app (Id_aux (Id "bitvector_cast", genunk), [exp]), (Generated exp_l,tar_ann))),
               (Generated exp_l,tar_ann)))
    | _ ->
       (fun var exp ->
         let exp_ann = Some (env,typ_of exp,effect_of exp) in
         E_aux (E_let (LB_aux (LB_val (pat, E_aux (E_id var,(genunk,src_ann))),(genunk,src_ann)),
                       E_aux (E_let (LB_aux (LB_val (P_aux (P_id var,(genunk,tar_ann)),e'),(genunk,tar_ann)),
                                     exp),(genunk,exp_ann))),(genunk,exp_ann))),
      (fun (E_aux (_,(exp_l,exp_ann)) as exp) ->
        E_aux (E_let (LB_aux (LB_val (pat, exp),(Generated exp_l,exp_ann)), e'),(Generated exp_l,tar_ann)))
  else (fun _ e -> e),(fun e -> e)

(* TODO: bound vars *)
let make_bitvector_env_casts env (kid,i) exp =
  let mk_cast var typ exp = (fst (make_bitvector_cast_fns env typ (subst_src_typ (KBindings.singleton kid (nconstant i)) typ))) var exp in
  let locals = Env.get_locals env in
  Bindings.fold (fun var (mut,typ) exp ->
    if mut = Immutable then mk_cast var typ exp else exp) locals exp

let make_bitvector_cast_exp typ target_typ exp = (snd (make_bitvector_cast_fns (env_of exp) typ target_typ)) exp

let rec extract_value_from_guard var (E_aux (e,_)) =
  match e with
  | E_app (op, ([E_aux (E_id var',_); E_aux (E_lit (L_aux (L_num i,_)),_)] |
                [E_aux (E_lit (L_aux (L_num i,_)),_); E_aux (E_id var',_)]))
      when string_of_id op = "eq_atom" && Id.compare var var' == 0 ->
     Some i
  | E_app (op, [e1;e2]) when string_of_id op = "and_bool" ->
     (match extract_value_from_guard var e1 with
     | Some i -> Some i
     | None -> extract_value_from_guard var e2)
  | _ -> None

let fill_in_type env typ =
  let constraints = Env.get_constraints env in
  let constraints = flatten_constraints constraints in
  let subst = Util.map_filter (function
    | NC_aux (NC_equal (Nexp_aux (Nexp_var var,_), (Nexp_aux (Nexp_constant _,_) as i)),_) -> Some (var,i)
    | NC_aux (NC_equal (Nexp_aux (Nexp_constant _,_) as i, Nexp_aux (Nexp_var var,_)),_) -> Some (var,i)
    | _ -> None) constraints in
  subst_src_typ (kbindings_from_list subst) typ

(* TODO: top-level patterns *)
let add_bitvector_casts (Defs defs) =
  let rewrite_body ret_typ exp =
    let rewrite_aux (e,ann) =
      match e with
      | E_case (E_aux (e',ann') as exp',cases) -> begin
        let env = env_of_annot ann in
        let result_typ = Env.base_typ_of env (typ_of_annot ann) in
        let matched_typ = Env.base_typ_of env (typ_of_annot ann') in
        match e',matched_typ with
        | E_sizeof (Nexp_aux (Nexp_var kid,_)), _
        | _, Typ_aux (Typ_app (Id_aux (Id "atom",_), [Typ_arg_aux (Typ_arg_nexp (Nexp_aux (Nexp_var kid,_)),_)]),_) ->
           let map_case pexp =
             let pat,guard,body,ann = destruct_pexp pexp in
             let body = match pat, guard with
               | P_aux (P_lit (L_aux (L_num i,_)),_), _ ->
                  let src_typ = subst_src_typ (KBindings.singleton kid (nconstant i)) result_typ in
                  make_bitvector_cast_exp src_typ result_typ
                    (make_bitvector_env_casts env (kid,i) body)
               | P_aux (P_id var,_), Some guard ->
                  (match extract_value_from_guard var guard with
                  | Some i ->
                     let src_typ = subst_src_typ (KBindings.singleton kid (nconstant i)) result_typ in
                     make_bitvector_cast_exp src_typ result_typ
                       (make_bitvector_env_casts env (kid,i) body)
                  | None -> body)
               | _ -> body
             in
             construct_pexp (pat, guard, body, ann)
           in
           E_aux (E_case (exp', List.map map_case cases),ann)
        | _ -> E_aux (e,ann)
      end
      | E_return e' ->
         E_aux (E_return (make_bitvector_cast_exp (fill_in_type (env_of e') (typ_of e')) ret_typ e'),ann)
      | E_assign (LEXP_aux (lexp,lexp_annot),e') ->
         E_aux (E_assign (LEXP_aux (lexp,lexp_annot),
                          make_bitvector_cast_exp (fill_in_type (env_of e') (typ_of e'))
                            (typ_of_annot lexp_annot) e'),ann)
      | _ -> E_aux (e,ann)
    in
    let open Rewriter in
    fold_exp
      { id_exp_alg with
        e_aux = rewrite_aux } exp
  in
  let rewrite_funcl (FCL_aux (FCL_Funcl (id,pexp),fcl_ann)) =
    let ret_typ =
      match typ_of_annot fcl_ann with
      | Typ_aux (Typ_fn (_,ret,_),_) -> ret
      | Typ_aux (_,l) as typ ->
         raise (Reporting_basic.err_unreachable l
                  ("Function clause must have function type: " ^ string_of_typ typ ^
                      " is not a function type"))
    in
    let pat,guard,body,annot = destruct_pexp pexp in
    let body = rewrite_body ret_typ body in
    let pexp = construct_pexp (pat,guard,body,annot) in
    FCL_aux (FCL_Funcl (id,pexp),fcl_ann)
  in
  let rewrite_def = function
    | DEF_fundef (FD_aux (FD_function (r,t,e,fcls),fd_ann)) ->
       DEF_fundef (FD_aux (FD_function (r,t,e,List.map rewrite_funcl fcls),fd_ann))
    | d -> d
  in Defs (List.map rewrite_def defs)
end

type options = {
  auto : bool;
  debug_analysis : int;
  rewrites : bool;
  rewrite_size_parameters : bool;
  all_split_errors : bool;
  continue_anyway : bool;
  dump_raw: bool
}

let recheck defs =
  let w = !Util.opt_warnings in
  let () = Util.opt_warnings := false in
  let r = Type_check.check (Type_check.Env.no_casts Type_check.initial_env) defs in
  let () = Util.opt_warnings := w in
  r

let monomorphise opts splits env defs =
  let (defs,env) =
    if opts.rewrites then
      let defs = MonoRewrites.mono_rewrite defs in
    (* TODO: is this necessary? *)
      recheck defs
    else (defs,env)
  in
(*let _ = Pretty_print.pp_defs stdout defs in*)
  let ok_analysis, new_splits, extra_splits =
    if opts.auto
    then
      let f,r,ex = Analysis.analyse_defs opts.debug_analysis env defs in
      if f || opts.all_split_errors || opts.continue_anyway
      then f, r, ex
      else raise (Reporting_basic.err_general Unknown "Unable to monomorphise program")
    else true, [], Analysis.ExtraSplits.empty in
  let splits = new_splits @ (List.map (fun (loc,id) -> (loc,id,None)) splits) in
  let ok_extras, defs, extra_splits = add_extra_splits extra_splits defs in
  let splits = splits @ extra_splits in
  let () = if ok_extras || opts.all_split_errors || opts.continue_anyway
      then ()
      else raise (Reporting_basic.err_general Unknown "Unable to monomorphise program")
  in
  let ok_split, defs = split_defs opts.all_split_errors splits defs in
  let () = if (ok_analysis && ok_extras && ok_split) || opts.continue_anyway
      then ()
      else raise (Reporting_basic.err_general Unknown "Unable to monomorphise program")
  in
  let defs = BitvectorSizeCasts.add_bitvector_casts defs in
  (* TODO: currently doing this because constant propagation leaves numeric literals as
     int, try to avoid this later; also use final env for DEF_spec case above, because the
     type checker doesn't store the env at that point :( *)
  let defs = if opts.rewrite_size_parameters then
      let (defs,env) = recheck defs in
      let defs = AtomToItself.rewrite_size_parameters env defs in
      defs
    else
      defs
  in
  let () = if opts.dump_raw then Pretty_print_sail.pp_defs stdout defs else () in
  recheck defs
