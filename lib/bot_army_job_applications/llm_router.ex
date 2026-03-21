defmodule BotArmyJobApplications.LLMRouter do
  @moduledoc """
  Unified LLM routing for personal and portable distributions.

  Personal (bot_army_job_applications):
    - Default: NATS LLM Proxy (llm.prompt.submit)
    - Dev fallback: Local Ollama
    - Fallback: Anthropic API

  Portable (portable_job_applications):
    - Default: Local Ollama
    - Fallback: Anthropic API

  Configuration (config/config.exs):
    config :bot_army_job_applications, :llm_router,
      backend: :nats | :ollama | :anthropic,  # Primary backend
      nats_url: "nats://localhost:4222",       # For NATS backend
      ollama_url: "http://localhost:11434",    # For Ollama
      ollama_model: "mistral",
      anthropic_api_key: nil,
      nats_timeout_ms: 30_000,
      ollama_timeout_ms: 10_000,
      anthropic_timeout_ms: 30_000
  """

  require Logger

  @doc """
  Request completion from LLM with automatic fallback.

  Options:
    :task — Task category: :score, :classify, :digest (routine)
                           :letter, :resume (quality)
    :model — Override model
    :timeout_ms — Override timeout
  """
  def request(prompt, task, opts \\ []) when is_binary(prompt) and is_atom(task) do
    # Quality tasks prefer Anthropic (highest quality)
    if task in [:letter, :resume, :artifact] do
      quality_task_request(prompt, opts)
    else
      # Routine tasks: Use configured backend with fallbacks
      routine_task_request(prompt, opts)
    end
  end

  # ============================================================================
  # Routine Tasks (score, classify, digest)
  # ============================================================================

  defp routine_task_request(prompt, opts) do
    backend = config(:backend)

    case backend do
      :nats ->
        # Try NATS (personal prod), fall back to Ollama (personal dev)
        case nats_request(prompt, opts) do
          {:ok, response} -> {:ok, response}
          {:error, reason} ->
            Logger.warning("NATS LLM unavailable (#{inspect(reason)}), trying Ollama...")
            case ollama_request(prompt, opts) do
              {:ok, response} -> {:ok, response}
              {:error, _} ->
                Logger.warning("Ollama unavailable, trying Anthropic...")
                anthropic_request(prompt, opts)
            end
        end

      :ollama ->
        # Try Ollama (portable, personal dev), fall back to Anthropic
        case ollama_request(prompt, opts) do
          {:ok, response} -> {:ok, response}
          {:error, reason} ->
            Logger.warning("Ollama unavailable (#{inspect(reason)}), trying Anthropic...")
            anthropic_request(prompt, opts)
        end

      :anthropic ->
        # Anthropic only (fallback for all)
        anthropic_request(prompt, opts)

      _ ->
        {:error, "invalid_backend_#{backend}"}
    end
  end

  # ============================================================================
  # Quality Tasks (letters, resumes)
  # ============================================================================

  defp quality_task_request(prompt, opts) do
    # Quality tasks use Anthropic if available, otherwise fail gracefully
    case anthropic_request(prompt, opts) do
      {:ok, response} ->
        {:ok, response}

      {:error, reason} ->
        # Log quality task failure clearly
        Logger.error("Quality LLM task failed (Anthropic unavailable): #{inspect(reason)}")
        {:error, "anthropic_unavailable"}
    end
  end

  # ============================================================================
  # NATS LLM Proxy (Personal version)
  # ============================================================================

  defp nats_request(prompt, opts) do
    case get_nats_connection() do
      {:ok, conn} ->
        timeout = Keyword.get(opts, :timeout_ms, config(:nats_timeout_ms))

        payload = Jason.encode!(%{
          "event" => "llm.prompt.submit",
          "payload" => %{
            "prompt" => prompt,
            "task_key" => "classify"
          }
        })

        try do
          case Gnat.request(conn, "llm.prompt.submit", payload, timeout: timeout) do
            {:ok, response} ->
              case Jason.decode(response.body) do
                {:ok, decoded} ->
                  case decoded do
                    %{"ok" => true, "text" => text} -> {:ok, text}
                    %{"error" => error} -> {:error, error}
                    _ -> {:error, "unexpected_response"}
                  end

                {:error, _} ->
                  {:error, "decode_failed"}
              end

            {:error, reason} ->
              {:error, inspect(reason)}
          end
        rescue
          e ->
            Logger.error("NATS request error: #{inspect(e)}")
            {:error, "nats_error"}
        end

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp get_nats_connection do
    case Application.get_env(:bot_army_job_applications, :nats_connection) do
      conn when is_pid(conn) -> {:ok, conn}
      _ -> {:error, "nats_not_configured"}
    end
  end

  # ============================================================================
  # Ollama (Local)
  # ============================================================================

  defp ollama_request(prompt, opts) do
    ollama_url = config(:ollama_url)
    model = Keyword.get(opts, :model, config(:ollama_model))
    timeout = Keyword.get(opts, :timeout_ms, config(:ollama_timeout_ms))

    if is_nil(ollama_url) or ollama_url == "" do
      {:error, "ollama_url not configured"}
    else
      make_ollama_request(ollama_url, model, prompt, timeout)
    end
  end

  defp make_ollama_request(ollama_url, model, prompt, timeout) do
    url = "#{ollama_url}/api/generate"

    payload =
      Jason.encode!(%{
        "model" => model,
        "prompt" => prompt,
        "stream" => false,
        "temperature" => 0.7
      })

    headers = [
      {"Content-Type", "application/json"},
      {"Accept", "application/json"}
    ]

    case HTTPoison.post(url, payload, headers, timeout: timeout, recv_timeout: timeout) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"response" => response}} when is_binary(response) ->
            {:ok, String.trim(response)}

          {:ok, decoded} ->
            Logger.warning("Unexpected Ollama response format: #{inspect(decoded)}")
            {:error, "invalid_response_format"}

          {:error, reason} ->
            Logger.warning("Failed to decode Ollama response: #{inspect(reason)}")
            {:error, "decode_failed"}
        end

      {:ok, %HTTPoison.Response{status_code: code}} ->
        {:error, "http_#{code}"}

      {:error, reason} ->
        Logger.warning("Ollama request failed: #{inspect(reason)}")
        {:error, inspect(reason)}
    end
  end

  # ============================================================================
  # Anthropic API (Fallback)
  # ============================================================================

  defp anthropic_request(prompt, opts) do
    api_key = config(:anthropic_api_key)

    if is_nil(api_key) or api_key == "" do
      {:error, "anthropic_api_key not configured"}
    else
      make_anthropic_request(api_key, prompt, opts)
    end
  end

  defp make_anthropic_request(api_key, prompt, opts) do
    model = Keyword.get(opts, :model, "claude-3-5-sonnet-20241022")
    timeout = Keyword.get(opts, :timeout_ms, config(:anthropic_timeout_ms))

    url = "https://api.anthropic.com/v1/messages"

    payload =
      Jason.encode!(%{
        "model" => model,
        "max_tokens" => 1024,
        "messages" => [
          %{
            "role" => "user",
            "content" => prompt
          }
        ]
      })

    headers = [
      {"Content-Type", "application/json"},
      {"Accept", "application/json"},
      {"x-api-key", api_key},
      {"anthropic-version", "2023-06-01"}
    ]

    case HTTPoison.post(url, payload, headers, timeout: timeout, recv_timeout: timeout) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"content" => [%{"text" => text} | _]}} when is_binary(text) ->
            {:ok, String.trim(text)}

          {:ok, decoded} ->
            Logger.warning("Unexpected Anthropic response format: #{inspect(decoded)}")
            {:error, "invalid_response_format"}

          {:error, reason} ->
            Logger.warning("Failed to decode Anthropic response: #{inspect(reason)}")
            {:error, "decode_failed"}
        end

      {:ok, %HTTPoison.Response{status_code: code, body: body}} ->
        Logger.warning("Anthropic HTTP #{code}: #{body}")
        {:error, "http_#{code}"}

      {:error, reason} ->
        Logger.warning("Anthropic request failed: #{inspect(reason)}")
        {:error, inspect(reason)}
    end
  end

  # ============================================================================
  # Config helpers
  # ============================================================================

  defp config(key) do
    Application.get_env(:bot_army_job_applications, :llm_router, [])
    |> Keyword.get(key, default_config(key))
  end

  defp default_config(:backend) do
    # Auto-detect backend based on environment
    case System.get_env("LLM_BACKEND") do
      "nats" -> :nats
      "ollama" -> :ollama
      "anthropic" -> :anthropic
      _ ->
        # Default: NATS for personal version, Ollama for portable
        if nats_available?(), do: :nats, else: :ollama
    end
  end

  defp default_config(:nats_url) do
    System.get_env("NATS_URL", "nats://localhost:4222")
  end

  defp default_config(:ollama_url) do
    System.get_env("OLLAMA_URL", "http://localhost:11434")
  end

  defp default_config(:ollama_model) do
    System.get_env("OLLAMA_MODEL", "mistral")
  end

  defp default_config(:anthropic_api_key) do
    System.get_env("ANTHROPIC_API_KEY")
  end

  defp default_config(:nats_timeout_ms) do
    30_000
  end

  defp default_config(:ollama_timeout_ms) do
    10_000
  end

  defp default_config(:anthropic_timeout_ms) do
    30_000
  end

  defp default_config(_), do: nil

  defp nats_available? do
    case Application.get_env(:bot_army_job_applications, :nats_connection) do
      conn when is_pid(conn) -> true
      _ -> false
    end
  end
end
