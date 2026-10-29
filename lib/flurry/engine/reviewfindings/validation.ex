defmodule Flurry.Engine.ReviewFindings.Validation do
  alias Flurry.{Auth, Error}
  alias Flurry.Engine.Changesets
  alias Flurry.Store.Tree

  @profiles ["correctness", "security", "regression", "edge_case", "contract"]

  def anchor!(repository, review, attrs) do
    values = Enum.map(["path", "side", "line"], &Map.get(attrs, &1))

    if Enum.all?(values, &is_nil/1) do
      %{}
    else
      unless Enum.all?(values, &(not is_nil(&1))),
        do: Error.fail("Inline findings require path, side, and line")

      [path, side, line] = values
      path = Tree.path!(path)
      unless side in ["before", "after"], do: Error.fail("Choose the before or after side")
      unless is_integer(line) and line > 0, do: Error.fail("Finding line must be positive")
      change = Changesets.get(repository, review.changeset_id)

      file =
        Changesets.diff(repository, change, if(review.series, do: review.base_id, else: :parent))
        |> Enum.find(&(&1.path == path)) || Error.fail("Finding path is not in this change", 409)

      content = Map.fetch!(file, String.to_existing_atom(side))

      unless (content && content.encoding == "utf8") and not content.truncated and
               line <= length(String.split(content.content, "\n")),
             do: Error.fail("Finding line is outside this text diff", 409)

      %{path: path, side: side, line: line}
    end
  end

  def profiles!(profiles) when is_list(profiles) and length(profiles) in 1..8 do
    profiles = profiles |> Enum.map(&enum!(&1, @profiles, "review profile")) |> Enum.uniq()
    if profiles == [], do: Error.fail("Choose at least one review profile"), else: profiles
  end

  def profiles!(_), do: Error.fail("Review profiles must contain between 1 and 8 values")

  def context!(nil), do: nil
  def context!(""), do: nil

  def context!(value) do
    value = Auth.text!(value, "Review status context", 100)

    unless Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9 ._\/-]*\z/, value),
      do: Error.fail("Review status context contains unsupported characters")

    value
  end

  def fingerprint!(value) do
    value = Auth.text!(value, "Finding fingerprint", 128)

    unless Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9._:\/-]*\z/, value),
      do: Error.fail("Finding fingerprints contain unsupported characters")

    value
  end

  def enum!(value, allowed, label) do
    unless value in allowed, do: Error.fail("Choose a valid #{label}")
    value
  end

  def optional_text!(nil, _label, _limit), do: nil
  def optional_text!("", _label, _limit), do: nil
  def optional_text!(value, label, limit), do: Auth.text!(value, label, limit)
end
