
(* A store is an instance of CausalRPC at a particular node *)
module type S = sig
  module Description: Description.S
  module Value = Description.Val
  module IrminContents: Irmin.Contents.S with type t = Value.t Contents.t

  module IrminStore: Irmin_git.S
    with type key = string list
     and type step = string
     and type contents = IrminContents.t
     and type branch = string

  module B: Backend.S
  module IrminSync: Irmin.SYNC with type db = IrminStore.t

  module type JOB_QUEUE = sig
    val is_empty: IrminStore.t -> bool Lwt.t
    val push: Job.t -> IrminStore.t -> unit Lwt.t
    val pop: IrminStore.t -> (Job.t, string) result Lwt.t
    val peek_opt: IrminStore.t -> Job.t option Lwt.t
    val peek_tree: IrminStore.t -> (Job.t * IrminStore.tree) option Lwt.t
  end

  module JobQueue: JOB_QUEUE 
  module Operation: Operation.S with module Val = Value

  exception Store_error of IrminStore.write_error
  exception Push_error of IrminSync.push_error

  (** Get an Irmin.store at a local or remote URI. *)
  val upstream: uri:string -> branch:string -> Irmin.remote Lwt.t

  val remove_pending_task: Task.t -> IrminStore.tree -> IrminStore.tree Lwt.t
  val remove_pending_tasks: Task.t list -> IrminStore.tree -> IrminStore.tree Lwt.t
end

(** A CausalRPC store. Parameterised on:
    - a CausalRPC backend module
    - an Irmin Git implementation
    - a description of an interface
    - a job_queue format functor *)
module Make
    (BackendMaker: Backend.MAKER)
    (GitBackend: Irmin_git.G)
    (Desc: Description.S): S
  with module Description = Desc
   and module Operation = Operation.Make(Desc.Val)
   and type IrminStore.branch = string
