defmodule BotArmyJobApplications.ResumeStoreBehaviour do
  @moduledoc """
  Behaviour definition for resume storage.

  Allows different implementations (real database, mock) to be swapped via configuration.
  """

  @callback create(payload :: map()) :: {:ok, map()} | {:error, atom()}
  @callback update(resume_id :: String.t(), payload :: map()) :: {:ok, map()} | {:error, atom()}
  @callback get(resume_id :: String.t()) :: {:ok, map()} | {:error, atom()}
  @callback list() :: {:ok, list(map())}
  @callback clear() :: :ok

  # TUI management callbacks
  @callback create_from_parsed(parsed_data :: map(), file_metadata :: map()) ::
    {:ok, map()} | {:error, atom() | String.t()}

  @callback replace_full(resume_id :: String.t(), parsed_data :: map()) ::
    {:ok, map()} | {:error, atom() | String.t()}

  @callback delete(resume_id :: String.t()) ::
    :ok | {:error, atom() | String.t()}
end
