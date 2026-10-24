defmodule Letterbox.Runner do
  @moduledoc """
  What runs Letterbox's work out of the request: fetching a message its
  provider told of, and giving each message to its mailbox. One runner does
  all of it, and another takes its place with no other change.

    * `Letterbox.Runner.Oban` - in Oban jobs, kept in the app's database:
      work that outlives a deploy, tried again with Oban's backoff. The
      default when the app runs Oban (an instance named `Oban`).
    * `Letterbox.Runner.Local` - in a process of Letterbox's, tried again
      with backoff. The default otherwise. Work it had when the app stopped
      is not lost: each message's state is in its row, and
      `Letterbox.resume/0` (or `Letterbox.Sweeper`) gives it to the runner
      again.
    * `:inline` - in the caller, at once: for tests (`Letterbox.Test`).
    * A module of the app's, of this behaviour.

  ## Choosing it

      config :letterbox, runner: Letterbox.Runner.Oban
      config :letterbox, Letterbox.Runner.Oban, queue: :mail, name: MyApp.Oban

  ## Writing one

  A runner keeps a job, a map that JSON holds (`%{"work" => "process",
  "id" => "…"}`), and runs it with `Letterbox.Runner.run/1` until it gives
  `:ok`, at most `Letterbox.Config`'s `:max_attempts` times.
  """

  # Oban is optional: it is asked only when it is there.
  @compile {:no_warn_undefined, Oban}

  @doc "Keeps the job and runs it out of the caller: `:ok` once it is kept."
  @callback enqueue(job :: map(), opts :: keyword()) :: :ok | {:error, term()}

  @typedoc "A runner: a module, `{module, opts}`, or `:oban`, `:local` or `:inline`."
  @type t :: module() | {module(), keyword()} | :oban | :local | :inline

  @doc false
  @spec enqueue(map(), keyword()) :: :ok | {:error, term()}
  def enqueue(job, opts \\ []) do
    case resolve(opts[:runner]) do
      :inline -> inline(job, 1)
      {runner, runner_opts} -> runner.enqueue(job, runner_opts)
    end
  end

  # Inline, the attempts happen at once, one after the other.
  defp inline(job, attempt) do
    case run(job) do
      :ok ->
        :ok

      {:error, _reason} = error ->
        if attempt < Letterbox.Config.max_attempts(), do: inline(job, attempt + 1), else: error
    end
  end

  @doc """
  Runs a job once: `:ok`, or `{:error, reason}` to be tried again. A job
  for a message that is gone is `:ok`.
  """
  @spec run(map()) :: :ok | {:error, term()}
  def run(%{"work" => "fetch", "id" => id}), do: Letterbox.Pipeline.fetch(id)
  def run(%{"work" => "process", "id" => id}), do: Letterbox.Pipeline.process(id)
  def run(_unknown), do: :ok

  @doc """
  The runner used: the one given, else `config :letterbox, :runner`, else
  Oban's when an instance named `Oban` runs, else `Letterbox.Runner.Local`.
  """
  @spec resolve(t() | nil) :: {module(), keyword()} | :inline
  def resolve(nil) do
    case Application.get_env(:letterbox, :runner) do
      nil -> default()
      runner -> resolve(runner)
    end
  end

  def resolve(:inline), do: :inline
  def resolve(:oban), do: {Letterbox.Runner.Oban, []}
  def resolve(:local), do: {Letterbox.Runner.Local, []}
  def resolve({runner, opts}) when is_atom(runner) and is_list(opts), do: {runner, opts}
  def resolve(runner) when is_atom(runner), do: {runner, []}

  defp default do
    if Code.ensure_loaded?(Oban) and is_pid(Oban.whereis(Oban)),
      do: {Letterbox.Runner.Oban, []},
      else: {Letterbox.Runner.Local, []}
  end
end
