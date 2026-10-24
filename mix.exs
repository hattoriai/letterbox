defmodule Letterbox.MixProject do
  use Mix.Project

  @version "0.1.0-dev"
  @source_url "https://github.com/hattoriai/letterbox"

  def project do
    [
      app: :letterbox,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        plt_core_path: "priv/plts",
        plt_file: {:no_warn, "priv/plts/project.plt"},
        ignore_warnings: ".dialyzer_ignore.exs"
      ],
      package: package(),
      docs: docs(),
      description: description(),
      name: "Letterbox",
      source_url: @source_url,
      homepage_url: @source_url
    ]
  end

  def application do
    [mod: {Letterbox.Application, []}, extra_applications: [:logger, :crypto]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      # The emails, one row each, in the app's database, on PostgreSQL or
      # SQLite.
      {:ecto, "~> 3.13"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, "~> 0.19", only: :test},
      # The raw emails and their attachments, kept in the app's store.
      {:storehouse, "~> 0.2"},
      # The table's versions (Letterbox.Migrations), the installer, and a
      # webhook's body as it was sent (PhoenixMountable.RawBody).
      {:phoenix_mountable, "~> 0.2.4"},
      # mix letterbox.install. Without it, the task says what to do by hand.
      {:igniter, "~> 0.6", optional: true},
      {:phoenix, "~> 1.7.14 or ~> 1.8"},
      # The development page (Letterbox.Dev.Router).
      {:phoenix_live_view, "~> 1.1"},
      {:lazy_html, "~> 0.1", only: :test},
      {:plug, "~> 1.15"},
      # The webhooks' signatures (Plug.Crypto.secure_compare/2); 2.2.1 and
      # later, for EEF-CVE-2026-105963.
      {:plug_crypto, "~> 2.2 and >= 2.2.1"},
      # A provider's API, to fetch an email its webhook names.
      {:req, "~> 0.5"},
      # The work on each email in Oban jobs, with retries that survive a
      # deploy, when the app runs Oban.
      {:oban, "~> 2.19", optional: true},
      {:telemetry, "~> 1.0"},
      {:bandit, "~> 1.5", only: :test},
      {:stream_data, "~> 1.1", only: :test}
    ]
  end

  defp description do
    "Inbound email for Phoenix: emails to your app, parsed, kept and routed to your code."
  end

  defp package do
    [
      name: "letterbox",
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv/static mix.exs .formatter.exs README.md CHANGELOG.md LICENSE NOTICE)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      assets: %{"media" => "media"},
      extras: ["README.md", "CHANGELOG.md"]
    ]
  end
end
