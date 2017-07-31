
val cast forall Num 'n, Num 'm, Order 'ord. vector<'n,'m,'ord,bit> -> [|0:2**'m - 1|] effect pure unsigned

val forall Num 'n, Num 'm, Order 'ord. vector<'n,'m,'ord,bit> -> [|0 - (2**('m - 1)):2**('m - 1) - 1|] effect pure signed

val forall Num 'n, Num 'm. [|0:'n|] -> vector<'m - 1,'m,dec,bit> effect pure to_vec

val forall Num 'm. int -> vector<'m - 1,'m,dec,bit> effect pure to_svec

(* Vector access can't actually be properly polymorphic on vector
   direction because of the ranges being different for each type, so
   we overload it instead *)
val forall Num 'n, Num 'l, Type 'a, 'l >= 0. (vector<'n,'l,dec,'a>, [|'n - 'l + 1:'n|]) -> 'a effect pure vector_access_dec
val forall Num 'n, Num 'l, Type 'a, 'l >= 0. (vector<'n,'l,inc,'a>, [|'n:'n + 'l - 1|]) -> 'a effect pure vector_access_inc

overload vector_access [vector_access_inc; vector_access_dec]

(* Type safe vector subrange *)
val forall Num 'n, Num 'l, Num 'm, Num 'o, Type 'a, 'l >= 0, 'm <= 'o, 'o <= 'l.
  (vector<'n,'l,inc,'a>, [:'m:], [:'o:]) -> vector<'m,'o - 'm,inc,'a> effect pure vector_subrange_inc

val forall Num 'n, Num 'l, Num 'm, Num 'o, Type 'a, 'n >= 'm, 'm >= 'o, 'o >= 'n - 'l + 1.
  (vector<'n,'l,dec,'a>, [:'m:], [:'o:]) -> vector<'m,'m - ('o - 1),dec,'a> effect pure vector_subrange_dec

val forall Num 'n, Num 'l, Order 'ord.
  (vector<'n,'l,'ord,bit>, int, int) -> list<bit> effect pure vector_subrange_bl

overload vector_subrange [vector_subrange_inc; vector_subrange_dec; vector_subrange_bl]

(* Type safe vector append *)
val forall Num 'n1, Num 'l1, Num 'n2, Num 'l2, Order 'o, Type 'a, 'l1 >= 0, 'l2 >= 0.
  (vector<'n1,'l1,'o,'a>, vector<'n2,'l2,'o,'a>) -> vector<'l1 + 'l2 - 1,'l1 + 'l2,'o,'a> effect pure vec_append

val (list<bit>, list<bit>) -> list<bit> effect pure list_append

overload vector_append [vec_append; list_append]

(* Implicit register dereferencing *)
val cast forall Type 'a. register<'a> -> 'a effect {rreg} reg_deref

(* Bitvector duplication *)
val forall Num 'n. (bit, [:'n:]) -> vector<'n - 1,'n,dec,bit> effect pure duplicate

val (bit, int) -> list<bit> effect pure duplicate_to_list

val forall Num 'n, Num 'm, Num 'o, Order 'ord.
  (vector<'o,'n,'ord,bit>, [:'m:]) -> vector<'o,'m*'n,'ord,bit> effect pure duplicate_bits

