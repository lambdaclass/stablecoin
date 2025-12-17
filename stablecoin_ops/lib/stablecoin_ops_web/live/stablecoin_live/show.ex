defmodule StablecoinOpsWeb.StablecoinLive.Show do
  use StablecoinOpsWeb, :live_view

  alias StablecoinOps.Stablecoins

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        Stablecoin {@stablecoin.id}
        <:subtitle>This is a stablecoin record from your database.</:subtitle>
        <:actions>
          <.button navigate={~p"/stablecoins"}>
            <.icon name="hero-arrow-left" />
          </.button>
          <.button variant="primary" navigate={~p"/stablecoins/#{@stablecoin}/edit?return_to=show"}>
            <.icon name="hero-pencil-square" /> Edit stablecoin
          </.button>
        </:actions>
      </.header>

      <.list>
        <:item title="Name">{@stablecoin.name}</:item>
        <:item title="Symbol">{@stablecoin.symbol}</:item>
        <:item title="Decimals">{@stablecoin.decimals}</:item>
      </.list>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Show Stablecoin")
     |> assign(:stablecoin, Stablecoins.get_stablecoin!(id))}
  end
end
