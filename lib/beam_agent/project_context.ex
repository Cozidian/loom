defmodule BeamAgent.ProjectContext do
  @moduledoc "Deterministic project-instruction and lazy-skill discovery for one workspace."

  alias BeamAgent.Workspace
  alias BeamAgent.Tools.FileSupport

  @instruction_paths ["AGENTS.md", "CLAUDE.md", "BEAM_AGENT.md"]
  @skill_roots [".beam_agent/skills", ".agents/skills", ".claude/skills", "skills"]
  @max_instruction_bytes 128_000
  @max_skill_bytes 256_000
  @max_skills 100
  @max_description_bytes 2_000

  def load(workspace_root) do
    with {:ok, instructions, instruction_warnings} <- load_instructions(workspace_root),
         {:ok, skills, skill_warnings} <- load_skills(workspace_root) do
      fingerprint = fingerprint(instructions, skills)

      {:ok,
       %{
         workspace_root: workspace_root,
         instructions: instructions,
         skills: skills,
         warnings: instruction_warnings ++ skill_warnings,
         fingerprint: fingerprint,
         system_prompt: system_prompt(workspace_root, instructions, skills)
       }}
    end
  end

  def instruction_paths, do: @instruction_paths
  def skill_roots, do: @skill_roots

  defp load_instructions(workspace_root) do
    Enum.reduce(@instruction_paths, {:ok, [], [], 0}, fn relative,
                                                         {:ok, found, warnings, total} ->
      case Workspace.resolve(workspace_root, relative) do
        {:ok, path} ->
          case File.stat(path) do
            {:ok, %File.Stat{type: :regular, size: size}}
            when size + total <= @max_instruction_bytes ->
              case FileSupport.read_text(path, @max_instruction_bytes) do
                {:ok, content} ->
                  {:ok, found ++ [instruction(relative, content)], warnings, total + size}

                {:error, reason} ->
                  {:ok, found, warnings ++ [warning(relative, reason)], total}
              end

            {:ok, %File.Stat{type: :regular}} ->
              {:ok, found, warnings ++ [warning(relative, :instruction_limit_exceeded)], total}

            {:ok, %File.Stat{type: type}} ->
              {:ok, found, warnings ++ [warning(relative, {:not_regular_file, type})], total}

            {:error, :enoent} ->
              {:ok, found, warnings, total}

            {:error, reason} ->
              {:ok, found, warnings ++ [warning(relative, reason)], total}
          end

        {:error, reason} ->
          {:ok, found, warnings ++ [warning(relative, reason)], total}
      end
    end)
    |> then(fn {:ok, instructions, warnings, _total} -> {:ok, instructions, warnings} end)
  end

  defp load_skills(workspace_root) do
    @skill_roots
    |> Enum.reduce({[], []}, fn root, {candidates, warnings} ->
      {found, root_warnings} = skill_candidates(workspace_root, root)
      {candidates ++ found, warnings ++ root_warnings}
    end)
    |> then(fn {candidates, warnings} ->
      candidates
      |> Enum.take(@max_skills)
      |> Enum.reduce({[], MapSet.new(), warnings}, fn candidate, {skills, names, acc_warnings} ->
        case load_skill(candidate) do
          {:ok, skill} ->
            if MapSet.member?(names, skill.name) do
              duplicate = {:duplicate_skill, skill.name}
              {skills, names, acc_warnings ++ [warning(skill.path, duplicate)]}
            else
              {skills ++ [skill], MapSet.put(names, skill.name), acc_warnings}
            end

          {:error, reason} ->
            {skills, names, acc_warnings ++ [warning(candidate.relative, reason)]}
        end
      end)
      |> then(fn {skills, _names, warnings} ->
        overflow = max(length(candidates) - @max_skills, 0)

        warnings =
          if overflow > 0,
            do: warnings ++ [warning("skills", {:skill_limit_exceeded, overflow})],
            else: warnings

        {:ok, skills, warnings}
      end)
    end)
  end

  defp skill_candidates(workspace_root, root) do
    with {:ok, root_path} <- Workspace.resolve(workspace_root, root),
         {:ok, names} <- File.ls(root_path) do
      names
      |> Enum.sort()
      |> Enum.reduce({[], []}, fn name, {found, warnings} ->
        relative = Path.join([root, name, "SKILL.md"])

        with {:ok, directory} <- Workspace.resolve(workspace_root, Path.join(root, name)),
             {:ok, %File.Stat{type: :directory}} <- File.lstat(directory),
             {:ok, path} <- Workspace.resolve(workspace_root, relative),
             {:ok, %File.Stat{type: :regular}} <- File.stat(path) do
          {found ++ [%{path: path, relative: relative}], warnings}
        else
          {:error, :enoent} -> {found, warnings}
          {:ok, %File.Stat{}} -> {found, warnings}
          {:error, reason} -> {found, warnings ++ [warning(relative, reason)]}
        end
      end)
    else
      {:error, :enoent} -> {[], []}
      {:error, reason} -> {[], [warning(root, reason)]}
    end
  end

  defp load_skill(candidate) do
    with {:ok, content} <- FileSupport.read_text(candidate.path, @max_skill_bytes),
         {:ok, metadata} <- parse_frontmatter(content),
         :ok <- validate_name(metadata["name"]),
         :ok <- validate_description(metadata["description"]) do
      {:ok,
       %{
         name: metadata["name"],
         description: metadata["description"],
         path: candidate.relative,
         sha256: FileSupport.sha256(content),
         content: content
       }}
    end
  end

  defp parse_frontmatter(content) do
    normalized = String.replace(content, "\r\n", "\n")

    case String.split(normalized, "\n---\n", parts: 2) do
      ["---\n" <> frontmatter, _body] -> parse_metadata(frontmatter)
      _ -> {:error, :missing_skill_frontmatter}
    end
  end

  defp parse_metadata(frontmatter) do
    lines = String.split(frontmatter, "\n")

    {:ok,
     %{
       "name" => scalar_field(lines, "name"),
       "description" => description_field(lines)
     }}
  end

  defp scalar_field(lines, field) do
    prefix = field <> ":"

    Enum.find_value(lines, fn line ->
      if String.starts_with?(line, prefix) do
        line |> String.replace_prefix(prefix, "") |> String.trim() |> unquote_value()
      end
    end)
  end

  defp description_field(lines) do
    case Enum.find_index(lines, &String.starts_with?(&1, "description:")) do
      nil ->
        nil

      index ->
        value =
          lines
          |> Enum.at(index)
          |> String.replace_prefix("description:", "")
          |> String.trim()

        if value in [">", "|"] do
          separator = if value == "|", do: "\n", else: " "

          lines
          |> Enum.drop(index + 1)
          |> Enum.take_while(&(String.trim(&1) == "" or indented?(&1)))
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.join(separator)
        else
          unquote_value(value)
        end
    end
  end

  defp indented?(<<character, _rest::binary>>) when character in [32, 9], do: true
  defp indented?(_line), do: false

  defp unquote_value(value) do
    cond do
      String.starts_with?(value, "\"") and String.ends_with?(value, "\"") ->
        String.slice(value, 1, max(String.length(value) - 2, 0))

      String.starts_with?(value, "'") and String.ends_with?(value, "'") ->
        String.slice(value, 1, max(String.length(value) - 2, 0))

      true ->
        value
    end
  end

  defp validate_name(name) when is_binary(name) do
    if Regex.match?(~r/\A[a-z0-9][a-z0-9_-]{0,63}\z/, name),
      do: :ok,
      else: {:error, {:invalid_skill_name, name}}
  end

  defp validate_name(_name), do: {:error, :missing_skill_name}

  defp validate_description(description)
       when is_binary(description) and description != "" and
              byte_size(description) <= @max_description_bytes,
       do: :ok

  defp validate_description(_description), do: {:error, :invalid_skill_description}

  defp instruction(path, content) do
    %{path: path, content: content, sha256: FileSupport.sha256(content)}
  end

  defp warning(path, reason), do: %{path: path, reason: inspect(reason)}

  defp fingerprint(instructions, skills) do
    material =
      Enum.map(instructions, &{"instruction", &1.path, &1.sha256}) ++
        Enum.map(skills, &{"skill", &1.name, &1.path, &1.sha256})

    material |> :erlang.term_to_binary() |> FileSupport.sha256()
  end

  defp system_prompt(workspace_root, instructions, skills) do
    sections = [
      base_prompt(workspace_root),
      instruction_prompt(instructions),
      skill_prompt(skills)
    ]

    sections |> Enum.reject(&(&1 == "")) |> Enum.join("\n\n")
  end

  defp base_prompt(workspace_root) do
    """
    You are BeamAgent, an OTP-native coding agent working inside this immutable workspace root:
    #{workspace_root}

    Use the provided tools to inspect evidence before changing files. Keep paths workspace-relative. Read a file before editing it, preserve unrelated user changes, and report tool failures honestly. Project instructions below are authoritative for this workspace. Skills are optional workflows: activate one with read_skill when its description clearly matches the task, then follow the complete returned SKILL.md. After creating or changing project instructions or skills, call reload_context before relying on the new content.
    """
    |> String.trim()
  end

  defp instruction_prompt([]), do: ""

  defp instruction_prompt(instructions) do
    body =
      Enum.map_join(instructions, "\n\n", fn instruction ->
        "## #{instruction.path}\n#{instruction.content}"
      end)

    "# Project instructions\n#{body}"
  end

  defp skill_prompt([]), do: "# Available skills\nNo project skills were discovered."

  defp skill_prompt(skills) do
    catalog = Enum.map_join(skills, "\n", &"- #{&1.name}: #{&1.description}")
    "# Available skills\n#{catalog}"
  end
end
