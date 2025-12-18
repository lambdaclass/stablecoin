defmodule StablecoinOps.Repo.Migrations.CreateStablecoinDeployments do
  use Ecto.Migration

  def change do
    create table(:stablecoin_deployments) do
      add :address, :string
      add :stablecoin_id, references(:stablecoins, on_delete: :nothing)
      add :network_id, references(:networks, on_delete: :nothing)

      timestamps(type: :utc_datetime)
    end

    create index(:stablecoin_deployments, [:stablecoin_id])
    create index(:stablecoin_deployments, [:network_id])
  end
end
