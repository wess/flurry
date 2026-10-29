defmodule Flurry.Integrations.Endpoint do
  import Bitwise
  alias Flurry.Error

  def validate!(url, resolver \\ &resolve/1) do
    uri = if is_binary(url), do: URI.parse(url), else: %URI{}
    host = if is_binary(uri.host), do: String.downcase(uri.host), else: nil

    unless uri.scheme == "https" and valid_host?(host) and is_nil(uri.userinfo) and
             is_nil(uri.fragment) and valid_port?(uri.port),
           do: Error.fail("Webhook URLs must be public HTTPS addresses")

    addresses =
      case resolver.(host) do
        {:ok, values} when is_list(values) -> values
        values when is_list(values) -> values
        _ -> []
      end

    if addresses == [] or Enum.any?(addresses, &(not public?(&1))),
      do: Error.fail("Webhook host must resolve only to public addresses")

    URI.to_string(%{uri | host: host})
  end

  def public?({a, b, c, d}) do
    Enum.all?([a, b, c, d], &(&1 in 0..255)) and
      not (a == 0 or a == 10 or a == 127 or a >= 224 or
             (a == 100 and b in 64..127) or
             (a == 169 and b == 254) or
             (a == 172 and b in 16..31) or
             (a == 192 and b in [0, 168]) or
             (a == 198 and b in 18..19) or
             (a == 192 and b == 0 and c == 2) or
             (a == 198 and b == 51 and c == 100) or
             (a == 203 and b == 0 and c == 113))
  end

  def public?({0, 0, 0, 0, 0, 0xFFFF, a, b}) do
    public?({a >>> 8, a &&& 255, b >>> 8, b &&& 255})
  end

  def public?({a, b, c, d, e, f, g, h}) do
    values = [a, b, c, d, e, f, g, h]

    Enum.all?(values, &(&1 in 0..65_535)) and
      (a &&& 0xE000) == 0x2000 and
      not (a == 0x2001 and b == 0x0DB8)
  end

  def public?(_), do: false

  defp resolve(host) do
    addresses =
      [:inet, :inet6]
      |> Enum.flat_map(fn family ->
        case :inet.getaddrs(String.to_charlist(host), family) do
          {:ok, values} -> values
          _ -> []
        end
      end)
      |> Enum.uniq()

    {:ok, addresses}
  end

  defp valid_host?(host) do
    is_binary(host) and byte_size(host) <= 253 and
      (match?({:ok, _}, :inet.parse_address(String.to_charlist(host))) or
         (not String.contains?(host, "..") and
            Enum.all?(String.split(host, "."), fn label ->
              byte_size(label) in 1..63 and
                Regex.match?(~r/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/, label)
            end)))
  end

  defp valid_port?(nil), do: true
  defp valid_port?(port), do: is_integer(port) and port in 1..65_535
end
