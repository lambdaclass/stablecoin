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
      <section class="mt-8">
        <h2 class="text-lg font-semibold mb-4">Deployments</h2>
        <%= if Enum.empty?(@stablecoin.deployments) do %>
          <p class="text-zinc-500 dark:text-zinc-400">No deployments yet.</p>
        <% else %>
          <.table id="deployments" rows={@stablecoin.deployments}>
            <:col :let={deployment} label="Network">{deployment.network.name}</:col>
            <:col :let={deployment} label="Address">
              <code class="text-sm font-mono">{deployment.address}</code>
            </:col>
          </.table>
        <% end %>
      </section>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Show Stablecoin")
     |> assign(:stablecoin, Stablecoins.get_stablecoin_with_deployments!(id))}
  end
end
