defmodule BotArmyJobApplications.ListingStoreBehaviour do
  @moduledoc """
  Behaviour definition for listing storage.

  Allows different implementations (real database, mock) to be swapped via configuration.
  """

  @callback create(payload :: map()) :: {:ok, map()} | {:error, atom()}
  @callback update(listing_id :: String.t(), payload :: map()) :: {:ok, map()} | {:error, atom()}
  @callback get(listing_id :: String.t()) :: {:ok, map()} | {:error, atom()}
  @callback list(opts :: keyword()) :: {:ok, list(map())}
  @callback clear() :: :ok
end
