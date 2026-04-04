defmodule BotArmyJobApplications.ListingStoreBehaviour do
  @moduledoc """
  Behaviour definition for listing storage.

  Allows different implementations (real database, mock) to be swapped via configuration.
  """

  @callback create(payload :: map()) :: {:ok, map()} | {:error, atom()}
  @callback update(tenant_id :: String.t(), listing_id :: String.t(), payload :: map()) :: {:ok, map()} | {:error, atom()}
  @callback get(tenant_id :: String.t(), listing_id :: String.t()) :: {:ok, map()} | {:error, atom()}
  @callback get_by_dedup_hash(tenant_id :: String.t(), dedup_hash :: String.t()) :: {:ok, map()} | {:error, :not_found}
  @callback list(tenant_id :: String.t(), opts :: keyword()) :: {:ok, list(map())}
  @callback clear() :: :ok
end
