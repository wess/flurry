defmodule Flurry.MixProject do
  use Mix.Project

  def project do
    [
      app: :flurry,
      version: "0.1.3",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: [setup: ["deps.get", "flurry.setup"], test: ["run test/run.exs"]]
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto, :public_key, :ssh], mod: {Flurry.Application, []}]
  end

  defp deps do
    [
      {:bandit, "~> 1.14.1"},
      {:plug, "~> 1.16"},
      {:ecto_sql, "~> 3.12"},
      {:postgrex, "~> 0.19"},
      {:jason, "~> 1.4"},
      {:nimble_totp, "~> 1.0"},
      {:wax_, "~> 0.7.0"},
      {:req, "~> 0.7"},
      {:req_s3, "~> 0.2.5"}
    ]
  end
end
