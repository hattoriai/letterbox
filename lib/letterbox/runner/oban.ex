if Code.ensure_loaded?(Oban.Worker) do
  defmodule Letterbox.Runner.Oban.Worker do
    @moduledoc """
    The Oban worker of `Letterbox.Runner.Oban`: a job's map as its
    arguments, run with `Letterbox.Runner.run/1`, tried again by Oban when
    it fails.
    """

    use Oban.Worker,
      queue: :letterbox,
      max_attempts: 5,
      unique: [keys: [:work, :id], states: [:available, :scheduled, :retryable]]

    @impl Oban.Worker
    def perform(%Oban.Job{args: args}), do: Letterbox.Runner.run(args)
  end
end

defmodule Letterbox.Runner.Oban do
  @moduledoc """
  A runner (`Letterbox.Runner`) in Oban: each job an Oban job
  (`Letterbox.Runner.Oban.Worker`), kept in the app's database, so it
  outlives a deploy, and tried again with Oban's backoff, up to
  `Letterbox.Config`'s `:max_attempts`. A job waiting is not inserted twice.

  The default runner when the app runs an Oban instance named `Oban`.

      config :letterbox, Letterbox.Runner.Oban, queue: :mail, name: MyApp.Oban

      config :my_app, Oban, queues: [default: 10, mail: 5]

  With no `:queue`, the jobs go on `:letterbox`, which the app's Oban must
  run. Any other option of `Oban.Job.new/2` (`:priority`, `:tags`) is
  passed on.
  """

  @behaviour Letterbox.Runner

  alias Letterbox.Runner.Oban.Worker

  # Oban is optional: this is called only with Oban there.
  @compile {:no_warn_undefined, [Oban, Worker]}

  @impl Letterbox.Runner
  def enqueue(job, opts) do
    opts = Keyword.merge(Application.get_env(:letterbox, __MODULE__, []), opts)
    {name, opts} = Keyword.pop(opts, :name, Oban)

    changeset =
      Worker.new(
        job,
        Keyword.merge(
          [queue: :letterbox, max_attempts: Letterbox.Config.max_attempts()],
          opts
        )
      )

    case Oban.insert(name, changeset) do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
