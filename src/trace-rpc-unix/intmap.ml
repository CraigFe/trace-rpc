open Trace_rpc
open Lwt.Infix

module Int: Irmin.Contents.S with type t = int64 = struct
  type t = int64

  let t = Irmin.Type.int64

  let merge = Irmin.Merge.(option (idempotent t))
end

module O = Operation.Make(Int)
open O

let identity_op  = declare "identity" return
let increment_op = declare "increment" return
let multiply_op  = declare "multiply" Type.(int64 @-> return)
let sleep_op     = declare "sleep" Type.(float @-> return_lwt)
let complex_op   = declare "complex" Type.(int @-> list int @-> unit @-> string @-> return)

module Definition = struct
  module Val = Int
  module D = Description.Make(Int)
  open D

  type shape = ((O.Val.t -> O.Val.t) *
                ((O.Val.t -> O.Val.t) *
                 ((float -> O.Val.t -> O.Val.t Lwt.t) *
                  ((int64 -> O.Val.t -> O.Val.t) *
                   (int -> int list -> unit -> string -> O.Val.t -> O.Val.t)))))

  let api = define (identity_op @ increment_op @ sleep_op @ multiply_op @ finally complex_op)
end

module Implementation: Interface.IMPL with type Val.t = int64 = struct
  module Val = Int
  module I = Interface.MakeImplementation(Val)
  open I

  let identity x = x
  let increment x = Int64.add Int64.one x
  let sleep f x =
    (Lwt_unix.sleep f >|= fun () -> increment x)

  let multiply = Int64.mul

  let product = List.fold_left (fun x y -> x * y) 1

  let complex i1 is () s = match Pervasives.int_of_string_opt s with
    | Some i -> Int64.mul @@ Int64.of_int (i1 * (product is) * i)
    | None -> Int64.mul Int64.minus_one

  type shape = ((O.Val.t -> O.Val.t) *
       ((O.Val.t -> O.Val.t) *
        ((float -> O.Val.t -> O.Val.t Lwt.t) *
         ((int64 -> O.Val.t -> O.Val.t) *
          (int -> int list -> unit -> string -> O.Val.t -> O.Val.t)))))

  let api = define ((identity_op, identity)
         @ (increment_op, increment)
         @ (sleep_op, sleep)
         @ (multiply_op, multiply)
         @ finally (complex_op, complex))
end


module IntPair (B: Backend.MAKER) (G: Irmin_git.G) = struct
  module Store = Store.Make(B)(G)(Definition)

  module IntClient = Client.Make(Store)
  module IntMap = Map.Make(Store)(Implementation)
  module IntWorker = Worker.Make(IntMap)(Implementation)
end
