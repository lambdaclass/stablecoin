defmodule StablecoinOps.NetworksFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `StablecoinOps.Networks` context.
  """

  @doc """
  Generate a network.
  """
  def network_fixture(attrs \\ %{}) do
    {:ok, network} =
      attrs
      |> Enum.into(%{
        chain_id: 42,
        name: "some name"
      })
      |> StablecoinOps.Networks.create_network()

    network
  end
end
