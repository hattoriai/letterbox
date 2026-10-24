# The tests of the pipeline run against PostgreSQL at DATABASE_URL, as CI
# does:
#
#     DATABASE_URL=postgres://postgres:postgres@localhost/letterbox_test mix test
exclude = if System.get_env("DATABASE_URL"), do: [], else: [:db]

if url = System.get_env("DATABASE_URL") do
  Application.put_env(:letterbox, LetterboxTest.Repo,
    url: url,
    pool: Ecto.Adapters.SQL.Sandbox,
    pool_size: 10,
    log: false
  )

  _ = Ecto.Adapters.Postgres.storage_up(Ecto.Repo.Supervisor.parse_url(url))
  {:ok, _pid} = LetterboxTest.Repo.start_link()

  defmodule LetterboxTest.Migration do
    use Ecto.Migration
    def up, do: Letterbox.Migrations.up(version: 1)
    def down, do: Letterbox.Migrations.down(to: 0)
  end

  Ecto.Migrator.up(LetterboxTest.Repo, 1, LetterboxTest.Migration, log: false)
end

{:ok, _memory} = Storehouse.Memory.start_link()

ExUnit.start(exclude: exclude)
