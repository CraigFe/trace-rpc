open Lwt.Infix

exception Empty_queue

type task = {
  name: Interface.op;
  params: Interface.param list;
  key: string;
}

let task =
  let open Irmin.Type in
  record "task" (fun name params key -> { name; params; key })
  |+ field "name" Interface.op (fun t -> t.name)
  |+ field "params" (list Interface.param) (fun t -> t.params)
  |+ field "key" string (fun t -> t.key)
  |> sealr

type ('v, 'jq) contents =
  | Value of 'v
  | Task_queue of (task list * task list)
  | Job_queue of 'jq

module type QUEUE_TYPE = sig
  type t
  type job

  val t: t Irmin.Type.t
  val job: job Irmin.Type.t
end

module type JOB_QUEUE = sig
  type t
  (** The type of job queues *)

  type job
  (** The type of jobs *)

  module Store: Irmin.KV

  module Type: QUEUE_TYPE
    with type t = t
     and type job = job

  module type IMPL = sig
    val job_of_string: string -> job
    val job_to_string: job -> string

    val is_empty: Store.t -> bool Lwt.t
    val push: job -> Store.t -> unit Lwt.t
    val pop: Store.t -> job Lwt.t
    val peek_opt: Store.t -> job option Lwt.t
  end

  module Impl: IMPL
end

