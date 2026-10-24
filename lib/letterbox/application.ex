defmodule Letterbox.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # The jobs of Letterbox.Runner.Local.
      {Task.Supervisor, name: Letterbox.TaskSupervisor}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Letterbox.Supervisor)
  end
end
