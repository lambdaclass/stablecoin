defmodule StablecoinOps.Stablecoins.Stablecoin do
  use Ecto.Schema
  import Ecto.Changeset

  schema "stablecoins" do
    field :name, :string
    field :symbol, :string
    field :decimals, :integer

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(stablecoin, attrs) do
    stablecoin
    |> cast(attrs, [:name, :symbol, :decimals])
    |> validate_required([:name, :symbol, :decimals])
  end
end
