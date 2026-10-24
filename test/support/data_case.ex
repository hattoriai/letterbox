defmodule LetterboxTest.DataCase do
  @moduledoc "Tests with the database (Ecto's sandbox) and the in-memory store."
  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      import Letterbox.Test
      alias LetterboxTest.Repo
    end
  end

  setup tags do
    pid = Sandbox.start_owner!(LetterboxTest.Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
    Storehouse.Memory.checkout()
    :ok
  end
end
