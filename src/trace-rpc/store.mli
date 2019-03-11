
(* A store is an instance of CausalRPC at a particular node *)
type job = string
type job_queue = job list

type 'v contents =
  | Value of 'v
  | Task_queue of Task_queue.t
  | Job_queue of job_queue

module MakeContents (Val: Irmin.Contents.S): Irmin.Contents.S
  with type t = Val.t contents

(* The job queue holds the active jobs to be performed *)
module type JOB_QUEUE = sig
  module Store: Irmin.KV

  module type IMPL = sig
    val job_of_string: string -> job
    val job_to_string: job -> string
    val job_equal: job -> job -> bool

    val is_empty: Store.t -> bool Lwt.t
    val push: job -> Store.t -> unit Lwt.t
    val pop: Store.t -> job Lwt.t
    val peek_opt: Store.t -> job option Lwt.t
  end

  module Impl: IMPL
end
