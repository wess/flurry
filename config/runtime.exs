import Config

if url = System.get_env("DATABASE_URL"), do: config(:flurry, Flurry.Repo, url: url)
if store = System.get_env("FLURRY_STORE"), do: config(:flurry, store: Path.expand(store))
if port = System.get_env("PORT"), do: config(:flurry, port: String.to_integer(port))

storage_driver = System.get_env("FLURRY_STORAGE_DRIVER", "local")

unless storage_driver in ["local", "s3"],
  do: raise("FLURRY_STORAGE_DRIVER must be local or s3")

storage =
  for {variable, key} <- [
        {"FLURRY_S3_ENDPOINT", :endpoint},
        {"FLURRY_S3_BUCKET", :bucket},
        {"FLURRY_S3_REGION", :region},
        {"FLURRY_S3_PREFIX", :prefix},
        {"FLURRY_S3_ACCESS_KEY_ID", :access_key_id},
        {"FLURRY_S3_SECRET_ACCESS_KEY", :secret_access_key}
      ],
      into: %{},
      do: {key, System.get_env(variable)}

s3_supplied =
  Enum.any?([storage.bucket, storage.access_key_id, storage.secret_access_key], fn value ->
    is_binary(value) and String.trim(value) != ""
  end)

if storage_driver == "s3" or s3_supplied do
  if Enum.any?(storage, fn {_, value} -> not is_binary(value) or String.trim(value) == "" end),
    do: raise("All FLURRY_S3_* settings are required when FLURRY_STORAGE_DRIVER=s3")

  uri = URI.parse(storage.endpoint)

  unless uri.scheme == "https" and is_binary(uri.host) and is_nil(uri.userinfo) and
           is_nil(uri.query) and is_nil(uri.fragment) and uri.path in [nil, "", "/"],
         do: raise("FLURRY_S3_ENDPOINT must be an HTTPS origin")

  unless Regex.match?(~r/\A[a-z0-9][a-z0-9-]{1,61}[a-z0-9]\z/, storage.bucket),
    do: raise("FLURRY_S3_BUCKET must be a valid bucket name")

  unless Regex.match?(~r/\A[a-z0-9-]+\z/, storage.region),
    do: raise("FLURRY_S3_REGION must be a valid region")

  prefix = String.trim(storage.prefix, "/")

  unless byte_size(prefix) in 1..200 and
           Enum.all?(
             String.split(prefix, "/"),
             &Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9.-]*\z/, &1)
           ),
         do: raise("FLURRY_S3_PREFIX must contain safe path segments")

  config :flurry,
    storage_s3: %{storage | endpoint: String.trim_trailing(storage.endpoint, "/"), prefix: prefix}
end

config :flurry,
  object_driver: if(storage_driver == "s3", do: Flurry.Store.S3, else: Flurry.Store.Local)

if port = System.get_env("FLURRY_SSH_PORT") do
  case Integer.parse(port) do
    {value, ""} when value in 1..65_535 -> config(:flurry, ssh_port: value)
    _ -> raise "FLURRY_SSH_PORT must be an integer from 1 to 65535"
  end
end

if directory = System.get_env("FLURRY_SSH_HOST_KEY_DIR") do
  unless Path.type(directory) == :absolute,
    do: raise("FLURRY_SSH_HOST_KEY_DIR must be an absolute directory")

  config(:flurry, ssh_host_key_dir: directory)
end

case {System.get_env("FLURRY_SSH_PORT"), System.get_env("FLURRY_SSH_HOST_KEY_DIR")} do
  {nil, nil} -> :ok
  {nil, _} -> raise "FLURRY_SSH_PORT is required with FLURRY_SSH_HOST_KEY_DIR"
  {_, nil} -> raise "FLURRY_SSH_HOST_KEY_DIR is required with FLURRY_SSH_PORT"
  {_, _} -> :ok
end

if sendmail = System.get_env("FLURRY_SENDMAIL_PATH") do
  unless Path.type(sendmail) == :absolute,
    do: raise("FLURRY_SENDMAIL_PATH must be an absolute executable path")

  config(:flurry, sendmail_path: sendmail)
end

mail =
  for {variable, key} <- [
        {"FLURRY_MAIL_API_URL", :url},
        {"FLURRY_MAIL_API_KEY", :api_key},
        {"FLURRY_MAIL_FROM", :from}
      ],
      value = System.get_env(variable),
      into: %{},
      do: {key, value}

if map_size(mail) not in [0, 3],
  do: raise("FLURRY_MAIL_API_URL, FLURRY_MAIL_API_KEY, and FLURRY_MAIL_FROM must be set together")

if map_size(mail) == 3 do
  uri = URI.parse(mail.url)

  unless uri.scheme == "https" and is_binary(uri.host) and uri.path not in [nil, ""] and
           is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment),
         do: raise("FLURRY_MAIL_API_URL must be an HTTPS API URL")

  config :flurry, :mail, %{mail | url: String.trim_trailing(mail.url, "/")}
end

if limit = System.get_env("FLURRY_RATE_LIMIT") do
  case Integer.parse(limit) do
    {value, ""} when value in 1..10_000 -> config(:flurry, rate_limit: value)
    _ -> raise "FLURRY_RATE_LIMIT must be an integer from 1 to 10000"
  end
end

