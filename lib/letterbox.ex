defmodule Letterbox do
  @moduledoc """
  Inbound email for Phoenix: emails to your app, kept, read and given to
  your code.

      defmodule MyApp.Mailboxes do
        use Letterbox.Routing

        route "support@", to: MyApp.SupportMailbox
      end

      defmodule MyApp.SupportMailbox do
        use Letterbox.Mailbox

        @impl true
        def process(message), do: MyApp.Tickets.open(message.verified_from || message.from, message.text)
      end

  A message reaches the app through an ingress (`Letterbox.Ingress`): a
  provider's webhook (`Letterbox.Ingress.Resend`), a relay of raw emails
  (`Letterbox.Ingress.Relay`), or the app's own code with `ingest/2`.
  Letterbox keeps the raw email in the app's store, a row for it in the
  app's database (`Letterbox.Inbound`), and, out of the request
  (`Letterbox.Runner`), reads it (`Letterbox.Email`) and gives it to the
  mailbox its routes name (`Letterbox.Routing`).

  ## Telemetry

    * `[:letterbox, :ingest, :start | :stop | :exception]` - a message
      kept, with `:ingress` and `:bytes`; the `:stop` has its `:result`,
      the row's status (or `:error`).
    * `[:letterbox, :process, :start | :stop | :exception]` - a mailbox
      given a message, with `:id`, `:mailbox`, `:ingress` and `:attempt`;
      the `:stop` has its `:result`: `:delivered`, `:bounced`, `:error`
      or `:exception`.
  """

  import Ecto.Query

  alias Letterbox.{Config, Email, Inbound, Message, Pipeline}

  @doc """
  Takes a raw email from the app's own code: kept, then given to its
  mailbox out of the caller. Gives the message's row.

  Options:

    * `:ingress` - a name for where it came from (`"app"`).
    * `:external_id` - its id where it came from: the same id twice is one
      message.
    * `:recipients` - the addresses the mail server took it for (its
      envelope), when they are known.
    * `:meta` - a map kept with it.
    * `:runner` - for this message only (`Letterbox.Runner`).
  """
  @spec ingest(binary(), keyword()) :: {:ok, Inbound.t()} | {:error, term()}
  def ingest(raw, opts \\ []) when is_binary(raw), do: Pipeline.ingest(raw, opts)

  @doc "A message's row, or nil."
  @spec get(String.t()) :: Inbound.t() | nil
  def get(id), do: Pipeline.get(id)

  @doc """
  The messages, the newest first. Options: `:status` (one or a list),
  `:mailbox` (a module), `:limit` (50) and `:offset`.
  """
  @spec list(keyword()) :: [Inbound.t()]
  def list(opts \\ []) do
    Inbound
    |> filter(:status, opts[:status])
    |> filter(:mailbox, opts[:mailbox] && opts[:mailbox] |> Module.split() |> Enum.join("."))
    |> order_by([inbound], desc: inbound.inserted_at)
    |> limit(^Keyword.get(opts, :limit, 50))
    |> offset(^Keyword.get(opts, :offset, 0))
    |> Config.repo().all(prefix: Config.db_prefix())
  end

  defp filter(query, _field, nil), do: query

  defp filter(query, field, values) when is_list(values),
    do: where(query, [i], field(i, ^field) in ^values)

  defp filter(query, field, value), do: where(query, [i], field(i, ^field) == ^value)

  @doc "A message's raw email, as it came."
  @spec raw(Inbound.t() | String.t()) :: {:ok, binary()} | {:error, term()}
  def raw(%Inbound{raw_key: nil}), do: {:error, :not_kept}
  def raw(%Inbound{raw_key: key}), do: Storehouse.read(key, adapter: Config.adapter())

  def raw(id) when is_binary(id) do
    case get(id) do
      nil -> {:error, :not_found}
      inbound -> raw(inbound)
    end
  end

  @doc "A message as its mailbox gets it (`Letterbox.Message`), read again from its raw email."
  @spec message(Inbound.t() | String.t()) :: {:ok, Message.t()} | {:error, term()}
  def message(inbound_or_id) do
    inbound = if is_binary(inbound_or_id), do: get(inbound_or_id), else: inbound_or_id

    with %Inbound{} <- inbound || {:error, :not_found},
         {:ok, raw} <- raw(inbound) do
      message =
        raw
        |> Email.parse(recipients: inbound.recipients, trusted_servers: Config.trusted_servers())
        |> Map.put(:id, inbound.id)

      {:ok, message}
    end
  end

  @doc """
  Gives a message to its mailbox again, from its first attempt: one that
  failed, bounced or was not routed, once the cause is fixed.
  """
  @spec retry(Inbound.t() | String.t(), keyword()) :: {:ok, Inbound.t()} | {:error, term()}
  def retry(inbound_or_id, opts \\ [])

  def retry(id, opts) when is_binary(id) do
    case get(id) do
      nil -> {:error, :not_found}
      inbound -> retry(inbound, opts)
    end
  end

  def retry(%Inbound{raw_key: nil}, _opts), do: {:error, :not_kept}

  def retry(%Inbound{} = inbound, opts) do
    with {:ok, inbound} <-
           inbound
           |> Ecto.Changeset.change(
             status: "received",
             attempts: 0,
             error: nil,
             processed_at: nil
           )
           |> Config.repo().update() do
      Pipeline.enqueue("process", inbound, opts)
      {:ok, Config.repo().reload(inbound)}
    end
  end

  @doc """
  Gives the runner the messages that were waiting: those to fetch from
  their provider, and those for their mailbox. After a restart, with the
  local runner, they are not lost (`Letterbox.Sweeper` does it on start).
  Gives how many.
  """
  @spec resume(keyword()) :: non_neg_integer()
  def resume(opts \\ []) do
    waiting =
      Inbound
      |> where([i], i.status in ["pending", "received", "processing"])
      |> select([i], {i.id, i.status})
      |> Config.repo().all(prefix: Config.db_prefix())

    for {id, status} <- waiting do
      work = if status == "pending", do: "fetch", else: "process"
      Pipeline.enqueue(work, %Inbound{id: id}, opts)
    end

    length(waiting)
  end

  @doc """
  Deletes a message: its row and its raw email.
  """
  @spec delete(Inbound.t() | String.t()) :: :ok | {:error, term()}
  def delete(id) when is_binary(id) do
    case get(id) do
      nil -> :ok
      inbound -> delete(inbound)
    end
  end

  def delete(%Inbound{} = inbound) do
    with :ok <- delete_raw(inbound),
         {:ok, _deleted} <- Config.repo().delete(inbound, allow_stale: true) do
      :ok
    end
  end

  defp delete_raw(%Inbound{raw_key: nil}), do: :ok
  defp delete_raw(%Inbound{raw_key: key}), do: Storehouse.delete(key, adapter: Config.adapter())

  @doc """
  Deletes the messages done with for longer than `days` (their row and
  their raw email): delivered, bounced, unrouted or failed. Gives how many.
  """
  @spec incinerate(pos_integer()) :: non_neg_integer()
  def incinerate(days) when is_integer(days) and days > 0 do
    before = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

    Inbound
    |> where([i], i.status in ["delivered", "bounced", "unrouted", "failed"])
    |> where([i], coalesce(i.processed_at, i.updated_at) < ^before)
    |> Config.repo().all(prefix: Config.db_prefix())
    |> Enum.count(&(delete(&1) == :ok))
  end
end
