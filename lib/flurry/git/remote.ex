defmodule Flurry.Git.Remote do
  alias Flurry.{Error, Auth}

  def parse(url, branch \\ nil) do
    unless is_binary(url) and byte_size(url) <= 1000,
      do: Error.fail("Enter an HTTPS Git repository URL")

    uri = URI.parse(String.trim(url))
    host = String.downcase(uri.host || "")
    allowed = Flurry.Instance.hosts()

    unless uri.scheme == "https" and uri.port == 443 and host in allowed and
             is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment),
           do:
             Error.fail(
               "Use an HTTPS URL from an allowed Git host; credentials belong in the token field"
             )

    path = uri.path || ""

    unless Regex.match?(~r{\A/[a-zA-Z0-9_.~-]+(?:/[a-zA-Z0-9_.~-]+)+/?\z}, path) and
             Enum.all?(String.split(path, "/", trim: true), &(&1 not in [".", ".."])),
           do: Error.fail("Use the repository clone URL, not a file or branch URL")

    path = String.trim_trailing(path, "/")
    path = if String.ends_with?(path, ".git"), do: path, else: path <> ".git"
    branch = if branch in [nil, ""], do: nil, else: branch!(branch)
    %{url: "https://#{host}#{path}", host: host, branch: branch}
  end

  def connect(remote) do
    case :inet.getaddrs(String.to_charlist(remote.host), :inet) do
      {:ok, addresses} ->
        unless addresses != [] and Enum.all?(addresses, &public?/1),
          do: Error.fail("Git hosts must resolve to public addresses")

        Map.put(remote, :address, addresses |> hd() |> :inet.ntoa() |> to_string())

      _ ->
        Error.fail("The Git host could not be resolved; try again", 502)
    end
  end

  def credentials(attrs) do
    token = attrs["token"] || ""
    username = if attrs["username"] in [nil, ""], do: "git", else: attrs["username"]

    unless is_binary(token) and byte_size(token) <= 4096 and
             not String.contains?(token, ["\r", "\n", <<0>>]),
           do: Error.fail("Invalid access token")

    username = Auth.text!(username, "Git username", 200)

    if String.contains?(username, [":", "\r", "\n", <<0>>]),
      do: Error.fail("Invalid Git username")

    %{token: token, username: username}
  end

  def branch!(value) do
    unless is_binary(value) and byte_size(value) in 1..200 and
             Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9._\/-]*\z/, value) and
             not String.contains?(value, ["..", "//", "@{"]) and
             Enum.all?(
               String.split(value, "/"),
               &(not String.starts_with?(&1, ".") and not String.ends_with?(&1, [".lock", "."]) and
                   &1 != "")
             ),
           do: Error.fail("Invalid branch name")

    value
  end

  defp public?({a, b, c, _}) do
    not (a in [0, 10, 127] or a >= 224 or
           (a == 100 and b in 64..127) or (a == 169 and b == 254) or
           (a == 172 and b in 16..31) or (a == 192 and b in [0, 168]) or
           (a == 192 and b == 0 and c == 2) or (a == 198 and b in [18, 19, 51]) or
           (a == 203 and b == 0 and c == 113))
  end
end
