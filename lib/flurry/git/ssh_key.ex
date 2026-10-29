defmodule Flurry.Git.SshKey do
  @behaviour :ssh_server_key_api

  alias Flurry.Engine.Keys

  @impl true
  def host_key(algorithm, options), do: :ssh_file.host_key(algorithm, options)

  @impl true
  def is_auth_key(public_key, username, _options) do
    blob = public_key |> :ssh_file.encode(:ssh2_pubkey) |> IO.iodata_to_binary()
    fingerprint = "SHA256:" <> (:crypto.hash(:sha256, blob) |> Base.encode64(padding: false))
    Keys.ssh_authenticated?(List.to_string(username), fingerprint)
  rescue
    _ -> false
  end
end
