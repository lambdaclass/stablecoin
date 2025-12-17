defmodule StablecoinOps.Repo.Migrations.CreateStablecoins do
  use Ecto.Migration

  def change do
    create table(:stablecoins) do
      add :name, :string
      add :symbol, :string
      add :decimals, :integer

      timestamps(type: :utc_datetime)
    end
  end
end
