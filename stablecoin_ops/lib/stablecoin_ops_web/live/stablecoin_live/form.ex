defmodule StablecoinOpsWeb.StablecoinLive.Form do
  use StablecoinOpsWeb, :live_view

  alias StablecoinOps.Stablecoins
  alias StablecoinOps.Stablecoins.Stablecoin

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        {@page_title}
        <:subtitle>Use this form to manage stablecoin records in your database.</:subtitle>
      </.header>

      <.form for={@form} id="stablecoin-form" phx-change="validate" phx-submit="save">
        <.input field={@form[:name]} type="text" label="Name" />
        <.input field={@form[:symbol]} type="text" label="Symbol" />
        <.input field={@form[:decimals]} type="number" label="Decimals" />
        <footer>
          <.button phx-disable-with="Saving..." variant="primary">Save Stablecoin</.button>
          <.button navigate={return_path(@return_to, @stablecoin)}>Cancel</.button>
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
    stablecoin = Stablecoins.get_stablecoin!(id)

    socket
    |> assign(:page_title, "Edit Stablecoin")
    |> assign(:stablecoin, stablecoin)
    |> assign(:form, to_form(Stablecoins.change_stablecoin(stablecoin)))
  end

  defp apply_action(socket, :new, _params) do
    stablecoin = %Stablecoin{}

    socket
    |> assign(:page_title, "New Stablecoin")
    |> assign(:stablecoin, stablecoin)
    |> assign(:form, to_form(Stablecoins.change_stablecoin(stablecoin)))
  end

  @impl true
  def handle_event("validate", %{"stablecoin" => stablecoin_params}, socket) do
    changeset = Stablecoins.change_stablecoin(socket.assigns.stablecoin, stablecoin_params)
    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"stablecoin" => stablecoin_params}, socket) do
    save_stablecoin(socket, socket.assigns.live_action, stablecoin_params)
  end

  defp save_stablecoin(socket, :edit, stablecoin_params) do
    case Stablecoins.update_stablecoin(socket.assigns.stablecoin, stablecoin_params) do
      {:ok, stablecoin} ->
        {:noreply,
         socket
         |> put_flash(:info, "Stablecoin updated successfully")
         |> push_navigate(to: return_path(socket.assigns.return_to, stablecoin))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save_stablecoin(socket, :new, stablecoin_params) do
    case Stablecoins.create_stablecoin(stablecoin_params) do
      {:ok, stablecoin} ->
        {:noreply,
         socket
         |> put_flash(:info, "Stablecoin created successfully")
         |> push_navigate(to: return_path(socket.assigns.return_to, stablecoin))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp return_path("index", _stablecoin), do: ~p"/stablecoins"
  defp return_path("show", stablecoin), do: ~p"/stablecoins/#{stablecoin}"
end
