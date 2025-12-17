defmodule StablecoinOpsWeb.StablecoinLive.Form do
  use StablecoinOpsWeb, :live_view

  alias StablecoinOps.Stablecoins
  alias StablecoinOps.Stablecoins.{Stablecoin, StablecoinDeployment}
  alias StablecoinOps.Networks

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

        <section class="mt-8 border-t border-zinc-200 dark:border-zinc-700 pt-6">
          <div class="flex items-center justify-between mb-4">
            <h2 class="text-lg font-semibold">Deployments</h2>
            <.button type="button" phx-click="add_deployment">
              <.icon name="hero-plus" class="w-4 h-4 mr-1" /> Add Deployment
            </.button>
          </div>

          <.inputs_for :let={deployment_form} field={@form[:deployments]}>
            <div class="flex gap-4 items-end mb-4 p-4 bg-zinc-50 dark:bg-zinc-800 rounded-lg">
              <input type="hidden" name="stablecoin[deployments_order][]" value={deployment_form.index} />
              <div class="flex-1">
                <.input
                  field={deployment_form[:network_id]}
                  type="select"
                  label="Network"
                  options={Enum.map(@networks, &{&1.name, &1.id})}
                  prompt="Select network"
                />
              </div>
              <div class="flex-[2]">
                <.input field={deployment_form[:address]} type="text" label="Contract Address" />
              </div>
              <.button
                type="button"
                name="stablecoin[deployments_drop][]"
                value={deployment_form.index}
                phx-click={JS.dispatch("change")}
                class="text-red-600 hover:text-red-800"
              >
                <.icon name="hero-trash" class="w-5 h-5" />
              </.button>
            </div>
          </.inputs_for>

          <input type="hidden" name="stablecoin[deployments_drop][]" />
        </section>

        <footer class="mt-6">
          <.button phx-disable-with="Saving..." variant="primary">Save Stablecoin</.button>
          <.button type="button" navigate={return_path(@return_to, @stablecoin)}>Cancel</.button>
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
     |> assign(:networks, Networks.list_networks())
     |> apply_action(socket.assigns.live_action, params)}
  end

  defp return_to("show"), do: "show"
  defp return_to(_), do: "index"

  defp apply_action(socket, :edit, %{"id" => id}) do
    stablecoin = Stablecoins.get_stablecoin_with_deployments!(id)

    socket
    |> assign(:page_title, "Edit Stablecoin")
    |> assign(:stablecoin, stablecoin)
    |> assign(:form, to_form(Stablecoins.change_stablecoin(stablecoin)))
  end

  defp apply_action(socket, :new, _params) do
    stablecoin = %Stablecoin{deployments: []}

    socket
    |> assign(:page_title, "New Stablecoin")
    |> assign(:stablecoin, stablecoin)
    |> assign(:form, to_form(Stablecoins.change_stablecoin(stablecoin)))
  end

  @impl true
  def handle_event("validate", %{"stablecoin" => stablecoin_params}, socket) do
    changeset =
      socket.assigns.stablecoin
      |> Stablecoins.change_stablecoin(stablecoin_params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("add_deployment", _, socket) do
    changeset = socket.assigns.form.source

    existing_deployments = Ecto.Changeset.get_assoc(changeset, :deployments)
    new_deployment = %StablecoinDeployment{}

    updated_changeset =
      Ecto.Changeset.put_assoc(changeset, :deployments, existing_deployments ++ [new_deployment])

    {:noreply, assign(socket, form: to_form(updated_changeset))}
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
