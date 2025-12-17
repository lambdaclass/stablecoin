defmodule StablecoinOps.Repo do
  use Ecto.Repo,
    otp_app: :stablecoin_ops,
    adapter: Ecto.Adapters.Postgres
end
