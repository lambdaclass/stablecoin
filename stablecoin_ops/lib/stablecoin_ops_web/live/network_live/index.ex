defmodule StablecoinOpsWeb.NetworkLive.Index do
  use StablecoinOpsWeb, :live_view

  alias StablecoinOps.Networks

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        Listing Networks
        <:actions>
          <.button variant="primary" navigate={~p"/networks/new"}>
            <.icon name="hero-plus" /> New Network
          </.button>
        </:actions>
      </.header>

      <.table
        id="networks"
        rows={@streams.networks}
        row_click={fn {_id, network} -> JS.navigate(~p"/networks/#{network}") end}
      >
        <:col :let={{_id, network}} label="Name">{network.name}</:col>
        <:col :let={{_id, network}} label="Chain">{network.chain_id}</:col>
        <:action :let={{_id, network}}>
          <div class="sr-only">
            <.link navigate={~p"/networks/#{network}"}>Show</.link>
          </div>
          <.link navigate={~p"/networks/#{network}/edit"}>Edit</.link>
        </:action>
        <:action :let={{id, network}}>
          <.link
            phx-click={JS.push("delete", value: %{id: network.id}) |> hide("##{id}")}
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
     |> assign(:page_title, "Listing Networks")
     |> stream(:networks, list_networks())}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    network = Networks.get_network!(id)
    {:ok, _} = Networks.delete_network(network)

    {:noreply, stream_delete(socket, :networks, network)}
  end

  defp list_networks() do
    Networks.list_networks()
  end
end
