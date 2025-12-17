defmodule StablecoinOpsWeb.HomeLive do
  use StablecoinOpsWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="max-w-4xl mx-auto">
        <.header class="text-center">
          Manage your stablecoins and networks
        </.header>

        <div class="mt-12 grid grid-cols-1 gap-6 sm:grid-cols-2">
          <.link
            navigate={~p"/stablecoins"}
            class="group relative block rounded-2xl bg-zinc-50 p-8 hover:bg-zinc-100 dark:bg-zinc-800 dark:hover:bg-zinc-700 transition-all duration-200 hover:shadow-lg hover:-translate-y-1"
          >
            <div class="flex items-center gap-4">
              <div class="flex h-14 w-14 items-center justify-center rounded-full bg-blue-100 text-blue-600 dark:bg-blue-900 dark:text-blue-300 group-hover:scale-110 transition-transform duration-200">
                <.icon name="hero-currency-dollar" class="h-7 w-7" />
              </div>
              <div>
                <h3 class="text-lg font-semibold text-zinc-900 dark:text-zinc-100">
                  Stablecoins
                </h3>
                <p class="mt-1 text-sm text-zinc-600 dark:text-zinc-400">
                  Manage stablecoin tokens and deployments
                </p>
              </div>
            </div>
            <div class="mt-4 flex items-center text-sm font-medium text-blue-600 dark:text-blue-400">
              View stablecoins
              <.icon name="hero-arrow-right" class="ml-2 h-4 w-4 group-hover:translate-x-1 transition-transform duration-200" />
            </div>
          </.link>

          <.link
            navigate={~p"/networks"}
            class="group relative block rounded-2xl bg-zinc-50 p-8 hover:bg-zinc-100 dark:bg-zinc-800 dark:hover:bg-zinc-700 transition-all duration-200 hover:shadow-lg hover:-translate-y-1"
          >
            <div class="flex items-center gap-4">
              <div class="flex h-14 w-14 items-center justify-center rounded-full bg-emerald-100 text-emerald-600 dark:bg-emerald-900 dark:text-emerald-300 group-hover:scale-110 transition-transform duration-200">
                <.icon name="hero-globe-alt" class="h-7 w-7" />
              </div>
              <div>
                <h3 class="text-lg font-semibold text-zinc-900 dark:text-zinc-100">
                  Networks
                </h3>
                <p class="mt-1 text-sm text-zinc-600 dark:text-zinc-400">
                  Configure blockchain networks
                </p>
              </div>
            </div>
            <div class="mt-4 flex items-center text-sm font-medium text-emerald-600 dark:text-emerald-400">
              View networks
              <.icon name="hero-arrow-right" class="ml-2 h-4 w-4 group-hover:translate-x-1 transition-transform duration-200" />
            </div>
          </.link>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Home")}
  end
end
