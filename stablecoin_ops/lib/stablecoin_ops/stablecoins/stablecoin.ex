defmodule StablecoinOps.Stablecoins.Stablecoin do
  use Ecto.Schema
  import Ecto.Changeset
  alias StablecoinOps.Stablecoins.StablecoinDeployment

  schema "stablecoins" do
    field :name, :string
    field :symbol, :string
    field :decimals, :integer
    has_many :deployments, StablecoinDeployment, on_replace: :delete

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(stablecoin, attrs) do
    stablecoin
    |> cast(attrs, [:name, :symbol, :decimals])
    |> validate_required([:name, :symbol, :decimals])
    |> cast_assoc(:deployments, with: &StablecoinDeployment.nested_changeset/2)
  end
end
