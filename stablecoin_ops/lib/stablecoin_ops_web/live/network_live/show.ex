defmodule StablecoinOpsWeb.NetworkLive.Show do
  use StablecoinOpsWeb, :live_view

  alias StablecoinOps.Networks

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        Network {@network.id}
        <:subtitle>This is a network record from your database.</:subtitle>
        <:actions>
          <.button navigate={~p"/networks"}>
            <.icon name="hero-arrow-left" />
          </.button>
          <.button variant="primary" navigate={~p"/networks/#{@network}/edit?return_to=show"}>
            <.icon name="hero-pencil-square" /> Edit network
          </.button>
        </:actions>
      </.header>

      <.list>
        <:item title="Name">{@network.name}</:item>
        <:item title="Chain">{@network.chain_id}</:item>
      </.list>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Show Network")
     |> assign(:network, Networks.get_network!(id))}
  end
end
