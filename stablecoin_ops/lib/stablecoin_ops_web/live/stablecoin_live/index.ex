defmodule StablecoinOpsWeb.StablecoinLive.Index do
  use StablecoinOpsWeb, :live_view

  alias StablecoinOps.Stablecoins

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        Listing Stablecoins
        <:actions>
          <.button variant="primary" navigate={~p"/stablecoins/new"}>
            <.icon name="hero-plus" /> New Stablecoin
          </.button>
        </:actions>
      </.header>

      <.table
        id="stablecoins"
        rows={@streams.stablecoins}
        row_click={fn {_id, stablecoin} -> JS.navigate(~p"/stablecoins/#{stablecoin}") end}
      >
        <:col :let={{_id, stablecoin}} label="Name">{stablecoin.name}</:col>
        <:col :let={{_id, stablecoin}} label="Symbol">{stablecoin.symbol}</:col>
        <:col :let={{_id, stablecoin}} label="Decimals">{stablecoin.decimals}</:col>
        <:action :let={{_id, stablecoin}}>
          <div class="sr-only">
            <.link navigate={~p"/stablecoins/#{stablecoin}"}>Show</.link>
          </div>
          <.link navigate={~p"/stablecoins/#{stablecoin}/edit"}>Edit</.link>
        </:action>
        <:action :let={{id, stablecoin}}>
          <.link
            phx-click={JS.push("delete", value: %{id: stablecoin.id}) |> hide("##{id}")}
            data-confirm="Are you sure?"
          >
            Delete
          </.link>
        </:action>
      </.table>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Listing Stablecoins")
     |> stream(:stablecoins, list_stablecoins())}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    stablecoin = Stablecoins.get_stablecoin!(id)
    {:ok, _} = Stablecoins.delete_stablecoin(stablecoin)

    {:noreply, stream_delete(socket, :stablecoins, stablecoin)}
  end

  defp list_stablecoins() do
    Stablecoins.list_stablecoins()
  end
end
