defmodule Mix.Tasks.Letterbox.Gen.Migration do
  @shortdoc "Generates the migration that installs or upgrades Letterbox's table"

  @moduledoc """
  Generates the migration of Letterbox's table in the app's repo: the one
  that installs it, or, after an upgrade of Letterbox, the one that brings
  it to its latest version.

      $ mix letterbox.gen.migration
      $ mix letterbox.gen.migration --repo MyApp.Repo

  It is `mix phoenix_mountable.gen.migration Letterbox.Migrations`: the
  version the app is at is read from its migrations, and the new migration
  pins the latest (see `Letterbox.Migrations`). Run it with `mix
  ecto.migrate`.

  The options are those of `mix phoenix_mountable.gen.migration`, such as
  `--repo` and `--migrations-path`.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args),
    do: Mix.Task.run("phoenix_mountable.gen.migration", ["Letterbox.Migrations" | args])
end
