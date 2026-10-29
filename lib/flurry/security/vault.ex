defmodule Flurry.Security.Vault do
  alias Flurry.Error
  @totp_context "flurry.totp.v1"

  def available?, do: is_binary(Application.get_env(:flurry, :encryption_key))

  def encrypt(data, context \\ @totp_context) when is_binary(data) and is_binary(context) do
    key = key!()
    nonce = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, data, context, 16, true)

    <<nonce::binary, tag::binary, ciphertext::binary>>
  end

  def decrypt(
        <<nonce::binary-size(12), tag::binary-size(16), ciphertext::binary>>,
        context \\ @totp_context
      )
      when is_binary(context) do
    case :crypto.crypto_one_time_aead(
           :aes_256_gcm,
           key!(),
           nonce,
           ciphertext,
           context,
           tag,
           false
         ) do
      :error ->
        Error.fail("Encrypted value could not be opened; contact the administrator", 503)

      plaintext ->
        plaintext
    end
  end

  defp key! do
    case Application.get_env(:flurry, :encryption_key) do
      key when is_binary(key) and byte_size(key) == 32 -> key
      _ -> Error.fail("Configure FLURRY_SECRET_KEY before storing encrypted values", 503)
    end
  end
end
