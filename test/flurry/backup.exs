defmodule Flurry.BackupTest do
  use ExUnit.Case, async: true
  alias Flurry.Backup

  test "Spaces can be selected without credentials or network activity" do
    status = Backup.inspect_config([])
    assert status.provider == "spaces"
    assert status.valid
    refute status.configured
    refute status.automatic
    assert status.endpoint == nil
  end

  test "configured means supplied settings, not an enabled backup job" do
    status =
      Backup.inspect_config(
        [
          provider: "spaces",
          region: "nyc3",
          bucket: "flurry-backups",
          prefix: "instance/production"
        ],
        %{access_key: true, secret_key: true}
      )

    assert status.configured
    assert status.endpoint == "https://nyc3.digitaloceanspaces.com"
    assert status.object_prefix == "instance/production/objects/v1"
    refute status.automatic
    assert status.managed_by == "devops"
  end

  test "configuration rejects URL injection and noncanonical prefixes" do
    for options <- [
          [region: "nyc3.attacker.test"],
          [bucket: "bucket/path"],
          [prefix: "../escape"],
          [prefix: "/absolute"],
          [provider: "unknown"]
        ] do
      status = Backup.inspect_config(options, %{access_key: true, secret_key: true})
      refute status.valid
      refute status.configured
      assert status.endpoint == nil
    end
  end

  test "the public diagnostic schema never serializes supplied secrets" do
    status =
      Backup.inspect_config(
        [region: "nyc3", bucket: "flurry-backups", secret_access_key: "do-not-expose"],
        %{access_key: "do-not-expose", secret_key: "do-not-expose"}
      )

    refute status.configured
    refute Jason.encode!(status) =~ "do-not-expose"
    assert Backup.inspect_config(provider: "none").provider == "none"
  end
end
