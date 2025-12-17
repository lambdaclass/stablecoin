defmodule StablecoinOpsWeb.NetworkLive.Form do
  use StablecoinOpsWeb, :live_view

  alias StablecoinOps.Networks
  alias StablecoinOps.Networks.Network

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        {@page_title}
        <:subtitle>Use this form to manage network records in your database.</:subtitle>
      </.header>

      <.form for={@form} id="network-form" phx-change="validate" phx-submit="save">
        <.input field={@form[:name]} type="text" label="Name" />
        <.input field={@form[:chain_id]} type="number" label="Chain" />
        <footer>
          <.button phx-disable-with="Saving..." variant="primary">Save Network</.button>
          <.button navigate={return_path(@return_to, @network)}>Cancel</.button>
        </footer>
      </.form>
    </Layouts.app>
    """
  end

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> assign(:return_to, return_to(params["return_to"]))
     |> apply_action(socket.assigns.live_action, params)}
  end

  defp return_to("show"), do: "show"
  defp return_to(_), do: "index"

  defp apply_action(socket, :edit, %{"id" => id}) do
    network = Networks.get_network!(id)

    socket
    |> assign(:page_title, "Edit Network")
    |> assign(:network, network)
    |> assign(:form, to_form(Networks.change_network(network)))
  end

  defp apply_action(socket, :new, _params) do
    network = %Network{}

    socket
    |> assign(:page_title, "New Network")
    |> assign(:network, network)
    |> assign(:form, to_form(Networks.change_network(network)))
  end

  @impl true
  def handle_event("validate", %{"network" => network_params}, socket) do
    changeset = Networks.change_network(socket.assigns.network, network_params)
    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"network" => network_params}, socket) do
    save_network(socket, socket.assigns.live_action, network_params)
  end

  defp save_network(socket, :edit, network_params) do
    case Networks.update_network(socket.assigns.network, network_params) do
      {:ok, network} ->
        {:noreply,
         socket
         |> put_flash(:info, "Network updated successfully")
         |> push_navigate(to: return_path(socket.assigns.return_to, network))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save_network(socket, :new, network_params) do
    case Networks.create_network(network_params) do
      {:ok, network} ->
        {:noreply,
         socket
         |> put_flash(:info, "Network created successfully")
         |> push_navigate(to: return_path(socket.assigns.return_to, network))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp return_path("index", _network), do: ~p"/networks"
  defp return_path("show", network), do: ~p"/networks/#{network}"
end
