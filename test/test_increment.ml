open Trace_rpc

(** Tests of the distributed increment operation on integer maps *)
let test () =
  let open Intmap in begin
    Logs.set_reporter (Logs_fmt.reporter ());
    Logs.set_level (Some Logs.Info);
    let root = "/tmp/irmin/increment/" in

    IntMap.empty ~directory:(root ^ "test-0001") ()
    |> IntMap.map Definition.increment_op Interface.Unit
    |> fun _ -> Alcotest.(check pass "Calling map on an empty Map terminates" () ());

    Alcotest.check_raises "Calling map on a non-empty Map without a worker causes a timeout" Map.Timeout
    (fun () -> ignore (IntMap.empty ~directory:(root ^ "test-0002") ()
    |> IntMap.add "timeout" (Int64.of_int 1)
    |> IntMap.map ~timeout:epsilon_float Definition.increment_op Interface.Unit));

    (* let worker = IntWorker.run ~dir:"/tmp/irmin/increment-worker/test-0001"
     *   ~client:"file:///tmp/irmin/incrmeent/test-0001" () in *)

    (* Lwt_main.run (Lwt.choose [
     *   worker;
     *   (IntMap.empty ~directory:(root ^ "test-0001") ()
     *    |> IntMap.add "a" Int64.one
     *    |> IntMap.map Definition.double_op Interface.Unit (\* TODO: It shouldn't be necessary to pass the empty array here *\)
     *    |> IntMap.find "a"
     *    |> Alcotest.(check int64) "Issuing a double request on a single key" (Int64.of_int 2); Lwt.return_unit)
     * ]); *)

    (* IntMap.empty ~directory:(root ^ "test-0002") ()
     * |> IntMap.add "a" (Int64.of_int 1)
     * |> IntMap.add "b" (Int64.of_int 10)
     * |> IntMap.add "c" (Int64.of_int 100)
     * |> IntMap.map Definition.multiply_op
     *   (Interface.Param (Type.Param.Int64 (Int64.of_int 5), Interface.Unit))
     * |> IntMap.values
     * |> List.map Int64.to_int
     * |> List.sort compare
     * |> Alcotest.(check (list int)) "Issuing a multiply reuqest on several keys" [5; 50; 500]; *)
  end