val forall Num 'n, Num 'o, Order 'ord.
  (vector<'o,'n,'ord,bit>, int) -> list<bit> effect pure duplicate_bits_to_list

overload (deinfix ^^) [duplicate; duplicate_bits; duplicate_to_list; duplicate_bits_to_list]

(* Bitvector extension *)
val forall Num 'n, Num 'm, Num 'o, Num 'p, Order 'ord.
    vector<'o, 'n, 'ord, bit> -> vector<'p, 'm, 'ord, bit> effect pure extz

val forall Num 'm, Num 'p, Order 'ord.
    list<bit> -> vector<'p, 'm, 'ord, bit> effect pure extz_bl

val forall Num 'n, Num 'm, Num 'o, Num 'p, Order 'ord.
    vector<'o, 'n, 'ord, bit> -> vector<'p, 'm, 'ord, bit> effect pure exts

val forall Num 'm, Num 'p, Order 'ord.
    list<bit> -> vector<'p, 'm, 'ord, bit> effect pure exts_bl

(* If we want an automatic bitvector extension, then this is the function to
   use, but I've disabled the cast because it hides signedness bugs. *)
val (*cast*) forall Num 'n, Num 'm, Num 'o, Num 'p, Order 'ord, 'm >= 'n.
    vector<'o, 'n, 'ord, bit> -> vector<'p, 'm, 'ord, bit> effect pure extzi

overload EXTZ [extz; extz_bl]
overload EXTS [exts; exts_bl]

val forall Type 'a, Num 'n, Num 'm, Num 'o, Num 'p, Order 'ord, 'm >= 'o.
    vector<'n, 'm, 'ord, 'a> -> vector<'p, 'o, 'ord, 'a> effect pure mask

(* Adjust the start index of a decreasing bitvector *)
val cast forall Num 'n, Num 'm, 'n >= 'm - 1.
  vector<'n,'m,dec,bit> -> vector<'m - 1,'m,dec,bit>
  effect pure norm_dec

val cast forall Num 'n, Num 'm, Num 'o, 'n >= 'm - 1, 'o >= 'm - 1.
  vector<'n,'m,dec,bit> -> vector<'o,'m,dec,bit>
  effect pure adjust_dec

(* Various casts from 0 and 1 to bitvectors *)
val cast forall Num 'n, Num 'l, Order 'ord. [:0:] -> vector<'n,'l,'ord,bit> effect pure cast_0_vec
val cast forall Num 'n, Num 'l, Order 'ord. [:1:] -> vector<'n,'l,'ord,bit> effect pure cast_1_vec
val cast forall Num 'n, Num 'l, Order 'ord. [|0:1|] -> vector<'n,'l,'ord,bit> effect pure cast_01_vec

val cast forall Num 'n, Order 'ord. vector<'n,1,'ord,bit> -> bool effect pure cast_vec_bool
val cast bit -> bool effect pure cast_bit_bool

val cast forall Num 'n, Num 'm, 'n >= 'm - 1, 'm >= 1. bit -> vector<'n,'m,dec,bit> effect pure cast_bit_vec

(* MSB *)
val forall Num 'n, Num 'm, Order 'ord. vector<'n, 'm, 'ord, bit> -> bit effect pure most_significant

(* Arithmetic *)

val forall Num 'n, Num 'm, Num 'o, Num 'p.
    ([|'n:'m|], [|'o:'p|]) -> [|'n + 'o:'m + 'p|] effect pure add

val (nat, nat) -> nat effect pure add_nat

val (int, int) -> int effect pure add_int

val forall Num 'n, Num 'o, Order 'ord.
    (vector<'o, 'n, 'ord, bit>, vector<'o, 'n, 'ord, bit>) -> vector<'o, 'n, 'ord, bit> effect pure add_vec

val forall Num 'n, Num 'o, Order 'ord.
    (vector<'o, 'n, 'ord, bit>, int) -> vector<'o, 'n, 'ord, bit> effect pure add_vec_int

val forall Num 'n, Num 'o, Order 'ord.
    (vector<'o, 'n, 'ord, bit>, vector<'o, 'n, 'ord, bit>) -> (vector<'o, 'n, 'ord, bit>, bit, bit) effect pure add_overflow_vec

val forall Num 'n, Num 'm, Num 'o, Num 'p.
    ([|'n:'m|], [|'o:'p|]) -> [|'n - 'p:'m - 'o|] effect pure sub

val (int, int) -> int effect pure sub_int

val forall Num 'n, Num 'm, Order 'ord.
    (vector<'n,'m,'ord,bit>, int) -> vector<'n,'m,'ord,bit> effect pure sub_vec_int

val forall Num 'n, Num 'o, Order 'ord.
    (vector<'o, 'n, 'ord, bit>, vector<'o, 'n, 'ord, bit>) -> vector<'o, 'n, 'ord, bit> effect pure sub_vec

val forall Num 'n, Num 'o, Order 'ord.
    (vector<'o, 'n, 'ord, bit>, vector<'o, 'n, 'ord, bit>) -> (vector<'o, 'n, 'ord, bit>, bit, bit) effect pure sub_underflow_vec

overload (deinfix +) [
  add_vec;
  add_overflow_vec;
  add_vec_int;
  add;
  add_nat;
  add_int
]

overload (deinfix -) [
  sub_vec_int;
  sub_vec;
  sub_underflow_vec;
  sub;
  sub_int
]

val bool -> bit effect pure bool_to_bit

val (int, int) -> int effect pure mul_int
val forall Num 'n, Num 'o, Order 'ord.
    (vector<'o, 'n, 'ord, bit>, vector<'o, 'n, 'ord, bit>) -> vector<2 * 'n - 1, 2 * 'n, 'ord, bit> effect pure mul_vec

overload (deinfix * ) [
  mul_vec;
  mul_int
]

val forall Num 'n, Num 'o, Order 'ord.
    (vector<'o, 'n, 'ord, bit>, vector<'o, 'n, 'ord, bit>) -> vector<2 * 'n - 1, 2 * 'n, 'ord, bit> effect pure mul_svec

overload (deinfix *_s) [
  mul_svec
]

val (bool, bool) -> bool effect pure bool_xor

val forall Num 'n, Num 'o, Order 'ord.
    (vector<'o, 'n, 'ord, bit>, vector<'o, 'n, 'ord, bit>) -> vector<'o, 'n, 'ord, bit> effect pure xor_vec

overload (deinfix ^) [
  bool_xor;
  xor_vec
]

val forall Num 'n, Num 'o, Order 'ord.
    (vector<'o, 'n, 'ord, bit>, int) -> vector<'o, 'n, 'ord, bit> effect pure shiftl

overload (deinfix <<) [
  shiftl
]

val forall Num 'n, Num 'o, Order 'ord.
    (vector<'o, 'n, 'ord, bit>, int) -> vector<'o, 'n, 'ord, bit> effect pure shiftr

overload (deinfix >>) [
  shiftr
]

(* Boolean operators *)
val bool -> bool effect pure bool_not
val (bool, bool) -> bool effect pure bool_or
val (bool, bool) -> bool effect pure bool_and

val forall Num 'n, Num 'm, Order 'ord.
    vector<'n,'m,'ord,bit> -> vector<'n,'m,'ord,bit> effect pure bitwise_not

val forall Num 'n, Num 'm, Order 'ord.
    (vector<'n,'m,'ord,bit>, vector<'n,'m,'ord,bit>) -> vector<'n,'m,'ord,bit> effect pure bitwise_and

val forall Num 'n, Num 'm, Order 'ord.
    (vector<'n,'m,'ord,bit>, vector<'n,'m,'ord,bit>) -> vector<'n,'m,'ord,bit> effect pure bitwise_or

overload ~ [bool_not; bitwise_not]
overload (deinfix &) [bool_and; bitwise_and]
overload (deinfix |) [bool_or; bitwise_or]

(* Equality *)

val forall Num 'n, Num 'm, Order 'ord. (vector<'n,'m,'ord,bit>, vector<'n,'m,'ord,bit>) -> bool effect pure eq_vec

val forall Type 'a. ('a, 'a) -> bool effect pure eq

val forall Num 'n, Num 'm, Order 'ord. (vector<'n,'m,'ord,bit>, vector<'n,'m,'ord,bit>) -> bool effect pure neq_vec

val forall Type 'a. ('a, 'a) -> bool effect pure neq

function forall Num 'n, Num 'm, Order 'ord. bool neq_vec (v1, v2) = bool_not(eq_vec(v1, v2))

overload (deinfix ==) [eq_vec; eq]
overload (deinfix !=) [neq_vec; neq]

val forall Num 'n, Num 'm, Order 'ord. (vector<'n,'m,'ord,bit>, vector<'n,'m,'ord,bit>) -> bool effect pure gteq_vec
val forall Num 'n, Num 'm, Order 'ord. (vector<'n,'m,'ord,bit>, vector<'n,'m,'ord,bit>) -> bool effect pure gt_vec
val forall Num 'n, Num 'm, Order 'ord. (vector<'n,'m,'ord,bit>, vector<'n,'m,'ord,bit>) -> bool effect pure lteq_vec
val forall Num 'n, Num 'm, Order 'ord. (vector<'n,'m,'ord,bit>, vector<'n,'m,'ord,bit>) -> bool effect pure lt_vec

val (int, int) -> bool effect pure gteq_int
val (int, int) -> bool effect pure gt_int
val (int, int) -> bool effect pure lteq_int
val (int, int) -> bool effect pure lt_int

val forall Num 'n, Num 'm, Num 'o. ([|'n:'m|], [:'o:]) -> bool effect pure lt_range_atom
val forall Num 'n, Num 'm, Num 'o. ([|'n:'m|], [:'o:]) -> bool effect pure lteq_range_atom
val forall Num 'n, Num 'm, Num 'o. ([|'n:'m|], [:'o:]) -> bool effect pure gt_range_atom
val forall Num 'n, Num 'm, Num 'o. ([|'n:'m|], [:'o:]) -> bool effect pure gteq_range_atom
val forall Num 'n, Num 'm, Num 'o. ([:'n:], [|'m:'o|]) -> bool effect pure lt_atom_range
val forall Num 'n, Num 'm, Num 'o. ([:'n:], [|'m:'o|]) -> bool effect pure lteq_atom_range
val forall Num 'n, Num 'm, Num 'o. ([:'n:], [|'m:'o|]) -> bool effect pure gt_atom_range
val forall Num 'n, Num 'm, Num 'o. ([:'n:], [|'m:'o|]) -> bool effect pure gteq_atom_range

