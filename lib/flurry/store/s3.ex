defmodule Flurry.Store.S3 do
  alias Flurry.Error

  def put(hash, compressed), do: put(hash, compressed, config())
  def get(hash), do: get(hash, config())

  def put(hash, compressed, config) do
    case request(:put, hash, compressed, config) do
      {:ok, %{status: status}} when status in [200, 201, 204] -> :ok
      _ -> Error.fail("Object storage could not persist this file", 503)
    end
  end

  def get(hash, config) do
    case request(:get, hash, nil, config) do
      {:ok, %{status: 200, body: body}} when is_binary(body) -> body
      {:ok, %{status: 404}} -> Error.fail("A repository object is missing", 500)
      _ -> Error.fail("Object storage could not read this file", 503)
    end
  end

  def key(hash, config \\ config()) do
    prefix = String.trim(config.prefix, "/")
    Enum.join([prefix, "objects", "v1", String.slice(hash, 0, 2), hash], "/")
  end

  def config, do: Application.fetch_env!(:flurry, :storage_s3)

  defp request(method, hash, body, config) do
    options = [
      aws_endpoint_url_s3: config.endpoint,
      aws_sigv4: [
        access_key_id: config.access_key_id,
        secret_access_key: config.secret_access_key,
        region: config.region
      ],
      connect_options: [timeout: 5_000],
      receive_timeout: 30_000,
      retry: false,
      redirect: false,
      decode_body: false
    ]

    options = Keyword.merge(options, Application.get_env(:flurry, :s3_req_options, []))
    request = Req.new() |> ReqS3.attach(options)
    request_options = [method: method, url: "s3://#{config.bucket}/#{key(hash, config)}"]

    request_options =
      if is_binary(body), do: Keyword.put(request_options, :body, body), else: request_options

    Req.request(request, request_options)
  end
end
