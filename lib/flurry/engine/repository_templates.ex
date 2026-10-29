defmodule Flurry.Engine.RepositoryTemplates do
  @moduledoc false

  @gitignores %{
    "node" => "node_modules/\n.env\n.env.*\ndist/\ncoverage/\n*.log\n",
    "python" => "__pycache__/\n*.py[cod]\n.venv/\nvenv/\n.env\ndist/\nbuild/\n*.egg-info/\n",
    "rust" => "/target/\n**/*.rs.bk\n.env\n",
    "elixir" => "/_build/\n/cover/\n/deps/\n/doc/\n/.fetch\nerl_crash.dump\n*.ez\n.env\n"
  }

  @licenses %{
    "mit" => """
    MIT License

    Copyright (c) {{year}} {{holder}}

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.
    """,
    "isc" => """
    ISC License

    Copyright (c) {{year}} {{holder}}

    Permission to use, copy, modify, and/or distribute this software for any
    purpose with or without fee is hereby granted, provided that the above
    copyright notice and this permission notice appear in all copies.

    THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH
    REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY
    AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT,
    INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM
    LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR
    OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
    PERFORMANCE OF THIS SOFTWARE.
    """,
    "bsd-3-clause" => """
    BSD 3-Clause License

    Copyright (c) {{year}}, {{holder}}
    All rights reserved.

    Redistribution and use in source and binary forms, with or without
    modification, are permitted provided that the following conditions are met:

    1. Redistributions of source code must retain the above copyright notice,
       this list of conditions and the following disclaimer.
    2. Redistributions in binary form must reproduce the above copyright notice,
       this list of conditions and the following disclaimer in the documentation
       and/or other materials provided with the distribution.
    3. Neither the name of the copyright holder nor the names of its contributors
       may be used to endorse or promote products derived from this software
       without specific prior written permission.

    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
    AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
    IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
    DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
    FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
    DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
    SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
    CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
    OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
    OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
    """
  }

  def files(attrs, repository, user) do
    readme = truthy?(attrs["initialize_readme"])
    gitignore = selection(attrs["gitignore_template"], @gitignores, "ignore template")
    license = selection(attrs["license_template"], @licenses, "license template")

    []
    |> maybe_add(readme, "README.md", readme(repository))
    |> maybe_add(gitignore, ".gitignore", gitignore && Map.fetch!(@gitignores, gitignore))
    |> maybe_add(license, "LICENSE", license && render_license(license, user))
  end

  defp selection(value, _choices, _label) when value in [nil, ""], do: nil

  defp selection(value, choices, label) when is_binary(value) do
    if Map.has_key?(choices, value), do: value, else: Flurry.Error.fail("Choose a valid #{label}")
  end

  defp selection(_, _, label), do: Flurry.Error.fail("Choose a valid #{label}")

  defp truthy?(value), do: value in [true, "true", "on", "1"]

  defp maybe_add(files, false, _path, _content), do: files
  defp maybe_add(files, nil, _path, _content), do: files

  defp maybe_add(files, _choice, path, content),
    do: files ++ [%{"path" => path, "content" => content}]

  defp readme(repository) do
    description = if repository.description == "", do: "", else: "\n\n#{repository.description}"
    "# #{repository.name}#{description}\n"
  end

  defp render_license(key, user) do
    @licenses
    |> Map.fetch!(key)
    |> String.replace("{{year}}", Integer.to_string(Date.utc_today().year))
    |> String.replace("{{holder}}", user.name)
  end
end
