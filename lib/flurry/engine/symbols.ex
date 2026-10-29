defmodule Flurry.Engine.Symbols do
  @moduledoc false

  @languages %{
    ".ex" => {"Elixir", ~r/^\s*(defmodule|defprotocol|defimpl|defmacro|defp|def)\s+([\w.!?]+)/},
    ".exs" => {"Elixir", ~r/^\s*(defmodule|defprotocol|defimpl|defmacro|defp|def)\s+([\w.!?]+)/},
    ".js" =>
      {"JavaScript",
       ~r/^\s*(?:export\s+)?(?:async\s+)?(function|class|const|let|var)\s+([A-Za-z_$][\w$]*)/},
    ".jsx" =>
      {"JavaScript",
       ~r/^\s*(?:export\s+)?(?:async\s+)?(function|class|const|let|var)\s+([A-Za-z_$][\w$]*)/},
    ".ts" =>
      {"TypeScript",
       ~r/^\s*(?:export\s+)?(?:default\s+)?(?:async\s+)?(function|class|interface|type|enum|const)\s+([A-Za-z_$][\w$]*)/},
    ".tsx" =>
      {"TypeScript",
       ~r/^\s*(?:export\s+)?(?:default\s+)?(?:async\s+)?(function|class|interface|type|enum|const)\s+([A-Za-z_$][\w$]*)/},
    ".py" => {"Python", ~r/^\s*(async\s+def|def|class)\s+([A-Za-z_]\w*)/},
    ".rb" => {"Ruby", ~r/^\s*(def|class|module)\s+([A-Za-z_]\w*[!?=]?)/},
    ".rs" =>
      {"Rust",
       ~r/^\s*(?:pub(?:\([^)]*\))?\s+)?(async\s+fn|fn|struct|enum|trait|impl)\s+([A-Za-z_]\w*)/},
    ".go" => {"Go", ~r/^\s*(func|type)\s+(?:\([^)]*\)\s*)?([A-Za-z_]\w*)/},
    ".zig" => {"Zig", ~r/^\s*(?:pub\s+)?(fn|const|var)\s+([A-Za-z_]\w*)/},
    ".java" =>
      {"Java",
       ~r/^\s*(?:public|protected|private|static|final|abstract|synchronized|native|default|\s)+\s*(class|interface|enum|[\w<>\[\], ?]+)\s+([A-Za-z_]\w*)\s*[({=]/},
    ".kt" =>
      {"Kotlin",
       ~r/^\s*(?:public|private|protected|internal|open|override|suspend|data|\s)*\s*(fun|class|interface|object)\s+([A-Za-z_]\w*)/},
    ".swift" =>
      {"Swift",
       ~r/^\s*(?:public|private|internal|open|final|static|class|mutating|\s)*\s*(func|class|struct|enum|protocol)\s+([A-Za-z_]\w*)/}
  }

  def annotate(diff) do
    Enum.map(diff, fn file -> Map.put(file, :symbols, summary(file)) end)
  end

  def summary(%{path: path, lines: lines, before: before, after: next}) when is_list(lines) do
    with {language, pattern} <- Map.get(@languages, Path.extname(path)),
         true <- text?(before) or text?(next) do
      old = declarations(content(before), pattern)
      new = declarations(content(next), pattern)
      {old_lines, new_lines} = changed_lines(lines)

      changed =
        (enclosing(old, old_lines) ++ enclosing(new, new_lines))
        |> Enum.uniq_by(& &1.name)
        |> Enum.map(fn symbol ->
          old? = Enum.any?(old, &(&1.name == symbol.name))
          new? = Enum.any?(new, &(&1.name == symbol.name))

          Map.put(
            symbol,
            :change,
            cond do
              old? and new? -> "modified"
              new? -> "added"
              true -> "deleted"
            end
          )
        end)
        |> Enum.take(12)

      if changed == [], do: nil, else: %{language: language, changed: changed}
    else
      _ -> nil
    end
  end

  def summary(_), do: nil

  defp declarations(content, pattern) do
    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, number} ->
      case Regex.run(pattern, line) do
        [_, kind, name | _] -> [%{name: name, kind: String.trim(kind), line: number}]
        _ -> []
      end
    end)
  end

  defp changed_lines(lines) do
    {_, _, old, new} =
      Enum.reduce(lines, {1, 1, MapSet.new(), MapSet.new()}, fn line,
                                                                {old_line, new_line, old, new} ->
        case line.kind do
          "eq" -> {old_line + 1, new_line + 1, old, new}
          "del" -> {old_line + 1, new_line, MapSet.put(old, old_line), new}
          "ins" -> {old_line, new_line + 1, old, MapSet.put(new, new_line)}
          :eq -> {old_line + 1, new_line + 1, old, new}
          :del -> {old_line + 1, new_line, MapSet.put(old, old_line), new}
          :ins -> {old_line, new_line + 1, old, MapSet.put(new, new_line)}
        end
      end)

    {old, new}
  end

  defp enclosing(symbols, lines) do
    lines
    |> Enum.map(fn line -> symbols |> Enum.take_while(&(&1.line <= line)) |> List.last() end)
    |> Enum.reject(&is_nil/1)
  end

  defp text?(nil), do: false
  defp text?(%{encoding: "utf8"}), do: true
  defp text?(_), do: false
  defp content(nil), do: ""
  defp content(%{encoding: "utf8", content: value}), do: value
  defp content(_), do: ""
end
