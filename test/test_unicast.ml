open Lwt.Infix
open Trace_rpc
open Intmap

module I = IntPair (Trace_rpc_unix.Make)(Global.GitBackend)
open I

let create_client directory remote =
  IntClient.empty ~directory
    ~local_uri:("file://" ^ directory)
    ~remote_uri:("file://" ^ remote)
    ~name:"clientA"
    ~initial:Int64.one

let test_single_rpc _switch () =
  let root = "/tmp/irmin/test_unicast/single_rpc/" in

  (* Create a simple client *)
  create_client (root ^ "clientA") (root ^ "server")
  >>= fun client -> IntMap.empty ~directory:(root ^ "server") ()
  >>= fun server -> IntMap.start server
  >>= fun () -> IntClient.rpc (O.apply multiply_op (Int64.of_int 10)) client
  >|= Int64.to_int
  >|= Alcotest.(check int) "Something" 10

  >>= (fun () ->
  let rec inner n max =
    if n = max then Lwt.return_unit
    else
      IntClient.rpc (O.apply increment_op) client
      >|= Int64.to_int
      >|= Alcotest.(check int) "Something" (n+1)
      >|= (fun () -> print_endline @@ Fmt.strf "%a" Core.Time_ns.pp (Core.Time_ns.now ()))
      >>= fun _ -> inner (n+1) max
  in inner 10 20)
  >>= fun () -> IntClient.output client


let test_aggregated_operations _switch () =
  let root = "/tmp/irmin/test_unicast/aggregate_operations/" in
  let open Trace_rpc.Remote in

  (* Create a simple client *)
  create_client (root ^ "client") (root ^ "server")
  >>= fun client -> IntMap.empty ~directory:(root ^ "server") ()
  >>= fun server -> IntMap.start server
  >>= fun () -> IntClient.rpc (
    O.apply increment_op
    <*> (O.app increment_op)
    <*> (O.app increment_op)
    <*> (O.app increment_op)
    <*> (O.app increment_op)
    <*> (O.app increment_op)
  ) client
  >|= Int64.to_int
  >|= Alcotest.(check int) "Something" 7

let tests = [
  Alcotest_lwt.test_case "Single client RPC" `Quick test_single_rpc;
  Alcotest_lwt.test_case "Aggregated operations" `Quick test_aggregated_operations
]

