defmodule Letterbox.Migrations do
  @moduledoc """
  The table of Letterbox, in a migration of the app.

      $ mix letterbox.gen.migration

  writes a migration that pins the latest version:

      defmodule MyApp.Repo.Migrations.AddLetterbox do
        use Ecto.Migration

        def up, do: Letterbox.Migrations.up(version: 1)
        def down, do: Letterbox.Migrations.down(to: 0)
      end

  The versions are `PhoenixMountable.Migrations`: tracked in the app's
  database (per prefix), and run on PostgreSQL and on SQLite. A later
  version of Letterbox that changes the table has a new version, and
  `mix letterbox.gen.migration` writes the migration that upgrades.

  Version 1 makes `letterbox_inbound`: a message a row (`Letterbox.Inbound`),
  one for each provider's id (a webhook delivered twice is one message).

  `up/1` takes `:version` and `:prefix` (the schema of the table, in
  PostgreSQL); `down/1` takes `:to` and `:prefix`.
  """

  use PhoenixMountable.Migrations,
    otp_app: :letterbox,
    versions: [Letterbox.Migrations.V1],
    compatible_with: 1,
    gen_task: "letterbox.gen.migration"
end
