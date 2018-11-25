module Boxed : sig
  type t
  val irmin_t: t Irmin.Type.t
  val test_t: t Alcotest.testable
end

type 'a t
val unit: unit t
val bool: bool t
val char: char t
val int32: int32 t
val int64: int64 t
val string: string t
val list: 'a t -> 'a list t

val to_boxed: 'a t -> 'a -> Boxed.t
val from_boxed: 'a t -> Boxed.t -> 'a

val to_irmin_type: 'a t -> 'a Irmin.Type.t
val to_testable: 'a t -> 'a Alcotest.testable

type (_, _) eq = Eq: ('a, 'a) eq
val refl: 'a t -> 'b t -> ('a, 'b) eq option
val equal: 'a t -> 'a -> 'a -> bool
