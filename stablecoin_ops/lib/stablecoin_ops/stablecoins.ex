defmodule StablecoinOps.Stablecoins do
  @moduledoc """
  The Stablecoins context.
  """

  import Ecto.Query, warn: false
  alias StablecoinOps.Repo

  alias StablecoinOps.Stablecoins.{Stablecoin, StablecoinDeployment}

  @doc """
  Returns the list of stablecoins.

  ## Examples

      iex> list_stablecoins()
      [%Stablecoin{}, ...]

  """
  def list_stablecoins do
    Stablecoin
    |> Repo.all()
    |> Repo.preload(deployments: :network)
  end

  @doc """
  Gets a single stablecoin.

  Raises `Ecto.NoResultsError` if the Stablecoin does not exist.

  ## Examples

      iex> get_stablecoin!(123)
      %Stablecoin{}

      iex> get_stablecoin!(456)
      ** (Ecto.NoResultsError)

  """
  def get_stablecoin!(id), do: Repo.get!(Stablecoin, id)

  @doc """
  Creates a stablecoin.

  ## Examples

      iex> create_stablecoin(%{field: value})
      {:ok, %Stablecoin{}}

      iex> create_stablecoin(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_stablecoin(attrs) do
    %Stablecoin{}
    |> Stablecoin.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a stablecoin.

  ## Examples

      iex> update_stablecoin(stablecoin, %{field: new_value})
      {:ok, %Stablecoin{}}

      iex> update_stablecoin(stablecoin, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_stablecoin(%Stablecoin{} = stablecoin, attrs) do
    stablecoin
    |> Stablecoin.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a stablecoin.

  ## Examples

      iex> delete_stablecoin(stablecoin)
      {:ok, %Stablecoin{}}

      iex> delete_stablecoin(stablecoin)
      {:error, %Ecto.Changeset{}}

  """
  def delete_stablecoin(%Stablecoin{} = stablecoin) do
    Repo.delete(stablecoin)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking stablecoin changes.

  ## Examples

      iex> change_stablecoin(stablecoin)
      %Ecto.Changeset{data: %Stablecoin{}}

  """
  def change_stablecoin(%Stablecoin{} = stablecoin, attrs \\ %{}) do
    stablecoin
    |> Repo.preload(:deployments)
    |> Stablecoin.changeset(attrs)
  end

  alias StablecoinOps.Stablecoins.StablecoinDeployment

  @doc """
  Returns the list of stablecoin_deployments.

  ## Examples

      iex> list_stablecoin_deployments()
      [%StablecoinDeployment{}, ...]

  """
  def list_stablecoin_deployments do
    Repo.all(StablecoinDeployment)
  end

  @doc """
  Gets a single stablecoin_deployment.

  Raises `Ecto.NoResultsError` if the Stablecoin deployment does not exist.

  ## Examples

      iex> get_stablecoin_deployment!(123)
      %StablecoinDeployment{}

      iex> get_stablecoin_deployment!(456)
      ** (Ecto.NoResultsError)

  """
  def get_stablecoin_deployment!(id), do: Repo.get!(StablecoinDeployment, id)

  @doc """
  Creates a stablecoin_deployment.

  ## Examples

      iex> create_stablecoin_deployment(%{field: value})
      {:ok, %StablecoinDeployment{}}

      iex> create_stablecoin_deployment(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_stablecoin_deployment(attrs) do
    %StablecoinDeployment{}
    |> StablecoinDeployment.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a stablecoin_deployment.

  ## Examples

      iex> update_stablecoin_deployment(stablecoin_deployment, %{field: new_value})
      {:ok, %StablecoinDeployment{}}

      iex> update_stablecoin_deployment(stablecoin_deployment, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_stablecoin_deployment(%StablecoinDeployment{} = stablecoin_deployment, attrs) do
    stablecoin_deployment
    |> StablecoinDeployment.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a stablecoin_deployment.

  ## Examples

      iex> delete_stablecoin_deployment(stablecoin_deployment)
      {:ok, %StablecoinDeployment{}}

      iex> delete_stablecoin_deployment(stablecoin_deployment)
      {:error, %Ecto.Changeset{}}

  """
  def delete_stablecoin_deployment(%StablecoinDeployment{} = stablecoin_deployment) do
    Repo.delete(stablecoin_deployment)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking stablecoin_deployment changes.

  ## Examples

      iex> change_stablecoin_deployment(stablecoin_deployment)
      %Ecto.Changeset{data: %StablecoinDeployment{}}

  """
  def change_stablecoin_deployment(%StablecoinDeployment{} = stablecoin_deployment, attrs \\ %{}) do
    StablecoinDeployment.changeset(stablecoin_deployment, attrs)
  end

  def add_deployment(%Stablecoin{} = stablecoin, attrs) do
    %StablecoinDeployment{}
    |> StablecoinDeployment.changeset(attrs)
    |> Ecto.Changeset.put_assoc(:stablecoin, stablecoin)
    |> Repo.insert()
  end

  def get_stablecoin_with_deployments!(id) do
    Stablecoin
    |> Repo.get!(id)
    |> Repo.preload(deployments: :network)
  end
end
