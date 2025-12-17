defmodule StablecoinOps.Networks.Network do
  use Ecto.Schema
  import Ecto.Changeset

  schema "networks" do
    field :name, :string
    field :chain_id, :integer

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(network, attrs) do
    network
    |> cast(attrs, [:name, :chain_id])
    |> validate_required([:name, :chain_id])
  end
end
