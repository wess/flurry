defmodule Flurry.Http.Body do
  def init(options), do: options

  def call(conn, _) do
    lfs_upload =
      conn.method == "PUT" and
        Regex.match?(~r|/info/lfs/objects/[0-9a-f]{64}\z|, conn.request_path)

    if lfs_upload or
         String.ends_with?(conn.request_path, ["/git-upload-pack", "/git-receive-pack"]) do
      conn
    else
      parse(conn)
    end
  end

  defp parse(conn) do
    length =
      if String.ends_with?(conn.request_path, ["/changesets", "/pushes"]) and conn.assigns.user,
        do: max(8_388_608, min(146_800_640, file_limit(conn) * 2)),
        else: 1_048_576

    length =
      if String.ends_with?(conn.request_path, "/pushes") and conn.assigns.user,
        do:
          (
            file_limit(conn)
            146_800_640
          ),
        else: length

    Plug.Parsers.call(
      conn,
      Plug.Parsers.init(
        parsers: [:json],
        json_decoder: Jason,
        length: length,
        pass: [],
        body_reader: {__MODULE__, :read_body, []}
      )
    )
  end

  defp file_limit(conn) do
    case conn.path_info do
      ["api", "repositories", id, action] when action in ["changesets", "pushes"] ->
        case Ecto.UUID.cast(id) do
          {:ok, _} ->
            repository = Flurry.Engine.Repositories.get(conn.assigns.user, id, :write)
            Flurry.Quota.file_limit(Flurry.Repo.get!(Flurry.Schema.User, repository.owner_id))

          _ ->
            Flurry.Quota.file_limit(conn.assigns.user)
        end

      _ ->
        Flurry.Quota.file_limit(conn.assigns.user)
    end
  end

  def read_body(conn, options) do
    case Plug.Conn.read_body(conn, options) do
      {status, bytes, conn} when status in [:ok, :more] ->
        {status, bytes, conn}

      result ->
        result
    end
  end
end
