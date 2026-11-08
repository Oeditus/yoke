defmodule Yoke.PRReview.Tools do
  @moduledoc "Read-only review tools that inspect Git objects, never the mutable checkout."

  @names ~w(read_file read_files list_dir grep_search glob_search git_diff git_root)
  @max_output 100_000

  @doc "Whether a tool belongs to the revision-pinned read-only catalog."
  def allowed?(name), do: name in @names

  @doc "Returns the restricted tool catalog used only by review turns."
  def definitions do
    Yoke.Plugin.DefaultTools.tools()
    |> Enum.filter(&(&1.name in @names))
    |> Enum.map(&with_revision_option/1)
    |> Enum.map(
      &Map.put(
        &1,
        :description,
        &1.description <>
          " REVIEW MODE: reads only the pinned reviewed Git revision, not the working tree."
      )
    )
  end

  defp with_revision_option(%{name: name} = tool) when name in ["read_file", "read_files"] do
    put_in(tool, [:parameters, :properties, :revision], %{
      type: "string",
      enum: ["head", "base"],
      description:
        "Read the reviewed head (default) or the comparison merge-base, including deleted files."
    })
  end

  defp with_revision_option(tool), do: tool

  @doc "Executes a read-only call against the immutable review context."
  def execute(name, args, context) do
    result = dispatch(name, args, context)

    case result do
      {:ok, output} when byte_size(output) > @max_output ->
        {:error, "Review tool output exceeds 100 KB. Narrow the path, query, or line range."}

      other ->
        other
    end
  rescue
    e -> {:error, "Review tool failed: #{Exception.message(e)}"}
  end

  defp dispatch("git_diff", _args, context), do: {:ok, context.raw_diff}
  defp dispatch("git_root", _args, context), do: {:ok, context.cwd}

  defp dispatch("read_file", %{"path" => path} = args, context) do
    with {:ok, relative} <- relative_path(path, context),
         {:ok, revision} <- revision(args, context),
         {:ok, output} <- git(["show", "#{revision}:#{relative}"], context) do
      slice(output, args)
    end
  end

  defp dispatch("read_files", %{"paths" => paths} = args, context) when is_list(paths) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, files} ->
      case dispatch("read_file", Map.put(args, "path", path), context) do
        {:ok, content} -> {:cont, {:ok, ["=== File: #{path} ===\n#{content}" | files]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, files} -> {:ok, files |> Enum.reverse() |> Enum.join("\n")}
      error -> error
    end
  end

  defp dispatch("list_dir", args, context) do
    with {:ok, path} <- relative_path(Map.get(args, "path", "."), context) do
      tree = if path == ".", do: context.head_sha, else: "#{context.head_sha}:#{path}"
      git(["ls-tree", "--name-only", tree], context)
    end
  end

  defp dispatch("glob_search", %{"pattern" => pattern}, context) when is_binary(pattern) do
    with {:ok, paths} <- git(["ls-tree", "-r", "--name-only", "-z", context.head_sha], context) do
      regex =
        pattern
        |> Regex.escape()
        |> String.replace("\\*\\*/", "(?:.*/)?")
        |> String.replace("\\*\\*", ".*")
        |> String.replace("\\*", "[^/]*")
        |> String.replace("\\?", "[^/]")

      matcher = Regex.compile!("\\A" <> regex <> "\\z")

      {:ok,
       paths
       |> String.split(<<0>>, trim: true)
       |> Enum.filter(&Regex.match?(matcher, &1))
       |> Enum.join("\n")}
    end
  end

  defp dispatch("grep_search", args, context) do
    query = Map.get(args, "query") || Map.get(args, "pattern")

    with true <- is_binary(query) and query != "",
         {:ok, path} <- relative_path(Map.get(args, "path", "."), context) do
      pathspec =
        case Map.get(args, "path_pattern") do
          pattern when is_binary(pattern) and pattern != "" ->
            prefix = if path == ".", do: "", else: path <> "/"
            glob = if String.contains?(pattern, "/"), do: pattern, else: "**/" <> pattern
            [":(glob)#{prefix}#{glob}"]

          _ ->
            if path == ".", do: [], else: [":(literal)#{path}"]
        end

      git(
        ["grep", "-n", "-I", "-E", "-e", query, context.head_sha, "--"] ++ pathspec,
        context,
        true
      )
    else
      false -> {:error, "grep_search requires a nonempty query."}
      error -> error
    end
  end

  defp dispatch(name, _args, _context),
    do: {:error, "Tool #{inspect(name)} is unavailable during read-only code review."}

  defp relative_path(path, context) when is_binary(path) do
    expanded = Path.expand(path, context.cwd)
    relative = Path.relative_to(expanded, context.cwd)

    if Path.type(relative) == :relative and relative != ".." and
         not String.starts_with?(relative, "../") do
      {:ok, relative}
    else
      {:error, "Review paths must stay inside the reviewed repository."}
    end
  end

  defp relative_path(_path, _context), do: {:error, "Review path must be a string."}

  defp revision(args, context) do
    case Map.get(args, "revision", "head") do
      "head" -> {:ok, context.head_sha}
      "base" -> {:ok, context.merge_base}
      _ -> {:error, "Review file revision must be head or base."}
    end
  end

  defp slice(output, args) do
    start_line = Map.get(args, "start_line", 1)
    end_line = Map.get(args, "end_line")

    if is_integer(start_line) and start_line > 0 and
         (is_nil(end_line) or (is_integer(end_line) and end_line >= start_line)) do
      if Map.has_key?(args, "start_line") or end_line do
        lines =
          if output == "",
            do: [],
            else: output |> String.replace_suffix("\n", "") |> String.split("\n")

        last = end_line || length(lines)

        if start_line > length(lines) do
          {:error,
           "Requested range is past end of file (#{length(lines)} lines). " <>
             "Use an earlier range or finish the review with the evidence already supplied."}
        else
          {:ok,
           lines
           |> Enum.slice(start_line - 1, last - start_line + 1)
           |> Enum.with_index(start_line)
           |> Enum.map_join("\n", fn {line, n} -> "#{n}: #{line}" end)}
        end
      else
        {:ok, output}
      end
    else
      {:error, "Invalid review file line range."}
    end
  end

  defp git(args, context, no_matches? \\ false) do
    case System.cmd("git", ["--no-pager" | args], cd: context.cwd, stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, Yoke.Json.sanitize_utf8(output)}

      {_output, 1} when no_matches? ->
        {:ok, "No matches in the reviewed revision."}

      {_output, _} ->
        {:error, "Cannot inspect that path or query at reviewed commit #{context.head_sha}."}
    end
  end
end
