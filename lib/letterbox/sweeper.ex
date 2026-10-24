defmodule Letterbox.Sweeper do
  @moduledoc """
  A process of the app's that keeps Letterbox's table: on start, the
  messages that were waiting go to the runner again (`Letterbox.resume/1`);
  then, every hour, those done with for `:incinerate_after` days are
  deleted (`Letterbox.incinerate/1`).

      children = [
        MyApp.Repo,
        {Letterbox.Sweeper, incinerate_after: 30}
      ]

  After the repo, in the app's supervision tree. Options:
  `:incinerate_after` (days; nil keeps every message), `:every` (an hour,
  in milliseconds) and `:resume` (`true`).

  With Oban, an app can do the same in a cron job of its own and run no
  sweeper.
  """

  use GenServer

  require Logger

  @doc false
  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)

  @impl true
  def init(opts) do
    if Keyword.get(opts, :resume, true), do: send(self(), :resume)
    schedule(opts)
    {:ok, opts}
  end

  @impl true
  def handle_info(:resume, opts) do
    count = Letterbox.resume()
    if count > 0, do: Logger.info("Letterbox resumed #{count} waiting messages")
    {:noreply, opts}
  end

  def handle_info(:sweep, opts) do
    if days = opts[:incinerate_after], do: Letterbox.incinerate(days)
    schedule(opts)
    {:noreply, opts}
  end

  defp schedule(opts) do
    if opts[:incinerate_after],
      do: Process.send_after(self(), :sweep, Keyword.get(opts, :every, :timer.hours(1)))
  end
end
