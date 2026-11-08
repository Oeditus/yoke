defmodule Yoke.Provider do
  @moduledoc """
  Resolves generation providers independently of Hands execution mode.

  Named profiles select a model and endpoint together, ignoring unrelated
  provider environment variables. Resolved options can be passed to children
  and auxiliary calls without resolving credentials again.
  """
  alias Yoke.Client.DeepSeekAPI
  alias Yoke.Config

  @profiles %{
    "local" => [
      endpoint: "http://127.0.0.1:11434/v1/chat/completions",
      model: "devstral-small-2:24b-instruct-2512-q4_K_M",
      temperature: 0.15,
      max_context_tokens: 16_384
    ],
    "local-qwen" => [
      endpoint: "http://127.0.0.1:11434/v1/chat/completions",
      model: "qwen3-coder:30b-a3b-q4_K_M",
      temperature: 0.7,
      max_context_tokens: 16_384
    ],
    "deepseek" => [
      endpoint: "https://api.deepseek.com/chat/completions",
      model: "deepseek-flash",
      temperature: 0.7,
      max_context_tokens: 64_000
    ]
  }

  @doc "Available explicit profiles."
  def names, do: ~w(local local-qwen deepseek)

  @doc "Resolve a profile or preserve legacy endpoint/model precedence."
  def resolve(opts \\ []) do
    if opts[:provider_resolved] do
      opts
    else
      cfg = Config.load_config(opts[:cwd] || ".")

      name =
        if opts[:provider] == false,
          do: nil,
          else: opts[:provider] || System.get_env("YOKE_PROVIDER") || cfg["provider"]

      name = if name in [nil, :null, ""], do: nil, else: name

      selected =
        if name do
          profile = profile!(name)
          local? = String.starts_with?(name, "local")

          profile
          |> Keyword.put(:api_key, if(local?, do: "not-needed", else: deepseek_key(cfg)))
          |> Keyword.put(:provider, name)
          |> Keyword.put(
            :price_per_million_prompt_tokens,
            if(local?, do: 0.0, else: cfg["price_per_million_prompt_tokens"])
          )
          |> Keyword.put(
            :price_per_million_completion_tokens,
            if(local?, do: 0.0, else: cfg["price_per_million_completion_tokens"])
          )
        else
          legacy(opts, cfg)
        end

      resolved =
        selected
        |> Keyword.merge(Enum.reject(opts, fn {_key, value} -> is_nil(value) end))
        |> Keyword.put(:provider, name)
        |> Keyword.update!(:endpoint, &DeepSeekAPI.normalize_endpoint/1)
        |> Keyword.put(:provider_resolved, true)

      if name && String.starts_with?(name, "local") do
        unless loopback?(resolved[:endpoint]) do
          raise ArgumentError,
                "Local profiles require a loopback endpoint; no remote fallback is allowed."
        end

        Keyword.put(resolved, :api_key, "not-needed")
      else
        resolved
      end
    end
  end

  @doc "Validate a profile name without loading credentials."
  def profile!(name) do
    case Map.fetch(@profiles, name) do
      {:ok, profile} ->
        profile

      :error ->
        raise ArgumentError, "Unknown provider #{inspect(name)}. Use #{Enum.join(names(), ", ")}."
    end
  end

  @doc "Describe the transport, not the execution mode or model's vendor."
  def location(endpoint),
    do: if(DeepSeekAPI.local_endpoint?(endpoint), do: "LOCAL", else: "REMOTE")

  @doc "A credential-free provider summary safe for terminal output."
  def describe(opts) do
    "#{location(opts[:endpoint])} #{opts[:provider] || "custom"} | #{opts[:model]} | #{opts[:endpoint]}"
  end

  @doc "Credential-free settings suitable for checkpoints and manifests."
  def public_options(opts) when is_map(opts) do
    Map.take(opts, ~w(provider model endpoint temperature max_context_tokens))
  end

  def public_options(opts) do
    opts
    |> Keyword.take([:provider, :model, :endpoint, :temperature, :max_context_tokens])
    |> Enum.reject(fn {_key, value} -> value in [nil, :null] end)
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
  end

  @doc "Rehydrate saved transport settings and resolve credentials afresh."
  def restore(saved, cwd) when is_map(saved) do
    [:provider, :model, :endpoint, :temperature, :max_context_tokens]
    |> Enum.flat_map(fn key ->
      case saved[to_string(key)] do
        value when value in [nil, :null] -> []
        value -> [{key, value}]
      end
    end)
    |> Keyword.put(:cwd, cwd)
    |> resolve()
  end

  defp loopback?(endpoint), do: URI.parse(endpoint).host in ["localhost", "127.0.0.1", "::1"]

  defp deepseek_key(cfg) do
    legacy_key =
      if URI.parse(DeepSeekAPI.normalize_endpoint(cfg["endpoint"])).host == "api.deepseek.com",
        do: cfg["api_key"]

    Enum.find(
      [System.get_env("DEEPSEEK_API_KEY"), cfg["deepseek_api_key"], legacy_key],
      &(is_binary(&1) and &1 != "")
    )
  end

  defp legacy(opts, cfg) do
    endpoint =
      opts[:endpoint] || System.get_env("DEEPSEEK_ENDPOINT") ||
        System.get_env("OPENROUTER_BASE_URL") || System.get_env("OPENCODE_BASE_URL") ||
        System.get_env("OLLAMA_HOST") || cfg["endpoint"]

    key =
      if DeepSeekAPI.local_endpoint?(DeepSeekAPI.normalize_endpoint(endpoint)) do
        "not-needed"
      else
        System.get_env("DEEPSEEK_API_KEY") || System.get_env("OPENROUTER_API_KEY") ||
          System.get_env("OPENCODE_API_KEY") || System.get_env("OPENCODE_ZEN_API_KEY") ||
          System.get_env("LLM_API_KEY") || cfg["api_key"]
      end

    [
      model: opts[:model] || System.get_env("DEEPSEEK_MODEL") || cfg["model"],
      endpoint: endpoint,
      api_key: key,
      temperature: cfg["temperature"],
      max_context_tokens: cfg["max_context_tokens"],
      price_per_million_prompt_tokens: cfg["price_per_million_prompt_tokens"],
      price_per_million_completion_tokens: cfg["price_per_million_completion_tokens"]
    ]
  end
end
