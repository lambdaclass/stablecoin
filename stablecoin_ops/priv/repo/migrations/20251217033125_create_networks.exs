defmodule StablecoinOps.Repo.Migrations.CreateNetworks do
  use Ecto.Migration

  def change do
    create table(:networks) do
      add :name, :string
      add :chain_id, :integer

      timestamps(type: :utc_datetime)
    end
  end
end
