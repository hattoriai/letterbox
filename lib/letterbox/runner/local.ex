defmodule Letterbox.Runner.Local do
  @moduledoc """
  A runner (`Letterbox.Runner`) in a process of Letterbox's: each job a
  task of `Letterbox.TaskSupervisor`, tried again with a backoff (one
  second, then doubling, at most a minute), up to `:max_attempts` times.

  A job it has when the app stops is not run, but its message keeps its
  state in its row: `Letterbox.resume/0` gives the messages that were
  waiting to the runner again (`Letterbox.Sweeper` does it on start).
  """

  @behaviour Letterbox.Runner

  require Logger

  @impl Letterbox.Runner
  def enqueue(job, _opts) do
    {:ok, _pid} = Task.Supervisor.start_child(Letterbox.TaskSupervisor, fn -> attempt(job, 1) end)
    :ok
  end

  defp attempt(job, attempt) do
    case Letterbox.Runner.run(job) do
      :ok ->
        :ok

      {:error, reason} ->
        if attempt < Letterbox.Config.max_attempts() do
          Process.sleep(min(1_000 * Integer.pow(2, attempt - 1), 60_000))
          attempt(job, attempt + 1)
        else
          Logger.warning("Letterbox gave up on #{inspect(job)}: #{inspect(reason)}")
        end
    end
  end
end
