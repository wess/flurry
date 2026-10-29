defmodule Flurry.StorageTest do
  use ExUnit.Case, async: false
  alias Flurry.Store.{Objects, S3}

  setup do
    old_driver = Application.get_env(:flurry, :object_driver)
    old_config = Application.get_env(:flurry, :storage_s3)
    old_options = Application.get_env(:flurry, :s3_req_options)

    config = %{
      endpoint: "https://nyc3.digitaloceanspaces.com",
      bucket: "flurry-test",
      region: "nyc3",
      prefix: "flurry",
      access_key_id: "test-access",
      secret_access_key: "test-secret"
    }

    {:ok, store} = Agent.start_link(fn -> %{} end)
    Req.Test.stub(__MODULE__, &object_store(&1, store))
    Application.put_env(:flurry, :object_driver, S3)
    Application.put_env(:flurry, :storage_s3, config)
    Application.put_env(:flurry, :s3_req_options, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      restore(:object_driver, old_driver)
      restore(:storage_s3, old_config)
      restore(:s3_req_options, old_options)
    end)

    %{store: store, config: config}
  end

  test "S3 storage writes immutable content-addressed objects and reads them back", %{
    store: store,
    config: config
  } do
    hash = Objects.put(:blob, "stored remotely\n")
    assert Objects.get(:blob, hash) == "stored remotely\n"
    assert S3.key(hash, config) == "flurry/objects/v1/#{String.slice(hash, 0, 2)}/#{hash}"

    assert Agent.get(store, &Map.keys/1) == [
             "/flurry-test/flurry/objects/v1/#{String.slice(hash, 0, 2)}/#{hash}"
           ]
  end

  defp object_store(conn, store) do
    path = conn.request_path

    case conn.method do
      "PUT" ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        Agent.update(store, &Map.put_new(&1, path, body))
        Plug.Conn.send_resp(conn, 204, "")

      "GET" ->
        case Agent.get(store, &Map.get(&1, path)) do
          nil -> Plug.Conn.send_resp(conn, 404, "")
          body -> Plug.Conn.send_resp(conn, 200, body)
        end
    end
  end

  defp restore(key, nil), do: Application.delete_env(:flurry, key)
  defp restore(key, value), do: Application.put_env(:flurry, key, value)
end
