defmodule IdempotencyPlug.ETSStoreTest do
  use ExUnit.Case

  alias IdempotencyPlug.ETSStore

  @options [table: __MODULE__]
  @request_id :sha256 |> :crypto.hash("key") |> Base.encode16() |> String.downcase()
  @data {:ok, %{resp_body: "OK", resp_headers: [], status: 200}}
  @updated_data {:halted, :terminated}

  test "setup" do
    assert ETSStore.setup(@options) == :ok

    assert ETSStore.setup([]) ==
      {:error, ":table must be specified in options for IdempotencyPlug.ETSStore"}
  end

  test "inserts, looks up, and updates" do
    :ok = ETSStore.setup(@options)

    assert ETSStore.lookup(@request_id, @options) == :not_found

    expires_at = DateTime.utc_now()
    assert ETSStore.insert(@request_id, @data, "fingerprint", expires_at, @options) == :ok
    assert ETSStore.insert(@request_id, @data, "fingerprint", expires_at, @options) == {:error, "key #{@request_id} already exists in store"}

    assert ETSStore.lookup(@request_id, @options) == {@data, "fingerprint", expires_at}

    updated_expires_at = DateTime.utc_now()
    assert ETSStore.update("#{@request_id}-other", @updated_data, updated_expires_at, @options) == {:error, "key #{@request_id}-other not found in store"}
    assert ETSStore.update(@request_id, @updated_data, updated_expires_at, @options) == :ok

    assert ETSStore.lookup(@request_id, @options) == {@updated_data, "fingerprint", updated_expires_at}
  end

  test "prunes" do
    :ok = ETSStore.setup(@options)

    expired = DateTime.add(DateTime.utc_now(), -1, :second)
    not_expired = DateTime.add(DateTime.utc_now(), 1, :second)

    assert ETSStore.insert("#{@request_id}-expired", @data, "fingerprint", expired, @options) == :ok
    assert ETSStore.insert("#{@request_id}-not-expired", @data, "fingerprint", not_expired, @options) == :ok

    assert ETSStore.prune(@options) == :ok

    assert ETSStore.lookup("#{@request_id}-expired", @options) == :not_found
    refute ETSStore.lookup("#{@request_id}-not-expired", @options) == :not_found
  end
end
