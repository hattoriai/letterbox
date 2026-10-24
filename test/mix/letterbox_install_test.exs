defmodule Mix.Tasks.Letterbox.InstallTest do
  # Not async: while it works, Igniter puts the test app's config in the
  # application environment (`config :letterbox, repo: Test.Repo`), and
  # the other tests would read it.
  use ExUnit.Case, async: false

  import Igniter.Test

  @router """
  defmodule TestWeb.Router do
    use Phoenix.Router

    pipeline :browser do
      plug :accepts, ["html"]
      plug :protect_from_forgery
    end

    scope "/", TestWeb do
      pipe_through :browser
    end
  end
  """

  @application """
  defmodule Test.Application do
    use Application

    def start(_type, _args) do
      children = [
        Test.Repo,
        TestWeb.Endpoint
      ]

      Supervisor.start_link(children, strategy: :one_for_one, name: Test.Supervisor)
    end
  end
  """

  @mix_exs """
  defmodule Test.MixProject do
    use Mix.Project

    def project, do: [app: :test, version: "0.1.0", deps: deps()]

    def application, do: [mod: {Test.Application, []}, extra_applications: [:logger]]

    defp deps, do: []
  end
  """

  # A Phoenix app's files, written here rather than by phx_test_project/1,
  # which needs the phx_new archive.
  defp install(files \\ %{}) do
    [
      files:
        Map.merge(
          %{
            ".formatter.exs" =>
              "[import_deps: [:phoenix], inputs: [\"{lib,test}/**/*.{ex,exs}\"]]\n",
            "lib/test_web/router.ex" => @router,
            "mix.exs" => @mix_exs,
            "lib/test/application.ex" => @application,
            "lib/test/repo.ex" =>
              "defmodule Test.Repo do\n  use Ecto.Repo, otp_app: :test, adapter: Ecto.Adapters.Postgres\nend\n"
          },
          files
        ),
      app_name: :test
    ]
    |> test_project()
    |> Igniter.compose_task(Mix.Tasks.Letterbox.Install, [])
  end

  defp file(igniter, path) do
    igniter
    |> apply_igniter!()
    |> Map.fetch!(:rewrite)
    |> Rewrite.source!(path)
    |> Rewrite.Source.get(:content)
  end

  test "adds the webhooks' route, in a pipeline with no CSRF token" do
    router = install() |> file("lib/test_web/router.ex")

    assert router =~ ~r/pipeline :webhooks do\s+plug :accepts, \["json"\]\s+end/

    assert router =~
             ~r|scope "/inbound" do\s+pipe_through :webhooks\s+post "/webhooks/:ingress", Letterbox.Plug, \[\]|
  end

  test "adds no route when the app has one, wherever it moved it" do
    moved =
      String.replace(
        @router,
        "scope \"/\", TestWeb do",
        "scope \"/mail\" do\n    post \"/resend\", Letterbox.Plug, ingress: :resend\n  end\n\n  scope \"/\", TestWeb do"
      )

    router = install(%{"lib/test_web/router.ex" => moved}) |> file("lib/test_web/router.ex")

    refute router =~ "pipeline :webhooks"
    assert length(String.split(router, "Letterbox.Plug")) == 2
  end

  test "configures the repo and the routes" do
    config = install() |> file("config/config.exs")

    assert config =~ "repo: Test.Repo"
    assert config =~ "routing: Test.Mailboxes"
  end

  test "writes the routes and a first mailbox" do
    igniter = install()

    assert_creates(igniter, "lib/test/mailboxes.ex")
    assert_creates(igniter, "lib/test/mailboxes/inbox.ex")
    # With or without parentheses: the test app has no Letterbox in its deps
    # to read the formatter of.
    assert file(igniter, "lib/test/mailboxes.ex") =~ ~r/route[ (]:all, to: Test.Mailboxes.Inbox/
    assert file(igniter, "lib/test/mailboxes/inbox.ex") =~ "use Letterbox.Mailbox"
  end

  test "leaves the app's own routes alone" do
    install(%{"lib/test/mailboxes.ex" => "defmodule Test.Mailboxes do\nend\n"})
    |> refute_creates("lib/test/mailboxes.ex")
  end

  test "starts the sweeper after the repo" do
    application = install() |> file("lib/test/application.ex")
    assert application =~ ~r/Test.Repo,.*\{Letterbox.Sweeper, \[?incinerate_after: 30\]?\}/s
  end

  test "imports Letterbox's formatter, so routes have no parentheses" do
    formatter =
      install().rewrite |> Rewrite.source!(".formatter.exs") |> Rewrite.Source.get(:content)

    assert formatter =~ "import_deps: [:letterbox, :phoenix]"
  end

  test "writes the migration" do
    igniter = install()

    assert Enum.any?(
             Rewrite.paths(igniter.rewrite),
             &(&1 =~ ~r{priv/repo/migrations/.*letterbox})
           )
  end

  test "changes nothing the second time" do
    install()
    |> apply_igniter!()
    |> Igniter.compose_task(Mix.Tasks.Letterbox.Install, [])
    |> assert_unchanged()
  end
end