if limit = System.get_env("FLURRY_API_RATE_LIMIT") do
  case Integer.parse(limit) do
    {value, ""} when value in 1..100_000 -> config(:flurry, api_rate_limit: value)
    _ -> raise "FLURRY_API_RATE_LIMIT must be an integer from 1 to 100000"
  end
end

if host = System.get_env("FLURRY_HOST") do
  {:ok, address} = :inet.parse_address(String.to_charlist(host))
  config :flurry, host: address
end

if proxies = System.get_env("FLURRY_TRUSTED_PROXIES") do
  addresses =
    proxies
    |> String.split(",", trim: true)
    |> Enum.map(fn value ->
      case :inet.parse_address(value |> String.trim() |> String.to_charlist()) do
        {:ok, address} -> address
        _ -> raise "FLURRY_TRUSTED_PROXIES must contain only comma-separated IP addresses"
      end
    end)

  config :flurry, trusted_proxies: addresses
end

config :flurry, secure_cookies: System.get_env("FLURRY_SECURE_COOKIES") == "true"

public_url =
  case System.get_env("FLURRY_PUBLIC_URL") do
    nil ->
      nil

    origin ->
      uri = URI.parse(origin)

      unless uri.scheme in ["http", "https"] and is_binary(uri.host) and is_nil(uri.userinfo) and
               is_nil(uri.query) and is_nil(uri.fragment) and uri.path in [nil, "/"],
             do: raise("FLURRY_PUBLIC_URL must be a server origin")

      if uri.scheme == "http" and uri.host not in ["localhost", "127.0.0.1"],
        do: raise("Public URLs must use HTTPS")

      String.trim_trailing(origin, "/")
  end

if public_url, do: config(:flurry, :public_url, public_url)

allowed_origins =
  System.get_env("FLURRY_ALLOWED_ORIGINS", "")
  |> String.split(",", trim: true)
  |> Enum.map(fn origin ->
    origin = String.trim(origin)
    uri = URI.parse(origin)

    unless uri.scheme == "https" and is_binary(uri.host) and is_nil(uri.userinfo) and
             is_nil(uri.query) and is_nil(uri.fragment) and uri.path in [nil, "", "/"],
           do: raise("FLURRY_ALLOWED_ORIGINS must contain comma-separated HTTPS origins")

    String.trim_trailing(origin, "/")
  end)

config(:flurry, :allowed_origins, allowed_origins)

if cookie_domain = System.get_env("FLURRY_COOKIE_DOMAIN") do
  unless Regex.match?(~r/\A\.[a-z0-9.-]+\z/, cookie_domain),
    do: raise("FLURRY_COOKIE_DOMAIN must begin with a dot and contain a DNS domain")

  config(:flurry, :cookie_domain, cookie_domain)
end

encryption_key =
  case System.get_env("FLURRY_SECRET_KEY") do
    nil ->
      nil

    secret ->
      case Base.decode64(secret) do
        {:ok, key} when byte_size(key) == 32 -> key
        _ -> raise "FLURRY_SECRET_KEY must be a base64-encoded 32-byte key"
      end
  end

if encryption_key, do: config(:flurry, :encryption_key, encryption_key)

source_providers =
  [
    {"github", "GitHub", "github.com", "https://github.com/login/oauth/authorize",
     "https://github.com/login/oauth/access_token", "https://api.github.com",
     "repo offline_access", ["repo"], "FLURRY_GITHUB_CLIENT_ID", "FLURRY_GITHUB_CLIENT_SECRET"},
    {"gitlab", "GitLab", "gitlab.com", "https://gitlab.com/oauth/authorize",
     "https://gitlab.com/oauth/token", "https://gitlab.com/api/v4", "read_api read_repository",
     ["read_api", "read_repository"], "FLURRY_GITLAB_CLIENT_ID", "FLURRY_GITLAB_CLIENT_SECRET"}
  ]
  |> Enum.reduce(%{}, fn {provider, name, host, authorize, token, api, scope, required_scopes,
                          id_env, secret_env},
                         providers ->
    case {System.get_env(id_env), System.get_env(secret_env)} do
      {nil, nil} ->
        providers

      {client_id, client_secret}
      when is_binary(client_id) and client_id != "" and is_binary(client_secret) and
             client_secret != "" ->
        Map.put(providers, provider, %{
          provider: provider,
          name: name,
          host: host,
          authorize_url: authorize,
          token_url: token,
          api_url: api,
          scope: scope,
          required_scopes: required_scopes,
          client_id: client_id,
          client_secret: client_secret
        })

      _ ->
        raise "#{id_env} and #{secret_env} must be set together"
    end
  end)

if map_size(source_providers) > 0 do
  unless is_binary(public_url),
    do: raise("FLURRY_PUBLIC_URL is required when source providers are configured")

  unless is_binary(encryption_key),
    do: raise("FLURRY_SECRET_KEY is required when source providers are configured")

  config(:flurry, :source_providers, source_providers)
end

if hosts = System.get_env("FLURRY_GIT_HOSTS") do
  config :flurry,
    git_hosts:
      hosts |> String.split(",", trim: true) |> Enum.map(&(String.trim(&1) |> String.downcase()))
end

# selection and configuration only; deployment tooling manages backup jobs
config :flurry, :backup,
  provider: System.get_env("FLURRY_BACKUP_PROVIDER", "spaces"),
  region: System.get_env("FLURRY_SPACES_REGION"),
  bucket: System.get_env("FLURRY_SPACES_BUCKET"),
  prefix: System.get_env("FLURRY_SPACES_PREFIX", "flurry")
