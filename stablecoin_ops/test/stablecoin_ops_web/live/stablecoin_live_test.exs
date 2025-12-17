defmodule StablecoinOpsWeb.StablecoinLiveTest do
  use StablecoinOpsWeb.ConnCase

  import Phoenix.LiveViewTest
  import StablecoinOps.StablecoinsFixtures

  @create_attrs %{decimals: 42, name: "some name", symbol: "some symbol"}
  @update_attrs %{decimals: 43, name: "some updated name", symbol: "some updated symbol"}
  @invalid_attrs %{decimals: nil, name: nil, symbol: nil}
  defp create_stablecoin(_) do
    stablecoin = stablecoin_fixture()

    %{stablecoin: stablecoin}
  end

  describe "Index" do
    setup [:create_stablecoin]

    test "lists all stablecoins", %{conn: conn, stablecoin: stablecoin} do
      {:ok, _index_live, html} = live(conn, ~p"/stablecoins")

      assert html =~ "Listing Stablecoins"
      assert html =~ stablecoin.name
    end

    test "saves new stablecoin", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/stablecoins")

      assert {:ok, form_live, _} =
               index_live
               |> element("a", "New Stablecoin")
               |> render_click()
               |> follow_redirect(conn, ~p"/stablecoins/new")

      assert render(form_live) =~ "New Stablecoin"

      assert form_live
             |> form("#stablecoin-form", stablecoin: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert {:ok, index_live, _html} =
               form_live
               |> form("#stablecoin-form", stablecoin: @create_attrs)
               |> render_submit()
               |> follow_redirect(conn, ~p"/stablecoins")

      html = render(index_live)
      assert html =~ "Stablecoin created successfully"
      assert html =~ "some name"
    end

    test "updates stablecoin in listing", %{conn: conn, stablecoin: stablecoin} do
      {:ok, index_live, _html} = live(conn, ~p"/stablecoins")

      assert {:ok, form_live, _html} =
               index_live
               |> element("#stablecoins-#{stablecoin.id} a", "Edit")
               |> render_click()
               |> follow_redirect(conn, ~p"/stablecoins/#{stablecoin}/edit")

      assert render(form_live) =~ "Edit Stablecoin"

      assert form_live
             |> form("#stablecoin-form", stablecoin: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert {:ok, index_live, _html} =
               form_live
               |> form("#stablecoin-form", stablecoin: @update_attrs)
               |> render_submit()
               |> follow_redirect(conn, ~p"/stablecoins")

      html = render(index_live)
      assert html =~ "Stablecoin updated successfully"
      assert html =~ "some updated name"
    end

    test "deletes stablecoin in listing", %{conn: conn, stablecoin: stablecoin} do
      {:ok, index_live, _html} = live(conn, ~p"/stablecoins")

      assert index_live |> element("#stablecoins-#{stablecoin.id} a", "Delete") |> render_click()
      refute has_element?(index_live, "#stablecoins-#{stablecoin.id}")
    end
  end

  describe "Show" do
    setup [:create_stablecoin]

    test "displays stablecoin", %{conn: conn, stablecoin: stablecoin} do
      {:ok, _show_live, html} = live(conn, ~p"/stablecoins/#{stablecoin}")

      assert html =~ "Show Stablecoin"
      assert html =~ stablecoin.name
    end

    test "updates stablecoin and returns to show", %{conn: conn, stablecoin: stablecoin} do
      {:ok, show_live, _html} = live(conn, ~p"/stablecoins/#{stablecoin}")

      assert {:ok, form_live, _} =
               show_live
               |> element("a", "Edit")
               |> render_click()
               |> follow_redirect(conn, ~p"/stablecoins/#{stablecoin}/edit?return_to=show")

      assert render(form_live) =~ "Edit Stablecoin"

      assert form_live
             |> form("#stablecoin-form", stablecoin: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert {:ok, show_live, _html} =
               form_live
               |> form("#stablecoin-form", stablecoin: @update_attrs)
               |> render_submit()
               |> follow_redirect(conn, ~p"/stablecoins/#{stablecoin}")

      html = render(show_live)
      assert html =~ "Stablecoin updated successfully"
      assert html =~ "some updated name"
    end
  end
end
