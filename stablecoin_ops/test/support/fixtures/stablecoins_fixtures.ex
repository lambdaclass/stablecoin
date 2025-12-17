defmodule StablecoinOps.StablecoinsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `StablecoinOps.Stablecoins` context.
  """

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
    {:ok, stablecoin_deployment} =
      attrs
      |> Enum.into(%{
        address: "some address"
      })
      |> StablecoinOps.Stablecoins.create_stablecoin_deployment()

    stablecoin_deployment
  end
end
