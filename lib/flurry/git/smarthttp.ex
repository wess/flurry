defmodule Flurry.Git.SmartHttp do
  alias Flurry.{Error, Git.Command, Git.Mirror}

  @max_request 146_800_640

  def advertise(repository, service) when service in ["git-upload-pack", "git-receive-pack"] do
    Mirror.with_repository(repository, fn directory ->
      command = if service == "git-upload-pack", do: "upload-pack", else: "receive-pack"

      output =
        Command.run(directory, [command, "--stateless-rpc", "--advertise-refs", directory],
          limit: 16_777_216
        )

      packet("# service=#{service}\n") <> "0000" <> output
    end)
  end

  def advertise(_, _), do: Error.fail("Unsupported Git service", 403)

  def upload(repository, body) when byte_size(body) <= @max_request do
    Mirror.with_repository(repository, fn directory ->
      input = Path.join(directory, "request")
      File.write!(input, body, [:binary, :exclusive])

      Command.run(directory, ["upload-pack", "--stateless-rpc", directory],
        input: input,
        limit: 268_435_456,
        timeout: 120_000
      )
    end)
  end

  def upload(_, _), do: Error.fail("Git request is too large", 413)

  def receive(repository, user, body) when byte_size(body) <= @max_request do
    Mirror.with_repository(repository, fn directory ->
      input = Path.join(directory, "request")
      updates = Path.join(directory, "updates")
      hook = Path.join([directory, "hooks", "pre-receive"])
      File.write!(input, body, [:binary, :exclusive])
      File.mkdir_p!(Path.dirname(hook))

      File.write!(
        hook,
        "#!/bin/sh\ncat > \"$FLURRY_UPDATES\"\ncount=$(wc -l < \"$FLURRY_UPDATES\")\n[ \"$count\" -eq 1 ] || { echo 'push one ref at a time' >&2; exit 1; }\n",
        [:binary, :exclusive]
      )

      File.chmod!(hook, 0o700)

      output =
        Command.run(directory, ["receive-pack", "--stateless-rpc", directory],
          input: input,
          env: [{"FLURRY_UPDATES", updates}],
          hooks: true,
          limit: 268_435_456,
          timeout: 120_000
        )

      if File.exists?(updates) do
        update = File.read!(updates)
        Flurry.Git.Import.apply(repository, user, directory, update)
      end

      output
    end)
  end

  def receive(_, _, _), do: Error.fail("Git request is too large", 413)

  def read_body(conn, limit \\ @max_request) do
    {body, conn} = read_chunks(conn, limit, [], 0)

    body =
      case Plug.Conn.get_req_header(conn, "content-encoding") do
        [] ->
          body

        ["gzip"] ->
          try do
            :zlib.gunzip(body)
          rescue
            _ -> Error.fail("Git request compression is invalid")
          end

        _ ->
          Error.fail("Git request compression is not supported", 415)
      end

    if byte_size(body) > limit, do: Error.fail("Git request is too large", 413)
    {body, conn}
  end

  defp read_chunks(conn, limit, chunks, size) do
    case Plug.Conn.read_body(conn, length: limit, read_length: 1_048_576, read_timeout: 30_000) do
      {:ok, bytes, conn} ->
        total = size + byte_size(bytes)
        if total > limit, do: Error.fail("Git request is too large", 413)
        {IO.iodata_to_binary(Enum.reverse([bytes | chunks])), conn}

      {:more, bytes, conn} ->
        total = size + byte_size(bytes)
        if total > limit, do: Error.fail("Git request is too large", 413)
        read_chunks(conn, limit, [bytes | chunks], total)

      {:error, _} ->
        Error.fail("Could not read Git request")
    end
  end

  defp packet(data) do
    (byte_size(data) + 4)
    |> Integer.to_string(16)
    |> String.pad_leading(4, "0")
    |> Kernel.<>(data)
  end
end
