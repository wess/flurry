defmodule Flurry.Git.Command do
  alias Flurry.Error

  @settings [
    {"protocol.allow", "never"},
    {"protocol.https.allow", "always"},
    {"http.followRedirects", "false"},
    {"http.sslVerify", "true"},
    {"http.proxy", ""},
    {"http.lowSpeedLimit", "1024"},
    {"http.lowSpeedTime", "20"},
    {"credential.helper", ""},
    {"core.hooksPath", "/dev/null"},
    {"core.attributesFile", "/dev/null"},
    {"gc.auto", "0"},
    {"fetch.fsckObjects", "true"}
  ]

  def run(directory, args, options \\ []) do
    executable =
      System.find_executable("git") ||
        Error.fail("Git must be installed on the Flurry server", 503)

    remote = options[:remote]
    credentials = options[:credentials] || %{token: "", username: "git"}

    network =
      if remote, do: [{"http.curloptResolve", "#{remote.host}:443:#{remote.address}"}], else: []

    auth =
      if remote && credentials.token != "",
        do: [
          {"http.#{remote.url}.extraHeader",
           "Authorization: Basic " <>
             Base.encode64(credentials.username <> ":" <> credentials.token)}
        ],
        else: []

    base_settings =
      if options[:hooks],
        do: Enum.reject(@settings, fn {key, _} -> key == "core.hooksPath" end),
        else: @settings

    {empty, settings} =
      Enum.split_with(base_settings ++ network ++ auth, fn {_, value} -> value == "" end)

    arguments = Enum.flat_map(empty, fn {key, _} -> ["-c", key <> "="] end) ++ args

    inherited =
      System.get_env()
      |> Map.keys()
      |> Enum.filter(
        &(String.starts_with?(&1, "GIT_") or
            String.downcase(&1) in ["http_proxy", "https_proxy", "all_proxy"])
      )
      |> Enum.map(&{&1, false})

    env =
      inherited ++
        [
          {"GIT_CONFIG_NOSYSTEM", "1"},
          {"GIT_CONFIG_GLOBAL", "/dev/null"},
          {"GIT_TERMINAL_PROMPT", "0"},
          {"GIT_ASKPASS", "/usr/bin/false"},
          {"GIT_CONFIG_COUNT", to_string(length(settings))},
          {"LC_ALL", "C"}
        ] ++
        Enum.flat_map(Enum.with_index(settings), fn {{key, value}, index} ->
          [{"GIT_CONFIG_KEY_#{index}", key}, {"GIT_CONFIG_VALUE_#{index}", value}]
        end) ++ (options[:env] || [])

    {executable, arguments} =
      case options[:input] do
        nil ->
          {executable, arguments}

        input ->
          unless is_binary(input) and Path.type(input) == :absolute,
            do: Error.fail("Git input path must be absolute", 500)

          script = ~s(input=$1; shift; exec "$@" < "$input")
          {"/bin/sh", ["-c", script, "flurry-git", input, executable | arguments]}
      end

    port =
      Port.open({:spawn_executable, String.to_charlist(executable)}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        {:args, Enum.map(arguments, &String.to_charlist/1)},
        {:cd, String.to_charlist(directory)},
        {:env,
         Enum.map(env, fn {key, value} ->
           {String.to_charlist(key),
            if(value == false, do: false, else: String.to_charlist(value))}
         end)}
      ])

    try do
      collect(
        port,
        [],
        0,
        System.monotonic_time(:millisecond) + (options[:timeout] || 120_000),
        options[:limit] || 4_194_304,
        if(remote, do: directory, else: nil)
      )
    rescue
      error in Error -> Error.fail("Git #{hd(args)}: #{error.message}", error.status)
    after
      if Port.info(port) do
        case Port.info(port, :os_pid) do
          {:os_pid, pid} ->
            System.cmd("/bin/kill", ["-TERM", to_string(pid)], stderr_to_stdout: true)

          _ ->
            :ok
        end

        Port.close(port)
      end
    end
  end

  defp collect(port, chunks, size, deadline, limit, directory) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    if remaining == 0,
      do: Error.fail("Git transfer timed out; try again with a smaller repository", 504)

    receive do
      {^port, {:data, bytes}} ->
        if size + byte_size(bytes) > limit,
          do: Error.fail("Git response exceeded the transfer limit", 413)

        collect(port, [bytes | chunks], size + byte_size(bytes), deadline, limit, directory)

      {^port, {:exit_status, 0}} ->
        check_size!(directory)
        chunks |> Enum.reverse() |> IO.iodata_to_binary()

      {^port, {:exit_status, _}} ->
        # Git output can contain remote-provided text or credentials; never persist it
        Error.fail(
          "Git transfer failed. Check the repository URL, branch, token permissions, and branch protection rules.",
          422
        )
    after
      min(remaining, 500) ->
        check_size!(directory)
        collect(port, chunks, size, deadline, limit, directory)
    end
  end

  defp check_size!(nil), do: :ok

  defp check_size!(directory) do
    :filelib.fold_files(
      String.to_charlist(directory),
      ~c".*",
      true,
      fn path, total ->
        size =
          case File.stat(path) do
            {:ok, stat} -> stat.size
            _ -> 0
          end

        if total + size > 268_435_456,
          do: Error.fail("Git transfer exceeded 256 MiB of temporary storage", 413)

        total + size
      end,
      0
    )
  end
end
