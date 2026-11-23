defmodule Flurry.LoggingTest do
  use ExUnit.Case, async: true

  test "production keeps SQL statements and their parameters out of the log" do
    level = fn env -> Config.Reader.read!("config/config.exs", env: env)[:logger][:level] end

    assert level.(:prod) == :info
    assert Logger.compare_levels(level.(:prod), :debug) == :gt
    # development keeps query logging for debugging
    assert level.(:dev) == nil
  end
end
