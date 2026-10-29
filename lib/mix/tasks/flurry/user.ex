defmodule Mix.Tasks.Flurry.User do
  use Mix.Task
  import Ecto.Query
  @shortdoc "Recover an account locally: reset or promote <username>"

  def run([action, username | options]) when action in ["reset", "promote"] do
    Mix.Task.run("app.config")
    Application.put_env(:flurry, :server, false)
    Mix.Task.run("app.start")

    user =
      Flurry.Repo.get_by(Flurry.Schema.User, username: username) || Mix.raise("User not found")

    {:ok, _} =
      Flurry.Repo.transaction(fn ->
        fields =
          if action == "promote" do
            [admin: true, disabled: false]
          else
            password =
              System.get_env("FLURRY_PASSWORD") ||
                Mix.raise("Set FLURRY_PASSWORD in the environment; do not pass it as an argument")

            fields = [
              password: Flurry.Auth.encode(Flurry.Auth.password!(password)),
              disabled: false
            ]

            if "--disabletwofactor" in options,
              do:
                fields ++
                  [
                    totp_secret: nil,
                    totp_pending: nil,
                    totp_expires: nil,
                    totp_last: nil,
                    recovery_codes: []
                  ],
              else: fields
          end

        user |> Ecto.Changeset.change(fields) |> Flurry.Repo.update!()

        if action == "reset" and "--disablepasskeys" in options do
          Flurry.Repo.delete_all(from(p in Flurry.Schema.Passkey, where: p.user_id == ^user.id))
        end

        Flurry.Security.Sessions.revoke_all(user)
        Flurry.Audit.record(user, "account.operator." <> action)
      end)

    Mix.shell().info("Account updated; existing sessions and API tokens revoked")
  end

  def run(_),
    do:
      Mix.raise(
        "Usage: mix flurry.user reset <username> [--disabletwofactor] [--disablepasskeys] OR mix flurry.user promote <username>"
      )
end
