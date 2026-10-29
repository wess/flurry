defmodule Flurry.Integrations.SourceProvider do
  alias Flurry.Error

  def exchange(config, code, redirect_uri) do
    token_request(config, %{
      "client_id" => config.client_id,
      "client_secret" => config.client_secret,
      "code" => code,
      "grant_type" => "authorization_code",
      "redirect_uri" => redirect_uri
    })
  end

  def refresh(config, refresh_token) do
    token_request(config, %{
      "client_id" => config.client_id,
      "client_secret" => config.client_secret,
      "refresh_token" => refresh_token,
      "grant_type" => "refresh_token"
    })
  end

  def account(config, token) do
    body = get!(config.api_url <> "/user", token, [])
    account = body["login"] || body["username"]

    unless is_binary(account) and byte_size(account) in 1..200,
      do: Error.fail("The source provider returned an invalid account", 502)

    account
  end

  def repositories(%{provider: "github"} = config, token, query) do
    get!(config.api_url <> "/user/repos", token,
      per_page: 100,
      sort: "updated",
      affiliation: "owner,collaborator,organization_member"
    )
    |> filter(query)
    |> Enum.map(fn repository ->
      %{
        id: to_string(repository["id"]),
        name: repository["name"],
        full_name: repository["full_name"],
        description: repository["description"] || "",
        url: repository["clone_url"],
        branch: repository["default_branch"],
        private: repository["private"] == true
      }
    end)
  end

  def repositories(%{provider: "gitlab"} = config, token, query) do
    get!(config.api_url <> "/projects", token,
      membership: true,
      simple: true,
      per_page: 100,
      order_by: "last_activity_at",
      sort: "desc"
    )
    |> filter(query)
    |> Enum.map(fn repository ->
      %{
        id: to_string(repository["id"]),
        name: repository["path"],
        full_name: repository["path_with_namespace"],
        description: repository["description"] || "",
        url: repository["http_url_to_repo"],
        branch: repository["default_branch"],
        private: repository["visibility"] != "public"
      }
    end)
  end

  defp token_request(config, form) do
    response =
      request(:post,
        url: config.token_url,
        form: form,
        headers: [{"accept", "application/json"}]
      )

    body = response.body
    token = is_map(body) && body["access_token"]

    unless response.status in 200..299 and is_binary(token) and byte_size(token) in 1..4096,
      do: Error.fail("The source provider did not authorize this connection", 502)

    expires_at =
      case body["expires_in"] do
        seconds when is_integer(seconds) and seconds > 0 ->
          DateTime.add(DateTime.utc_now(), seconds)

        _ ->
          nil
      end

    %{
      access_token: token,
      refresh_token: valid_token(body["refresh_token"]),
      expires_at: expires_at,
      scopes: scopes(body["scope"])
    }
  end

  defp get!(url, token, params) do
    response =
      request(:get,
        url: url,
        auth: {:bearer, token},
        params: params,
        headers: [
          {"accept", "application/json"},
          {"user-agent", "Flurry source connection"}
        ]
      )

    unless response.status in 200..299 and (is_map(response.body) or is_list(response.body)),
      do: Error.fail("The source provider connection is unavailable; reconnect it", 502)

    response.body
  end

  defp request(method, options) do
    options =
      [redirect: false, retry: false, receive_timeout: 10_000, connect_options: [timeout: 5_000]]
      |> Keyword.merge(Application.get_env(:flurry, :source_provider_req_options, []))
      |> Keyword.merge(options)

    case Req.request(Keyword.put(options, :method, method)) do
      {:ok, response} -> response
      _ -> Error.fail("The source provider could not be reached", 502)
    end
  end

  defp filter(repositories, query) when is_list(repositories) do
    value = String.downcase(query)

    repositories
    |> Enum.filter(fn repository ->
      value == "" or
        String.contains?(
          String.downcase(repository["full_name"] || repository["path_with_namespace"] || ""),
          value
        )
    end)
    |> Enum.take(100)
  end

  defp filter(_, _), do: Error.fail("The source provider returned invalid repositories", 502)

  defp valid_token(value) when is_binary(value) and byte_size(value) in 1..4096, do: value
  defp valid_token(_), do: nil

  defp scopes(value) when is_binary(value),
    do: String.split(value, [",", " "], trim: true) |> Enum.uniq()

  defp scopes(_), do: []
end
