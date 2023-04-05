defmodule IdempotencyPlugTest do
  use ExUnit.Case

  import Plug.Conn

  alias IdempotencyPlug.RequestTracker

  setup [:setup_tracker, :setup_request]

  test "with no idempotency header set", %{conn: conn, tracker: tracker} do
    conn =
      conn
      |> delete_req_header("idempotency-key")
      |> run_plug(tracker)

    assert conn.halted
    assert json = json_response(conn, 400)
    assert json["message"] =~ "No idempotency key found."
  end

  test "with too many idempotency headers set", %{conn: conn, tracker: tracker} do
    conn = run_plug(%{conn | req_headers: conn.req_headers ++ [{"idempotency-key", "other-key"}]}, tracker)

    assert conn.halted
    assert json = json_response(conn, 400)
    assert json["message"] =~ "Only one `Idempotency-Key` header can be sent."
  end

  test "with no idempotency header set and GET header", %{conn: conn, tracker: tracker} do
    conn =
      conn
      |> delete_req_header("idempotency-key")
      |> Map.put(:method, "GET")
      |> run_plug(tracker)

    refute conn.halted
    assert conn.resp_body == "OK"
    refute expires(conn)
  end

  test "with no cached response", %{conn: conn, tracker: tracker} do
    conn = run_plug(conn, tracker)

    refute conn.halted
    assert conn.status == 200
    assert conn.resp_body == "OK"
    assert expires(conn)
  end

  test "with concurrent request", %{conn: conn, tracker: tracker} do
    pid = self()

    task =
      Task.async(fn ->
        run_plug(conn, tracker, callback: fn conn ->
          send(pid, :continue)
          receive do
            :continue -> :ok
          end
          conn
        end)
      end)

    receive do
      :continue -> :ok
    end

    conn = run_plug(conn, tracker)

    assert conn.halted
    assert json = json_response(conn, 409)
    assert json["message"] =~ "A request with the same `Idempotency-Key` is currently being processed."

    send(task.pid, :continue)
    Task.await(task)
  end

  @tag capture_log: true
  test "with halted response", %{conn: conn, tracker: tracker} do
    Process.flag(:trap_exit, true)
    task = Task.async(fn -> run_plug(conn, tracker, callback: fn _conn -> raise "failed" end) end)
    {{%RuntimeError{}, _}, _} = catch_exit(Task.await(task))

    conn = run_plug(conn, tracker)

    assert conn.halted
    assert json = json_response(conn, 500)
    assert json["message"] =~ "The original request was interrupted and can't be recovered as it's in an unknown state."
    assert expires(conn)
  end

  test "with cached response", %{conn: conn, tracker: tracker} do
    other_conn =
      run_plug(conn, tracker, callback: fn conn ->
        conn
        |> put_resp_header("x-header-key", "header-value")
        |> send_resp(201, "OTHER")
      end)

    conn = run_plug(conn, tracker)

    assert conn.halted
    assert conn.status == 201
    assert conn.resp_body == "OTHER"
    assert expires(conn) == expires(other_conn)
    assert get_resp_header(conn, "x-header-key") == ["header-value"]
  end

  test "with cached response with different request payload", %{conn: conn, tracker: tracker} do
    _other_conn = run_plug(%{conn | params: %{"other_key" => "1"}}, tracker, callback: &send_resp(&1, 201, "OTHER"))

    conn = run_plug(conn, tracker)

    assert conn.halted
    assert json = json_response(conn, 422)
    assert json["message"] =~ "This `Idempotency-Key` can't be reused with a different payload or URI."
  end

  test "with cached response with different request URI", %{conn: conn, tracker: tracker} do
    _other_conn = run_plug(%{conn | path_info: ["other", "path"]}, tracker, callback: &send_resp(&1, 201, "OTHER"))

    conn = run_plug(conn, tracker)

    refute conn.halted
    assert conn.status == 200
    assert conn.resp_body == "OK"
  end

  defmodule TestHandler do
    @behaviour IdempotencyPlug.Handler

    @impl true
    def idempotent_id(_conn, id), do: "custom:#{id}"

    @impl true
    def resp_error(conn, _error) do
      Plug.Conn.resp(conn, 418, "I'm a teapot")
    end
  end

  test "with custom handler", %{conn: conn, tracker: tracker} do
    resp_conn = run_plug(conn, tracker, handler: TestHandler)

    refute resp_conn.halted
    assert resp_conn.status == 200

    resp_conn = run_plug(%{conn | params: %{"other_key" => "1"}}, tracker, handler: TestHandler)

    assert resp_conn.halted
    assert resp_conn.status == 418
    assert resp_conn.resp_body == "I'm a teapot"
  end

  defp setup_tracker(_) do
    tracker = start_supervised!({RequestTracker, [name: __MODULE__]})

    %{tracker: tracker}
  end

  defp setup_request(_) do
    conn =
      %Plug.Conn{}
      |> Plug.Adapters.Test.Conn.conn("POST", "/my/path", nil)
      |> put_req_header("idempotency-key", "key")
      |> Map.put(:params, %{"a" => 1, "b" => 2})

    %{conn: conn}
  end

  defp run_plug(conn, tracker, opts \\ []) do
    {callback, opts} = Keyword.pop(opts, :callback)
    callback = callback || &send_resp(&1, 200, "OK")

    conn
    |> IdempotencyPlug.call(IdempotencyPlug.init([tracker: tracker] ++ opts))
    |> case do
      %{halted: true} = conn -> send_resp(conn)
      conn -> callback.(conn)
    end
  end

  def json_response(conn, status \\ 200) do
    assert conn.status == status
    assert ["application/json" <> _] = get_resp_header(conn, "content-type")

    Jason.decode!(conn.resp_body)
  end

  def expires(conn) do
    case get_resp_header(conn, "expires") do
      [expires] -> expires
      [] -> nil
    end
  end
end
