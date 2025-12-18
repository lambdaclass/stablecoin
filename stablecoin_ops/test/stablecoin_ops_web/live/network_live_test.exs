defmodule StablecoinOpsWeb.NetworkLiveTest do
  use StablecoinOpsWeb.ConnCase

  import Phoenix.LiveViewTest
  import StablecoinOps.NetworksFixtures

  @create_attrs %{name: "some name", chain_id: 42}
  @update_attrs %{name: "some updated name", chain_id: 43}
  @invalid_attrs %{name: nil, chain_id: nil}
  defp create_network(_) do
    network = network_fixture()

    %{network: network}
  end

  describe "Index" do
    setup [:create_network]

    test "lists all networks", %{conn: conn, network: network} do
      {:ok, _index_live, html} = live(conn, ~p"/networks")

      assert html =~ "Listing Networks"
      assert html =~ network.name
    end

    test "saves new network", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/networks")

      assert {:ok, form_live, _} =
               index_live
               |> element("a", "New Network")
               |> render_click()
               |> follow_redirect(conn, ~p"/networks/new")

      assert render(form_live) =~ "New Network"

      assert form_live
             |> form("#network-form", network: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert {:ok, index_live, _html} =
               form_live
               |> form("#network-form", network: @create_attrs)
               |> render_submit()
               |> follow_redirect(conn, ~p"/networks")

      html = render(index_live)
      assert html =~ "Network created successfully"
      assert html =~ "some name"
    end

    test "updates network in listing", %{conn: conn, network: network} do
      {:ok, index_live, _html} = live(conn, ~p"/networks")

      assert {:ok, form_live, _html} =
               index_live
               |> element("#networks-#{network.id} a", "Edit")
               |> render_click()
               |> follow_redirect(conn, ~p"/networks/#{network}/edit")

      assert render(form_live) =~ "Edit Network"

      assert form_live
             |> form("#network-form", network: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert {:ok, index_live, _html} =
               form_live
               |> form("#network-form", network: @update_attrs)
               |> render_submit()
               |> follow_redirect(conn, ~p"/networks")

      html = render(index_live)
      assert html =~ "Network updated successfully"
      assert html =~ "some updated name"
    end

    test "deletes network in listing", %{conn: conn, network: network} do
      {:ok, index_live, _html} = live(conn, ~p"/networks")

      assert index_live |> element("#networks-#{network.id} a", "Delete") |> render_click()
      refute has_element?(index_live, "#networks-#{network.id}")
    end
  end

  describe "Show" do
    setup [:create_network]

    test "displays network", %{conn: conn, network: network} do
      {:ok, _show_live, html} = live(conn, ~p"/networks/#{network}")

      assert html =~ "Show Network"
      assert html =~ network.name
    end

    test "updates network and returns to show", %{conn: conn, network: network} do
      {:ok, show_live, _html} = live(conn, ~p"/networks/#{network}")

      assert {:ok, form_live, _} =
               show_live
               |> element("a", "Edit")
               |> render_click()
               |> follow_redirect(conn, ~p"/networks/#{network}/edit?return_to=show")

      assert render(form_live) =~ "Edit Network"

      assert form_live
             |> form("#network-form", network: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert {:ok, show_live, _html} =
               form_live
               |> form("#network-form", network: @update_attrs)
               |> render_submit()
               |> follow_redirect(conn, ~p"/networks/#{network}")

      html = render(show_live)
      assert html =~ "Network updated successfully"
      assert html =~ "some updated name"
    end
  end
end
