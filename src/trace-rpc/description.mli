open Operation

(** A set of RPC operations *)
module Make(V: Irmin.Contents.S): sig
  module Op: Operation.S with module Val = V

  type 'i t
  (** The type of descriptions over type 'a *)

  val finally: (Op.Val.t, 'a, 'p, 'd) NamedOp.t -> (Op.Val.t, 'a) interface
  (** Construct an RPC interface from a single operation *)

  val (@): (Op.Val.t,'a,'p,'d) NamedOp.t
    -> (Op.Val.t, 'b) interface
    -> (Op.Val.t, 'a * 'b) interface
  (** Combinator for adding an operation to an interface *)

  val describe: (Op.Val.t,'a,'p,'d) NamedOp.t -> Op.t

  val define: (Op.Val.t,' i) interface -> 'i t
  (** Construct an RPC interface description from a list of declared functions *)

  val valid_name: string -> 'i t -> bool
  (** Test whether or not an operation is contained in the description *)

end with module Op = Operation.Make(V)

module type S = sig
  module Val: Irmin.Contents.S
  type shape
  val api: shape Make(Val).t
end
