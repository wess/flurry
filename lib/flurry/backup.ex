defmodule Flurry.Backup do
  @moduledoc "Configuration and status for DevOps-managed object backups. No network operations."

  def status do
    inspect_config(Application.get_env(:flurry, :backup, []), %{
      access_key: present?(System.get_env("FLURRY_SPACES_ACCESS_KEY_ID")),
      secret_key: present?(System.get_env("FLURRY_SPACES_SECRET_ACCESS_KEY"))
    })
  end

  def inspect_config(options, credentials \\ %{}) do
    provider = Keyword.get(options, :provider, "spaces")
    region = text(Keyword.get(options, :region))
    bucket = text(Keyword.get(options, :bucket))
    prefix = text(Keyword.get(options, :prefix)) || "flurry"

    valid =
      provider in ["none", "spaces"] and
        (is_nil(region) or Regex.match?(~r/\A[a-z]{3}[0-9]{1,2}\z/, region)) and
        (is_nil(bucket) or Regex.match?(~r/\A[a-z0-9][a-z0-9-]{1,61}[a-z0-9]\z/, bucket)) and
        byte_size(prefix) <= 200 and
        Enum.all?(String.split(prefix, "/"), &Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9.-]*\z/, &1))

    credentials_ready = credentials[:access_key] == true and credentials[:secret_key] == true

    %{
      provider: if(provider in ["none", "spaces"], do: provider, else: "invalid"),
      valid: valid,
      configured:
        provider == "spaces" and valid and not is_nil(region) and not is_nil(bucket) and
          credentials_ready,
      credentials_configured: credentials_ready,
      automatic: false,
      managed_by: "devops",
      region: if(valid, do: region),
      bucket: if(valid, do: bucket),
      endpoint: if(valid and region, do: "https://#{region}.digitaloceanspaces.com"),
      prefix: if(valid, do: prefix),
      object_prefix: if(valid, do: prefix <> "/objects/v1")
    }
  end

  def description do
    status = status()

    cond do
      not status.valid ->
        "Invalid backup configuration; check the Spaces environment settings"

      status.provider == "none" ->
        "Backups disabled; no automatic backup job is installed"

      status.configured ->
        "DigitalOcean Spaces configuration supplied; DevOps must install and monitor the backup job"

      true ->
        "DigitalOcean Spaces selected; region, bucket, credentials, and DevOps backup job are pending"
    end
  end

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp text(_), do: nil
  defp present?(value), do: not is_nil(text(value))
end
