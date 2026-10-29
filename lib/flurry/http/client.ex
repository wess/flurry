defmodule Flurry.Http.Client do
  import Plug.Conn

  def address(conn) do
    if conn.remote_ip in Application.get_env(:flurry, :trusted_proxies, []) do
      forwarded_address(conn) || conn.remote_ip
    else
      conn.remote_ip
    end
  end

  defp forwarded_address(conn) do
    with [header] <- get_req_header(conn, "x-forwarded-for"),
         [first | _] <- String.split(header, ","),
         {:ok, address} <- first |> String.trim() |> String.to_charlist() |> :inet.parse_address() do
      address
    else
      _ -> nil
    end
  end
end
