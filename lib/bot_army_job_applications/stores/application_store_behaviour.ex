defmodule BotArmyJobApplications.ApplicationStoreBehaviour do
  @moduledoc """
  Behaviour for ApplicationStore.

  Used for dependency injection and mocking in tests.
  """

  @callback create(payload :: map()) :: {:ok, map()} | {:error, atom()}
  @callback get(application_id :: binary()) :: {:ok, map()} | {:error, atom()}
  @callback update(application_id :: binary(), payload :: map()) :: {:ok, map()} | {:error, atom()}
  @callback delete(application_id :: binary()) :: :ok | {:error, atom()}
  @callback list() :: {:ok, list(map())}
  @callback clear() :: :ok
end
