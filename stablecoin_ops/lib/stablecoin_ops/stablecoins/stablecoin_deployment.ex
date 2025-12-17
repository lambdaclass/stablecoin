defmodule StablecoinOps.Stablecoins.StablecoinDeployment do
  use Ecto.Schema
  import Ecto.Changeset

  schema "stablecoin_deployments" do
    field :address, :string
    field :stablecoin_id, :id
    field :network_id, :id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(stablecoin_deployment, attrs) do
    stablecoin_deployment
    |> cast(attrs, [:address])
    |> validate_required([:address])
  end
end
