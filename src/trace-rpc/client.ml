open Lwt.Infix

(* A client receives requests on a single key, and pushes onto the job_queue of
   a remote server*)
module type S = sig
  module Store: Store.S
  module Value = Store.Value

  type t
  (** A client *)

  val clear_caches: t -> unit Lwt.t

  val empty: ?directory:string
    -> remote_uri:string
    -> local_uri:string
    -> name:string
    -> initial:Value.t
    -> t Lwt.t

  val rpc: ?timeout:float
    -> Value.t Remote.t
    -> t -> Value.t Lwt.t

  val output: t -> unit Lwt.t
end

module Make (Store: Store.S): S with module Store = Store = struct
  module Store = Store
  module Value = Store.Value

  (* Private modules *)
  module IStore = Store.IrminStore
  module ISync = Store.IrminSync

  exception Push_error of ISync.push_error

  type t = {
    repo: IStore.repo;
    local: IStore.t;
    local_uri: string; (* When we invoke an RPC, we need to give a pointer back to us *)
    remote: Irmin.remote;
    name: IStore.branch (* The name of the branch that belongs to us *)
  }

  let clear_caches t =
    IStore.get_tree t.local []
    >|= IStore.Tree.clear_caches

  let generate_random_directory () =
    Helpers.generate_rand_string ~length:20 ()
    |> Pervasives.(^) "/tmp/irmin/client/"
    |> fun x -> Logs.info (fun m -> m "No directory supplied. Generated random directory %s" x); x

  let push t =
    ISync.push t.local t.remote

  let value t =
    IStore.get t.local ["val"]
    >>= fun contents -> match contents with
    | Contents.Value v -> Lwt.return v
    | _ -> Lwt.fail Not_found

  let empty ?(directory=generate_random_directory()) ~remote_uri ~local_uri ~name ~initial =
    let config = Irmin_git.config ~bare:true directory in
    let info = Store.B.make_info ~author:name "Initial value" in

    (* Delete the directory if it already exists... Unsafe! *)
    let ret_code = Sys.command ("rm -rf " ^ directory) in
    if (ret_code <> 0) then invalid_arg "Unable to delete directory";

    IStore.Repo.v config
    >>= fun repo -> IStore.of_branch repo name
    >>= fun local -> IStore.set local ["val"] (Contents.Value initial) ~info
    >>= (function
        | Ok () -> Lwt.return_unit
        | Error se -> Lwt.fail @@ Store.Store_error se)
    >>= fun () -> Store.upstream remote_uri name
    >|= fun remote -> {repo; local; local_uri; remote; name}

  let callback t () =
    let (thread, wait) = MProf.Trace.named_task "ClientWaitForRPCResponse" in
    (wait, thread >>= fun () -> value t)

  (* Thread that fails after f *)
  let timeout_thread f =
    Store.B.sleep f
    >|= (fun () -> MProf.Trace.label "ClientTimeoutThread")
    >>= fun () -> Lwt.fail Exceptions.Timeout

  let task_of_rpc =
    Task.of_rpc "root"

  let rpc ?(timeout=5.0) rpc t =
    let l = t.local in
    let ts = List.map task_of_rpc rpc in

    (* Push a job onto the job queue *)
    Store.JobQueue.push (Job.Rpc (ts, t.local_uri)) l

    >>= fun () -> Logs_lwt.app (fun m -> m "<%a> operation issued." (Fmt.list Task.pp) ts)
    (* Prepare to push by creating setting the watch on a thread *)

    >|= callback t
    >>= fun (wait, callback_thread) -> IStore.Branch.watch t.repo t.name
      (fun _ -> Lwt.return (Lwt.wakeup wait ()))

    >>= fun watch -> Logs_lwt.app (fun m -> m "Prepared callback thread")

    (* Push to the remote *)
    >>= fun () -> push t
    >>= fun res -> (match res with
        | Ok () -> Logs_lwt.app (fun m -> m "Successfully pushed to the remote")
        | Error pe -> Lwt.fail @@ Push_error pe)

    >>= fun () -> Lwt.pick [
      (callback_thread >>= fun v -> IStore.unwatch watch >>= fun () -> Lwt.return v);
      timeout_thread timeout]

  let output t =
    Store.IrminStore.Branch.get t.repo t.name
    >>= fun commit -> Store.IrminStore.history t.local
    >|= fun g -> Store.IrminStore.History.iter_vertex (fun a ->
        let info = Store.IrminStore.Commit.info a in
        print_endline (Fmt.strf "%Ld: %s" (Irmin.Info.date info) (Irmin.Info.message info))
      ) g
end

