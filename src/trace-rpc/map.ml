open Lwt.Infix
module E = Exceptions
open Contents
open Task

module type S = sig
  type key = string

  type t

  module Store: Store.S
  module Sync = Store.IrminSync
  module Value = Store.Value

  type 'a params = (Value.t, 'a) Interface.params

  val of_store: Sync.db -> t
  val to_store: t -> Sync.db

  val empty: ?directory:string -> ?remote_uri:string -> unit -> t Lwt.t
  val is_empty: t -> bool Lwt.t
  val mem: key -> t -> bool Lwt.t
  val add: ?message:string -> key -> Value.t -> t -> t Lwt.t
  val add_all: ?message:string -> (key * Value.t) list -> t -> t Lwt.t
  val find: key -> t -> Value.t Lwt.t
  val remove: key -> t -> t Lwt.t
  val size: t -> int Lwt.t
  val keys: t -> key list Lwt.t
  val values: t -> Value.t list Lwt.t
  val map: ?timeout:float -> (Value.t,'a,'p) Interface.NamedOp.t -> 'a params -> t -> t Lwt.t
  val start: t -> unit Lwt.t
end

module Make (Store: Store.S)
    (Impl: Interface.IMPL with module Val = Store.Value) : S
  with module Store = Store = struct

  module Store = Store
  module Sync = Store.IrminSync
  module Value = Store.Value

  (* Internal modules *)
  module IrminStore = Store.IrminStore
  module I = Interface.MakeImplementation(Impl.Val)
  module Ex = Executor.Make(I)

  type key = string
  type value = Value.t
  type 'a params = (Value.t, 'a) Interface.params

  type t = {
    local: IrminStore.t;
    remote_uri: string option;
  }
  (* A map is a branch in an Irmin Key-value store *)

  exception Internal_type_error

  let generate_random_directory () =
    Helpers.generate_rand_string ~length:20 ()
    |> Pervasives.(^) "/tmp/irmin/map/"
    |> fun x -> Logs.info (fun m -> m "No directory supplied. Generated random directory %s" x); x

  let empty ?(directory=generate_random_directory()) ?remote_uri () =
    let config = Irmin_git.config ~bare:true directory in

    Helpers.check_within_tmp directory;

    (* Delete the directory if it already exists... Unsafe! *)
    let ret_code = Sys.command ("rm -rf " ^ directory) in
    if (ret_code <> 0) then invalid_arg "Unable to delete directory";

    IrminStore.Repo.v config
    >>= IrminStore.master

    >|= fun local -> {local; remote_uri}

  let of_store s = {local = s; remote_uri = None}
  let to_store {local; _} = local

  let mem key {local; _} =
    IrminStore.tree local
    >>= fun tree -> IrminStore.Tree.list tree ["vals"]
    >|= List.exists (fun (x,_) -> x = key)

  let add ?message key value m =
    let l = m.local in
    let message = (match message with
        | Some m -> m
        | None -> Printf.sprintf "Commit to key %s" key) in

    IrminStore.set
      ~allow_empty:true
      ~info:(Store.B.make_info ~author:"client" "%s" message)
      l
      ["vals"; key]
      (Value value)

    >>= fun res -> match res with
    | Ok () -> Lwt.return m
    | Error se -> Lwt.fail @@ Store.Store_error se

  let add_all ?message kv_list m =
    let l = m.local in
    let rec contains_duplicates l = (match l with
        | [] -> false
        | x::xs -> (List.mem x xs) || contains_duplicates xs)

    in if contains_duplicates kv_list then invalid_arg "Duplicate keys in key/value list";

    let message = (match message with
        | Some m -> m
        | None -> Printf.sprintf "Commit to %d keys" (List.length kv_list)) in


    IrminStore.find_tree l ["vals"]
    >|= (fun t -> match t with
        | Some t -> t
        | None -> IrminStore.Tree.empty)

    (* We construct the commit by folding over the (k,v) list and accumulating a tree *)
    >>= Lwt_list.fold_right_s
      (fun (k, v) tree_acc -> IrminStore.Tree.add tree_acc [k] (Value v))
      kv_list

    >>= fun tree -> IrminStore.set_tree
      ~allow_empty:true
      ~info:(Store.B.make_info ~author:"client" "%s" message)
      l ["vals"] tree

    >>= fun res -> (match res with
        | Ok () -> Lwt.return m
        | Error se -> Lwt.fail @@ Store.Store_error se)

  let find key {local; _} =
    (* Get the value from the store and deserialise it *)
    IrminStore.find local ["vals"; key]

    >>= fun value -> match value with
    | Some (Value v) -> Lwt.return v
    | Some _ -> Lwt.fail Internal_type_error
    | None -> Lwt.fail Not_found

  let remove _ _ = invalid_arg "TODO"

  let size {local; _} =
    IrminStore.tree local
    >>= fun tree -> IrminStore.Tree.list tree ["vals"]
    (* >|= List.filter (fun (_, typ) -> typ = `Contents) *)
    >|= List.length

  let is_empty m =
    size m
    >|= (=) 0

  let keys m =
    IrminStore.tree m.local
    >>= fun tree -> IrminStore.Tree.list tree ["vals"]
    >|= List.map(fst)

  let values m =
    IrminStore.tree m.local
    >>= fun tree -> IrminStore.Tree.list tree ["vals"]
    >>= Lwt_list.map_p (fun (x, _) -> IrminStore.get m.local ["vals"; x])
    >|= List.map (fun value -> match value with
        | Value v -> v
        | _ -> raise Internal_type_error
      )

  let get_task_queue m =
    IrminStore.find m ["task_queue"]
    >>= fun q -> match q with
    | Some Task_queue tq -> Lwt.return tq
    | _ -> Lwt.fail Internal_type_error

  let task_queue_is_empty branch =
    get_task_queue branch
    >|= fun q -> match q with
    | ([], []) -> true
    | _ -> false

  let task_queue_size branch =
    get_task_queue branch
    >|= fun (a, b) -> (List.length a) + (List.length b)

  let generate_task_queue: type a p. (value, a, p) Interface.NamedOp.t -> a params -> t -> value Contents.t Lwt.t = fun operation params map ->
    let open Task_queue in
    let name = Interface.NamedOp.name operation in
    let param_list = Store.Operation.flatten_params params in

    keys map
    >|= List.map (fun key -> {name; params = param_list; key})
    >>= fun ops -> Logs_lwt.app (fun m -> m "Generated task queue of [%s]"
                                    (List.map Task.show ops |> String.concat ", "))
    >|= fun () -> Task_queue (ops, []) (* Initially there are no pending operations *)

  let set_task_queue q m =
    IrminStore.set ~info:(Store.B.make_info ~author:"map" "Specify workload")
      m ["task_queue"] q

    >>= fun res -> match res with
    | Ok () -> Lwt.return_unit
    | Error we -> Lwt.fail @@ Store.Store_error we

  let map ?(timeout=5.0) operation params m =

    let l = m.local in

    (* Generate a new unique branch name for the map *)
    let rec unique_name_gen () =
      Lwt.wrap (fun () -> "map--" ^ Helpers.generate_rand_string ~length:8 ())
      >>= fun map_name -> IrminStore.Branch.mem (IrminStore.repo l) map_name
      >>= fun exists -> if exists then unique_name_gen () else Lwt.return map_name
    in unique_name_gen ()

    >>= fun map_name -> Logs_lwt.app (fun m -> m "Map operation issued. Branch name %s" map_name)

    (* Push the job onto the job queue *)
    >>= fun () -> Store.JobQueue.Impl.push (Job.MapJob map_name) l

    (* Create a new branch to isolate the operation *)
    >>= fun () -> IrminStore.clone ~src:l ~dst:map_name
    >>= fun branch -> IrminStore.merge_with_branch l
      ~info:(Store.B.make_info ~author:"map" "Merged") IrminStore.Branch.master
    >>= Helpers.handle_merge_conflict IrminStore.Branch.master map_name

    (* Generate and commit the task queue *)
    >>= fun () -> generate_task_queue operation params m
    >>= fun tq -> set_task_queue tq branch

    (* Wait for the task queue to be empty *)
    >>= fun () ->

    let inactivity_count = ref 0.0 in
    let sleep_interval = ref 0.01 in

    (* The callback to be executed when we detect changes to the repository.
       Note: here we don't explicitly signal the workers that are available for a
       map, so we have to watch for any changes in the repo and then filter within
       the callback. *)
    let watch_callback (br_name: IrminStore.branch) (_: IrminStore.commit Irmin.diff) =

      (* Here we assume that all branches that don't start with 'map--' are worker branches
         for this map request. In future this may not always be the case *)
      if String.equal br_name map_name then Lwt.return_unit
      else if not (String.sub br_name  0 5 |> String.equal "map--") then begin

        IrminStore.of_branch (IrminStore.repo l) br_name
        >>= Store.JobQueue.Impl.peek_opt
        >>= fun job -> (match job with
            | Some (Job.MapJob m) when String.equal map_name m ->

              Logs_lwt.debug (fun m -> m "Resetting count due to activity on branch %s" br_name)
              >|= (fun () -> inactivity_count := 0.0; sleep_interval := !sleep_interval /. 2.)

              (* Merge the work from this branch *)
              >>= fun () -> IrminStore.merge_with_branch branch
                ~info:(Store.B.make_info ~author:"map" "Merged work from %s into %s" br_name map_name) br_name

              >>= Helpers.handle_merge_conflict br_name map_name

            | Some j -> Logs_lwt.warn
                          (fun m -> m "Woke up due to submitted work for a job %a, but the currently executing job is %s"
                              Job.pp j map_name)

            | None -> Lwt.fail @@ E.Protocol_error (Printf.sprintf "Received work on branch %s, but there is no job on this branch" br_name))

      end else
        Logs_lwt.warn (fun m -> m "Woke up due to an irrelevant branch %s when waiting for work on %s" br_name map_name)

    in

    IrminStore.Branch.watch_all (IrminStore.repo l) watch_callback

    >>= fun watch -> Logs_lwt.app (fun m -> m "Waiting for the task queue to be empty, with timeout %f" timeout)
    >>= fun () ->

    let rec inner () =

      task_queue_is_empty branch
      >>= fun is_empty -> if is_empty then (* we are done *)
        IrminStore.unwatch watch

      else if !inactivity_count >= timeout then (* we have been waiting for too long *)
        Logs_lwt.app (fun m -> m "Inactivity count: %f" (!inactivity_count))
        >>= fun () -> Lwt.fail E.Timeout

      else (* we will wait for a bit *)
        task_queue_size branch
        >>= fun tq_size -> Logs_lwt.app (fun m -> m "Sleeping for a time of %f, with an inactivity count of %f. %d tasks remaining"
                                            !sleep_interval !inactivity_count tq_size)
        >>= fun () -> Store.B.sleep (!sleep_interval)
        >|= (fun () ->
            inactivity_count := !inactivity_count +. !sleep_interval;
            sleep_interval := !sleep_interval *. 2.)
        >>= inner

    in inner ()

    >>= (fun () -> Logs_lwt.info @@ fun m -> m "All operations complete on %s. Merging with the master branch" map_name)

    (* Merge the map branch into master *)
    >>= fun () -> IrminStore.merge_with_branch l
      ~info:(Store.B.make_info ~author: "map" "Job %s complete" map_name) map_name
    >>= Helpers.handle_merge_conflict map_name IrminStore.Branch.master

    (* Remove the job from the job queue *)
    >>= fun () -> Store.JobQueue.Impl.pop l

    (* For now, we only ever perform one map at once. Eventually, the job queue
       will need to be cleverer to avoid popping off the wrong job here *)
    >>= fun j -> (match j with
        | Ok (Job.MapJob m) when m = map_name -> Lwt.return_unit
        | Ok j -> Lwt.fail_with (Fmt.strf "Expected to pop %a, but actually popped %a" Job.pp (Job.MapJob map_name) Job.pp j)
        | Error msg -> Lwt.fail_with (Fmt.strf "Error <%s> when attempting to remove %a from the job queue" msg Job.pp (Job.MapJob map_name)))

    >>= (fun _ -> Logs_lwt.app @@ fun m -> m "Map operation complete. Branch name %s" map_name)
    >|= fun () -> m

  (* This is the main server process *)
  let start m =
    let l = m.local in
    let pp_task = Fmt.of_to_string (fun (t:Task.t) -> Fmt.strf "<%s> on key %s" t.name t.key) in

    (* The callback wakes up a thread on our queue *)
    let watch_callback (br_name: IrminStore.branch) (_: IrminStore.commit Irmin.diff) =
      IrminStore.of_branch (IrminStore.repo l) br_name
      >>= fun local -> Store.JobQueue.Impl.pop local
      >>= fun result -> (match result with
      | Ok job -> Lwt.return job
      | Error msg -> Lwt.fail_with (Fmt.strf "Error <%s> when attempting to pop from job queue on branch %s" msg br_name))

      >>= fun job -> (match job with
          | Job.Rpc (t, remote) ->
            let boxed_mi () = (match I.find_operation_opt t.name Impl.api with
                | Some operation -> operation
                | None -> invalid_arg "Operation not found") in

            (* Found a pending RPC task *)
            IrminStore.get local ["val"]
            >>= (fun v -> match v with Value v -> Lwt.return v | _ -> raise E.Internal_type_error)
            >>= fun old_val -> Ex.execute_task (boxed_mi ()) t.params old_val

            (* Commit value to store *)
            >>= fun new_val -> IrminStore.set local ["val"]
              ~info:(Store.B.make_info ~author:"server" "%a" pp_task t) (Value new_val)

            >>= fun res -> (match res with
                | Ok () -> Lwt.return_unit
                | Error se -> Lwt.fail @@ Store.Store_error se)

            (* Merge into master *)
            (* TODO *)

            (* Push back to the client *)
            >>= fun () -> Store.upstream ~uri:remote ~branch:br_name
            >>= fun remote -> Sync.push local remote
            >>= fun res -> (match res with
                | Ok () -> Lwt.return_unit
                | Error pe -> Lwt.fail @@ Store.Push_error pe)

          | Job.MapJob _ -> Lwt.return_unit)

    in let _ = IrminStore.Branch.watch_all (IrminStore.repo l) watch_callback in
    Lwt.return_unit

  let () = Store.B.initialise (); (* XXX *)
end
