defmodule Flurry.Security.PasskeyChallenges do
  import Ecto.Query
  alias Flurry.{Error, Repo}
  alias Flurry.Schema.PasskeyChallenge

  @timeout 300

  def timeout_ms, do: @timeout * 1_000

  def create(kind, user_id, rp) when kind in [:registration, :authentication] do
    options = [
      origin: rp.origin,
      rp_id: rp.id,
      user_verification: "required",
      timeout: @timeout
    ]

    challenge =
      case kind do
        :registration -> Wax.new_registration_challenge(options)
        :authentication -> Wax.new_authentication_challenge(options)
      end

    now = DateTime.utc_now()
    Repo.delete_all(from(c in PasskeyChallenge, where: c.expires_at <= ^now))

    record =
      Repo.insert!(%PasskeyChallenge{
        id: Ecto.UUID.generate(),
        user_id: user_id,
        kind: Atom.to_string(kind),
        bytes: challenge.bytes,
        origin: List.first(List.wrap(challenge.origin)),
        rp_id: challenge.rp_id,
        issued_at: challenge.issued_at,
        expires_at: DateTime.add(now, @timeout)
      })

    {record, challenge}
  end

  def consume(id, kind, user_id) when kind in [:registration, :authentication] do
    unless match?({:ok, _}, Ecto.UUID.cast(id)),
      do: Error.fail("Passkey request expired; try again", 401)

    query =
      from(c in PasskeyChallenge,
        where:
          c.id == ^id and c.kind == ^Atom.to_string(kind) and
            c.expires_at > ^DateTime.utc_now(),
        select: c
      )

    query =
      if user_id,
        do: from(c in query, where: c.user_id == ^user_id),
        else: from(c in query, where: is_nil(c.user_id))

    case Repo.delete_all(query) do
      {1, [record]} -> challenge(record, kind)
      _ -> Error.fail("Passkey request expired; try again", 401)
    end
  end

  defp challenge(record, kind) do
    %Wax.Challenge{
      type: if(kind == :registration, do: :attestation, else: :authentication),
      bytes: record.bytes,
      origin: record.origin,
      rp_id: record.rp_id,
      issued_at: record.issued_at,
      user_verification: "required",
      timeout: @timeout,
      origin_verify_fun: {Wax, :origins_match?, []}
    }
  end
end
