defmodule Mix.Tasks.Letterbox.Install do
  @moduledoc """
  Installs Letterbox in a Phoenix application.

      $ mix igniter.install letterbox

  or, with Letterbox already in the deps, `mix letterbox.install`.
  [Igniter](https://hexdocs.pm/igniter) shows each change as a diff
  before it writes, and running the task again changes nothing:

    * the router has the ingresses' webhooks, in a pipeline of their own
      with no session and no CSRF token:

          pipeline :webhooks do
            plug :accepts, ["json"]
          end

          scope "/inbound" do
            pipe_through :webhooks
            post "/webhooks/:ingress", Letterbox.Plug, []
          end

      The app's to change: the path, the scope and the pipeline (see
      `Letterbox.Plug`). Run again, the task finds the route by its plug,
      wherever it is, and adds no other.
    * the migration of Letterbox's table (`mix letterbox.gen.migration`);
    * `.formatter.exs` imports Letterbox's, so routes are written
      `route "support@", to: …`;
    * `config :letterbox, repo: MyApp.Repo, routing: MyApp.Mailboxes`;
    * `lib/my_app/mailboxes.ex`, the routes, which give every message to
      `lib/my_app/mailboxes/inbox.ex`, a first mailbox that logs what it
      gets: the app's own files, written once;
    * the application starts `Letterbox.Sweeper` after the repo: messages
      that were waiting are resumed, and those done with for 30 days are
      deleted.

    * the endpoint's `Plug.Parsers` keeps a webhook's body as it was sent,
      for its signature (`PhoenixMountable.RawBody`).

  Then say how messages reach the app, in `config/runtime.exs`
  (`Letterbox.Ingress`).
  """

  use PhoenixMountable.Install,
    otp_app: :letterbox,
    migrations: Letterbox.Migrations,
    raw_body: true,
    manual: "See https://hexdocs.pm/letterbox/readme.html#install"

  if Code.ensure_loaded?(Igniter) do
    alias Igniter.Libs.Phoenix, as: Phx
    alias Igniter.Project.Application, as: App
    alias Igniter.Project.Config
    alias Igniter.Project.Formatter
    alias Igniter.Project.Module, as: Mod

    @impl PhoenixMountable.Install
    def install(igniter) do
      prefix = Mod.module_name_prefix(igniter)
      repo = Module.concat(prefix, Repo)
      routing = Module.concat(prefix, Mailboxes)
      inbox = Module.concat(routing, Inbox)

      igniter
      |> Formatter.import_dep(:letterbox)
      |> webhooks()
      |> Config.configure_new("config.exs", :letterbox, [:repo], repo)
      |> Config.configure_new("config.exs", :letterbox, [:routing], routing)
      |> create_once(routing, routing(inbox))
      |> create_once(inbox, inbox())
      |> App.add_new_child({Letterbox.Sweeper, {:code, quote(do: [incinerate_after: 30])}},
        after: [repo]
      )
      |> Igniter.add_notice(notice())
    end

    # The webhooks' route, unless the router has one: found by its plug,
    # wherever the app moved it.
    defp webhooks(igniter) do
      {igniter, router} = Phx.select_router(igniter)

      cond do
        router == nil ->
          Igniter.add_warning(
            igniter,
            "Letterbox found no router: add its webhooks' route by hand (see Letterbox.Plug)."
          )

        routed?(igniter, router) ->
          igniter

        true ->
          igniter
          |> Phx.add_pipeline(:webhooks, ~s|plug :accepts, ["json"]|, router: router)
          |> Phx.add_scope(
            "/inbound",
            """
            pipe_through :webhooks
            post "/webhooks/:ingress", Letterbox.Plug, []
            """,
            router: router
          )
      end
    end

    defp routed?(igniter, router) do
      case Mod.find_module(igniter, router) do
        {:ok, {_igniter, source, _zipper}} ->
          source |> Rewrite.Source.get(:content) |> String.contains?("Letterbox.Plug")

        {:error, _igniter} ->
          false
      end
    end

    # Written once: the app's own after that.
    defp create_once(igniter, module, contents) do
      case Mod.module_exists(igniter, module) do
        {true, igniter} -> igniter
        {false, igniter} -> Mod.create_module(igniter, module, contents)
      end
    end

    defp routing(inbox) do
      """
      @moduledoc \"\"\"
      Which mailbox takes which message. See `Letterbox.Routing`.
      \"\"\"
      use Letterbox.Routing

      # route "support@", to: #{inspect(Module.concat(Module.split(inbox) |> Enum.drop(-1)))}.Support
      route :all, to: #{inspect(inbox)}
      """
    end

    defp inbox do
      ~S'''
      @moduledoc """
      Every message no other route takes. See `Letterbox.Mailbox`.
      """
      use Letterbox.Mailbox

      require Logger

      @impl true
      def process(message) do
        Logger.info("Letterbox: #{inspect(message.subject)} from #{message.from}")
        :ok
      end
      '''
    end

    defp notice do
      """
      Letterbox: say how messages reach the app, in config/runtime.exs:

          config :letterbox,
            ingresses: [
              resend: [
                secret: System.fetch_env!("RESEND_WEBHOOK_SECRET"),
                api_key: System.fetch_env!("RESEND_API_KEY")
              ]
            ]

      See Letterbox.Ingress.

      For the development page, in the router's dev_routes block:

          import Letterbox.Dev.Router
          scope "/dev" do
            pipe_through :browser
            letterbox_dev "/letterbox"
          end
      """
    end
  end
end