val forall Num 'n, Num 'm. ([:'n:], [:'m:]) -> bool effect pure lteq_atom_atom
val forall Num 'n, Num 'm. ([:'n:], [:'m:]) -> bool effect pure gteq_atom_atom
val forall Num 'n, Num 'm. ([:'n:], [:'m:]) -> bool effect pure lt_atom_atom
val forall Num 'n, Num 'm. ([:'n:], [:'m:]) -> bool effect pure gt_atom_atom

overload (deinfix >=) [gteq_atom_atom; gteq_range_atom; gteq_atom_range; gteq_vec; gteq_int]
overload (deinfix >) [gt_atom_atom; gt_vec; gt_int]
overload (deinfix <=) [lteq_atom_atom; lteq_range_atom; lteq_atom_range; lteq_vec; lteq_int]
overload (deinfix <) [lt_atom_atom; lt_vec; lt_int]

val forall Num 'n, Num 'm, Order 'ord. (vector<'n,'m,'ord,bit>, vector<'n,'m,'ord,bit>) -> bool effect pure gteq_svec
val forall Num 'n, Num 'm, Order 'ord. (vector<'n,'m,'ord,bit>, vector<'n,'m,'ord,bit>) -> bool effect pure gt_svec
val forall Num 'n, Num 'm, Order 'ord. (vector<'n,'m,'ord,bit>, vector<'n,'m,'ord,bit>) -> bool effect pure lteq_svec
val forall Num 'n, Num 'm, Order 'ord. (vector<'n,'m,'ord,bit>, vector<'n,'m,'ord,bit>) -> bool effect pure lt_svec

overload (deinfix <_s) [lt_svec]
overload (deinfix <=_s) [lteq_svec]
overload (deinfix >_s) [gt_svec]
overload (deinfix >=_s) [gteq_svec]

val (int, int) -> int effect pure quotient

overload (deinfix quot) [quotient]

val (int, int) -> int effect pure modulus

overload (deinfix mod) [modulus]

val forall Num 'n, Num 'm, Order 'ord, Type 'a. vector<'n,'m,'ord,'a> -> [:'m:] effect pure length

val cast forall Num 'n. [:'n:] -> [|'n|] effect pure upper

typedef option = const union forall Type 'a. {
    None;
    'a Some
}
