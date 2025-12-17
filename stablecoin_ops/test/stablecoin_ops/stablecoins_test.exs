defmodule StablecoinOps.StablecoinsTest do
  use StablecoinOps.DataCase

  alias StablecoinOps.Stablecoins

  describe "stablecoins" do
    alias StablecoinOps.Stablecoins.Stablecoin

    import StablecoinOps.StablecoinsFixtures

    @invalid_attrs %{decimals: nil, name: nil, symbol: nil}

    test "list_stablecoins/0 returns all stablecoins" do
      stablecoin = stablecoin_fixture()
      assert Stablecoins.list_stablecoins() == [stablecoin]
    end

    test "get_stablecoin!/1 returns the stablecoin with given id" do
      stablecoin = stablecoin_fixture()
      assert Stablecoins.get_stablecoin!(stablecoin.id) == stablecoin
    end

    test "create_stablecoin/1 with valid data creates a stablecoin" do
      valid_attrs = %{decimals: 42, name: "some name", symbol: "some symbol"}

      assert {:ok, %Stablecoin{} = stablecoin} = Stablecoins.create_stablecoin(valid_attrs)
      assert stablecoin.decimals == 42
      assert stablecoin.name == "some name"
      assert stablecoin.symbol == "some symbol"
    end

    test "create_stablecoin/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Stablecoins.create_stablecoin(@invalid_attrs)
    end

    test "update_stablecoin/2 with valid data updates the stablecoin" do
      stablecoin = stablecoin_fixture()
      update_attrs = %{decimals: 43, name: "some updated name", symbol: "some updated symbol"}

      assert {:ok, %Stablecoin{} = stablecoin} = Stablecoins.update_stablecoin(stablecoin, update_attrs)
      assert stablecoin.decimals == 43
      assert stablecoin.name == "some updated name"
      assert stablecoin.symbol == "some updated symbol"
    end

    test "update_stablecoin/2 with invalid data returns error changeset" do
      stablecoin = stablecoin_fixture()
      assert {:error, %Ecto.Changeset{}} = Stablecoins.update_stablecoin(stablecoin, @invalid_attrs)
      assert stablecoin == Stablecoins.get_stablecoin!(stablecoin.id)
    end

    test "delete_stablecoin/1 deletes the stablecoin" do
      stablecoin = stablecoin_fixture()
      assert {:ok, %Stablecoin{}} = Stablecoins.delete_stablecoin(stablecoin)
      assert_raise Ecto.NoResultsError, fn -> Stablecoins.get_stablecoin!(stablecoin.id) end
    end

    test "change_stablecoin/1 returns a stablecoin changeset" do
      stablecoin = stablecoin_fixture()
      assert %Ecto.Changeset{} = Stablecoins.change_stablecoin(stablecoin)
    end
  end

  describe "stablecoin_deployments" do
    alias StablecoinOps.Stablecoins.StablecoinDeployment

    import StablecoinOps.StablecoinsFixtures

    @invalid_attrs %{address: nil}

    test "list_stablecoin_deployments/0 returns all stablecoin_deployments" do
      stablecoin_deployment = stablecoin_deployment_fixture()
      assert Stablecoins.list_stablecoin_deployments() == [stablecoin_deployment]
    end

    test "get_stablecoin_deployment!/1 returns the stablecoin_deployment with given id" do
      stablecoin_deployment = stablecoin_deployment_fixture()
      assert Stablecoins.get_stablecoin_deployment!(stablecoin_deployment.id) == stablecoin_deployment
    end

    test "create_stablecoin_deployment/1 with valid data creates a stablecoin_deployment" do
      valid_attrs = %{address: "some address"}

      assert {:ok, %StablecoinDeployment{} = stablecoin_deployment} = Stablecoins.create_stablecoin_deployment(valid_attrs)
      assert stablecoin_deployment.address == "some address"
    end

    test "create_stablecoin_deployment/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Stablecoins.create_stablecoin_deployment(@invalid_attrs)
    end

    test "update_stablecoin_deployment/2 with valid data updates the stablecoin_deployment" do
      stablecoin_deployment = stablecoin_deployment_fixture()
      update_attrs = %{address: "some updated address"}

      assert {:ok, %StablecoinDeployment{} = stablecoin_deployment} = Stablecoins.update_stablecoin_deployment(stablecoin_deployment, update_attrs)
      assert stablecoin_deployment.address == "some updated address"
    end

    test "update_stablecoin_deployment/2 with invalid data returns error changeset" do
      stablecoin_deployment = stablecoin_deployment_fixture()
      assert {:error, %Ecto.Changeset{}} = Stablecoins.update_stablecoin_deployment(stablecoin_deployment, @invalid_attrs)
      assert stablecoin_deployment == Stablecoins.get_stablecoin_deployment!(stablecoin_deployment.id)
    end

    test "delete_stablecoin_deployment/1 deletes the stablecoin_deployment" do
      stablecoin_deployment = stablecoin_deployment_fixture()
      assert {:ok, %StablecoinDeployment{}} = Stablecoins.delete_stablecoin_deployment(stablecoin_deployment)
      assert_raise Ecto.NoResultsError, fn -> Stablecoins.get_stablecoin_deployment!(stablecoin_deployment.id) end
    end

    test "change_stablecoin_deployment/1 returns a stablecoin_deployment changeset" do
      stablecoin_deployment = stablecoin_deployment_fixture()
      assert %Ecto.Changeset{} = Stablecoins.change_stablecoin_deployment(stablecoin_deployment)
    end
  end
end
