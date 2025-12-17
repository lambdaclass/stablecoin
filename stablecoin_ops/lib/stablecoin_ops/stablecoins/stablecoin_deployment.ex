defmodule StablecoinOps.Stablecoins.StablecoinDeployment do
  use Ecto.Schema
  import Ecto.Changeset

  schema "stablecoin_deployments" do
    field(:address, :string)
    belongs_to(:stablecoin, StablecoinOps.Stablecoins.Stablecoin)
    belongs_to(:network, StablecoinOps.Networks.Network)

    timestamps(type: :utc_datetime)
  end

  def changeset(stablecoin_deployment, attrs) do
    stablecoin_deployment
    |> cast(attrs, [:address, :stablecoin_id, :network_id])
    |> validate_required([:address, :stablecoin_id, :network_id])
    |> unique_constraint([:stablecoin_id, :network_id])
  end

  # Used by cast_assoc - stablecoin_id comes from parent
  def nested_changeset(stablecoin_deployment, attrs) do
    stablecoin_deployment
    |> cast(attrs, [:address, :network_id])
    |> validate_required([:address, :network_id])
    |> unique_constraint([:stablecoin_id, :network_id])
  end
end