module MakeContents (Val: Irmin.Contents.S) (JQueueType: QUEUE_TYPE): Irmin.Contents.S
  with type t = (Val.t, JQueueType.t) contents = struct

  type t = (Val.t, JQueueType.t) contents

  let t =
    let open Irmin.Type in
    variant "contents" (fun value task_queue branch_name -> function
        | Value v -> value v
        | Task_queue q -> task_queue q
        | Job_queue js -> branch_name js)
    |~ case1 "Value" Val.t (fun v -> Value v)
    |~ case1 "Task_queue" (pair (list task) (list task)) (fun q -> Task_queue q)
    |~ case1 "Job_queue" JQueueType.t (fun js -> Job_queue js)
    |> sealv

  let pp = Irmin.Type.pp_json t

  let of_string s =
    let decoder = Jsonm.decoder (`String s) in
    Irmin.Type.decode_json t decoder

  let merge = Irmin.Merge.(option (idempotent t))
end

exception Malformed_params of string
module type S = sig

  type key = string
  type value
  type queue
  type operation = Interface.op
  type param = Interface.param

  type t

  module Contents: Irmin.Contents.S with type t = (value, queue) contents
  module Store: Irmin.KV with type contents = Contents.t
  module Sync: Irmin.SYNC with type db = Store.t
  module JobQueue: JOB_QUEUE with module Store = Store

  (* Here for testing purposes *)
  val task_queue_is_empty: t -> bool
  val job_queue_is_empty: t -> bool
  val generate_task_queue: operation -> param list -> t -> ('a, 'b) contents
  (* ------------------------- *)

  val of_store: Sync.db -> t
  val empty: ?directory:string -> unit -> t
  val is_empty: t -> bool
  val mem: key -> t -> bool
  val add: key -> value -> t -> t
  val find: key -> t -> value
  val remove: key -> t -> t
  val size: t -> int
  val keys: t -> key list
  val values: t -> value list
  val map: operation -> param list -> t -> t
end

module Make
    (Val : Irmin.Contents.S)
    (Desc: Interface.DESC with type t = Val.t)
    (QueueType: QUEUE_TYPE)
    (JQueueMake: functor
       (Val: Irmin.Contents.S)
       (St: Irmin.KV with type contents = (Val.t, QueueType.t) contents)
       -> (JOB_QUEUE with module Store = St)
    ) = struct

  module Contents = MakeContents(Val)(QueueType)
  module Store = Irmin_unix.Git.FS.KV(Contents)
  module Sync = Irmin.Sync(Store)
  module JobQueue = JQueueMake(Val)(Store)

  type key = string
  type value = Val.t
  type queue = QueueType.t
  type operation = Interface.op
  type param = Interface.param

  type t = Sync.db
  (* A map is a branch in an Irmin Key-value store *)

  let generate_random_directory () =
    Misc.generate_rand_string ~length:20 ()
    |> Pervasives.(^) "/tmp/irmin/set/"
    |> fun x -> Logs.info (fun m -> m "No directory supplied. Generated random directory %s" x); x

  let empty ?(directory=generate_random_directory()) () =
    let config = Irmin_git.config ~bare:true directory in

    (* Delete the directory if it already exists... Unsafe! *)
    let ret_code = Sys.command ("rm -rf " ^ directory) in begin
      if (ret_code <> 0) then invalid_arg "Unable to delete directory";

      let lwt = Store.Repo.v config
        >>= fun repo -> Store.of_branch repo "master"
      in Lwt_main.run lwt
    end

  let of_store s = s

  let mem key m =
    let lwt =
      Store.tree m
      >>= fun tree -> Store.Tree.list tree ["vals"]
      >|= List.exists (fun (x,_) -> x = key)
    in Lwt_main.run lwt

  let add key value m =
    let lwt =
      Store.set m
        ~info:(Irmin_unix.info ~author:"test" "Committing to key %s" key)
        ["vals"; key]
        (Value value)
    in Lwt_main.run lwt; m

  let find key m =
    let lwt =
      (* Get the value from the store and deserialise it *)
      Store.get m ["vals"; key]
      >|= fun value -> match value with
      | Value v -> v
      | _ -> invalid_arg "Can't happen by design"

    in try
      Lwt_main.run lwt
    with Invalid_argument _ -> raise Not_found

  let remove _ _ = invalid_arg "TODO"

  let size m =
    let lwt =
      Store.tree m
      >>= fun tree -> Store.Tree.list tree ["vals"]
      (* >|= List.filter (fun (_, typ) -> typ = `Contents) *)
      >|= List.length
    in Lwt_main.run lwt

  let is_empty m =
    (size m) == 0

  let keys m =
    let lwt =
      Store.tree m
      >>= fun tree -> Store.Tree.list tree ["vals"]
      >|= List.map(fst)
    in Lwt_main.run lwt

  let values m =
    let lwt =
      Store.tree m
      >>= fun tree -> Store.Tree.list tree ["vals"]
      >>= Lwt_list.map_p (fun (x, _) -> Store.get m ["vals"; x])
      >|= List.map (fun value -> match value with
          | Value v -> v
          | _ -> invalid_arg "Can't happen by design"
        )
    in Lwt_main.run lwt

  let get_task_queue m =
    Store.find m ["task_queue"]
    >|= fun q -> match q with
    | Some Task_queue tq -> tq
    | Some _ -> invalid_arg "Can't happen by design"
    | None -> ([], [])

  let task_queue_is_empty branch =
    let lwt =
      get_task_queue branch
      >|= fun q -> match q with
      | ([], []) -> true
      | _ -> false
    in Lwt_main.run lwt

  let job_queue_is_empty m =
    Lwt_main.run (JobQueue.Impl.is_empty m)

  let generate_task_queue operation params map =
    let (name, count) = operation in
    let expected_param_count = Int32.to_int count in
    let true_param_count = List.length params in

    if true_param_count != expected_param_count then
      Printf.sprintf "Expected %d arguments but received %d for operation %s"
        expected_param_count true_param_count name
      |> fun m -> raise (Malformed_params m)

    else
      keys map
      |> List.map (fun key -> {name=operation; params; key})
      |> (fun ops ->
          Logs.warn (fun m -> m "Generated task queue of [%s]"
                        (List.map (fun {name = n; params = _; key = k} ->
                             Printf.sprintf "{name: %s; key %s}" (fst n) k) ops
                         |> String.concat ", "));
          ops)
      |> fun ops -> Task_queue (ops, []) (* Initially there are no pending operations *)

  let set_task_queue q m =
    Store.set ~info:(Irmin_unix.info ~author:"map" "specifying workload")
      m ["task_queue"] q

  let map operation params m =
    let lwt =

      (* TODO: ensure this name doesn't collide with existing branches *)
      let map_name = "map--" ^ Misc.generate_rand_string ~length:8 () in
      Logs.app (fun m -> m "Map operation issued. Branch name %s" map_name);

      (* Push the job to the job queue *)
      JobQueue.Impl.push (JobQueue.Impl.job_of_string map_name) m

      (* Create a new branch to isolate the operation *)
      >>= fun _ -> Store.clone ~src:m ~dst:map_name
      >>= fun branch -> Store.merge_with_branch m
        ~info:(Irmin_unix.info ~author:"map" "Merged") "master"
      >|= (fun merge -> match merge with
      | Ok () -> ()
      | Error _ -> invalid_arg "merge conflict")

      (* Generate and commit the task queue *)
      >>= fun () -> set_task_queue (generate_task_queue operation params m) branch

      (* Wait for the task queue to be empty *)
      >|= (fun _ -> while not(task_queue_is_empty branch) do Unix.sleep 1 done)

      (* Merge the map branch into master *)
      >>= fun _ -> Store.merge_with_branch m
        ~info:(Irmin_unix.info ~author: "map" "Job %s complete" map_name) map_name
      >|= (fun merge -> match merge with
      | Ok () -> ()
      | Error _ -> invalid_arg "merge conflict")
      >>= fun _ -> JobQueue.Impl.pop m
      >|= fun _ -> Logs.app (fun m -> m "Map operation complete. Branch name %s" map_name)

    in Lwt_main.run lwt; m
end
