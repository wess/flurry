defmodule Flurry.Repo do
  use Ecto.Repo, otp_app: :flurry, adapter: Ecto.Adapters.Postgres
end
