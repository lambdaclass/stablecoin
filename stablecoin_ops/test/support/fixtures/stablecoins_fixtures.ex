defmodule StablecoinOps.StablecoinsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `StablecoinOps.Stablecoins` context.
  """
  import StablecoinOps.NetworksFixtures

  @doc """
  Generate a stablecoin.
  """
  def stablecoin_fixture(attrs \\ %{}) do
    {:ok, stablecoin} =
      attrs
      |> Enum.into(%{
        decimals: 42,
        name: "some name",
        symbol: "some symbol"
      })
      |> StablecoinOps.Stablecoins.create_stablecoin()

    stablecoin
  end

  @doc """
  Generate a stablecoin_deployment.
  """
  def stablecoin_deployment_fixture(attrs \\ %{}) do
    stablecoin = attrs[:stablecoin] || stablecoin_fixture()
    network = attrs[:network] || network_fixture()
    {:ok, stablecoin_deployment} =
      attrs
      |> Enum.into(%{
        address: "some address",
        stablecoin_id: stablecoin.id,
        network_id: network.id
      })
      |> StablecoinOps.Stablecoins.create_stablecoin_deployment()

    stablecoin_deployment
  end
end
