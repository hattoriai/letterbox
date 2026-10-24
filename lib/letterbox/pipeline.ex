defmodule Letterbox.Pipeline do
  @moduledoc false
  # What happens to a message: kept (ingest/2), or told of and fetched
  # (expect/4, fetch/1); then given to its mailbox (process/1). Each step
  # reads and writes the message's row, so it can be run again: a step
  # that finds its work done does nothing.

  import Ecto.Query

  alias Letterbox.{Config, Email, Inbound, Routing, Runner}
  alias Letterbox.MIME.Header

  require Logger

  @doc false
  @spec ingest(binary(), keyword()) :: {:ok, Inbound.t()} | {:error, term()}
  def ingest(raw, opts) when is_binary(raw) do
    ingress = Keyword.get(opts, :ingress, "app")
    external_id = opts[:external_id]

    :telemetry.span([:letterbox, :ingest], %{ingress: ingress, bytes: byte_size(raw)}, fn ->
      result =
        case external_id && by_external_id(ingress, external_id) do
          %Inbound{status: "pending"} = inbound -> fill(inbound, raw, opts)
          %Inbound{} = inbound -> {:ok, inbound}
          nil -> insert(raw, ingress, external_id, opts)
        end

      {result, %{ingress: ingress, result: result_meta(result)}}
    end)
  end

  defp result_meta({:ok, %Inbound{status: status}}), do: status
  defp result_meta({:error, _reason}), do: :error

  defp insert(raw, ingress, external_id, opts) do
    if byte_size(raw) > Config.max_bytes() do
      %Inbound{}
      |> Ecto.Changeset.change(
        ingress: ingress,
        external_id: external_id,
        status: "bounced",
        error: "too_large",
        raw_bytes: byte_size(raw),
        recipients: recipients(opts[:recipients]),
        meta: Map.new(opts[:meta] || %{})
      )
      |> repo().insert(prefix: Config.db_prefix())
    else
      id = Ecto.UUID.generate()

      with {:ok, stored} <- keep_raw(id, raw) do
        changeset =
          Ecto.Changeset.change(
            %Inbound{id: id},
            Map.merge(summary(raw), %{
              ingress: ingress,
              external_id: external_id,
              status: "received",
              recipients: recipients(opts[:recipients], raw),
              meta: Map.new(opts[:meta] || %{}),
              raw_key: stored.key,
              raw_bytes: stored.bytes,
              checksum: stored.checksum
            })
          )

        insert_kept(changeset, stored, opts)
      end
    end
  rescue
    # The same provider's id, inserted at the same time by another request.
    error in Ecto.ConstraintError ->
      case external_id && by_external_id(ingress, external_id) do
        %Inbound{} = inbound -> {:ok, inbound}
        nil -> reraise error, __STACKTRACE__
      end
  end

  # The row of a raw email kept; the raw email goes when the row cannot be.
  defp insert_kept(changeset, stored, opts) do
    case repo().insert(changeset, prefix: Config.db_prefix()) do
      {:ok, inbound} ->
        enqueue("process", inbound, opts)
        {:ok, inbound}

      {:error, %Ecto.Changeset{}} = error ->
        Storehouse.delete(stored.key, adapter: Config.adapter())
        error
    end
  end

  # A pending message's raw email, as its provider gave it.
  defp fill(%Inbound{} = inbound, raw, opts) do
    with {:ok, stored} <- keep_raw(inbound.id, raw) do
      recipients = recipients(opts[:recipients])

      inbound
      |> Ecto.Changeset.change(
        Map.merge(summary(raw), %{
          status: "received",
          attempts: 0,
          error: nil,
          raw_key: stored.key,
          raw_bytes: stored.bytes,
          checksum: stored.checksum,
          recipients: if(recipients == [], do: inbound.recipients, else: recipients)
        })
      )
      |> repo().update()
      |> tap(fn
        {:ok, inbound} -> enqueue("process", inbound, opts)
        _error -> :ok
      end)
    end
  end

  @doc false
  # A message its provider told of, to fetch (Letterbox.Ingress.fetch/2).
  @spec expect(String.t(), String.t(), [String.t()], map(), keyword()) ::
          {:ok, Inbound.t()} | {:error, term()}
  def expect(ingress, external_id, recipients, meta, opts \\ []) do
    case by_external_id(ingress, external_id) do
      %Inbound{} = inbound ->
        {:ok, inbound}

      nil ->
        %Inbound{}
        |> Ecto.Changeset.change(
          ingress: ingress,
          external_id: external_id,
          status: "pending",
          recipients: recipients(recipients),
          meta: Map.new(meta)
        )
        |> repo().insert(
          prefix: Config.db_prefix(),
          on_conflict: :nothing,
          conflict_target:
            {:unsafe_fragment, "(ingress, external_id) WHERE external_id IS NOT NULL"}
        )
        |> case do
          {:ok, %Inbound{id: nil}} ->
            {:ok, by_external_id(ingress, external_id)}

          {:ok, inbound} ->
            enqueue("fetch", inbound, opts)
            {:ok, inbound}

          error ->
            error
        end
    end
  end

  @doc false
  @spec fetch(String.t()) :: :ok | {:error, term()}
  def fetch(id) do
    case get(id) do
      %Inbound{status: "pending"} = inbound -> fetch_raw(inbound)
      _done_or_gone -> :ok
    end
  end

  defp fetch_raw(inbound) do
    with {module, opts} <- Config.ingress(inbound.ingress) || {:error, :unknown_ingress},
         {:ok, raw, extra} <- module.fetch(inbound.external_id, opts),
         {:ok, _inbound} <-
           ingest(raw,
             ingress: inbound.ingress,
             external_id: inbound.external_id,
             recipients: extra[:recipients] || []
           ) do
      :ok
    else
      {:error, reason} -> failed_attempt(inbound, reason)
    end
  end

  @doc false
  # The message given to its mailbox. `{:error, reason}` asks the runner to
  # try again; on the last attempt the message is failed, and the runner
  # stops.
  @spec process(String.t()) :: :ok | {:error, term()}
  def process(id) do
    case get(id) do
      %Inbound{status: status} = inbound when status in ["received", "processing"] ->
        inbound |> start() |> deliver()

      _done_or_gone ->
        :ok
    end
  end

  defp start(inbound) do
    {:ok, inbound} =
      inbound
      |> Ecto.Changeset.change(status: "processing", attempts: inbound.attempts + 1)
      |> repo().update()

    inbound
  end

  defp deliver(inbound) do
    case Storehouse.read(inbound.raw_key, adapter: Config.adapter()) do
      {:ok, raw} -> route(inbound, raw)
      {:error, reason} -> failed_attempt(inbound, {:raw, reason})
    end
  end

  defp route(inbound, raw) do
    message =
      raw
      |> Email.parse(recipients: inbound.recipients, trusted_servers: Config.trusted_servers())
      |> Map.put(:id, inbound.id)

    case Routing.match(Config.routing(), message) do
      :none ->
        finish(inbound, "unrouted", nil, nil)

      {:ok, mailbox, recipient} ->
        outcome = call(mailbox, %{message | recipient: recipient}, inbound)
        outcome(inbound, mailbox, outcome)
    end
  end

  defp call(mailbox, message, inbound) do
    meta = %{
      id: inbound.id,
      mailbox: mailbox,
      ingress: inbound.ingress,
      attempt: inbound.attempts
    }

    :telemetry.span([:letterbox, :process], meta, fn ->
      outcome =
        try do
          mailbox.process(message)
        rescue
          exception -> {:exception, Exception.format(:error, exception, __STACKTRACE__)}
        catch
          kind, reason -> {:exception, Exception.format(kind, reason, __STACKTRACE__)}
        end

      {outcome, Map.put(meta, :result, outcome_name(outcome))}
    end)
  end

  defp outcome_name({:bounce, _reason}), do: :bounced
  defp outcome_name({:error, _reason}), do: :error
  defp outcome_name({:exception, _formatted}), do: :exception
  defp outcome_name(_ok), do: :delivered

  defp outcome(inbound, mailbox, {:bounce, reason}),
    do: finish(inbound, "bounced", mailbox, reason(reason))

  defp outcome(inbound, mailbox, {:error, reason}),
    do: failed_attempt(inbound, reason, name(mailbox))

  defp outcome(inbound, mailbox, {:exception, formatted}) do
    Logger.error("Letterbox: #{inspect(mailbox)} raised on #{inbound.id}:\n" <> formatted)
    failed_attempt(inbound, formatted, name(mailbox))
  end

  defp outcome(inbound, mailbox, _ok), do: finish(inbound, "delivered", mailbox, nil)

  defp finish(inbound, status, mailbox, error) do
    inbound
    |> Ecto.Changeset.change(
      status: status,
      mailbox: mailbox && name(mailbox),
      error: error,
      processed_at: DateTime.utc_now()
    )
    |> repo().update!()

    :ok
  end

  # One attempt more: tried again, unless it was the last.
  defp failed_attempt(inbound, reason, mailbox \\ nil) do
    attempts = if inbound.status == "pending", do: inbound.attempts + 1, else: inbound.attempts
    last? = attempts >= Config.max_attempts()

    inbound
    |> Ecto.Changeset.change(
      attempts: attempts,
      mailbox: mailbox || inbound.mailbox,
      error: reason(reason),
      status:
        if(last?,
          do: "failed",
          else: if(inbound.status == "pending", do: "pending", else: "received")
        ),
      processed_at: if(last?, do: DateTime.utc_now())
    )
    |> repo().update!()

    if last?, do: :ok, else: {:error, reason}
  end

  defp name(module) when is_atom(module), do: module |> Module.split() |> Enum.join(".")

  defp reason(reason) when is_binary(reason), do: reason
  defp reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason(reason), do: inspect(reason)

  @doc false
  # Gives a message to the runner for the step its state needs.
  @spec enqueue(String.t(), Inbound.t(), keyword()) :: :ok | {:error, term()}
  def enqueue(work, %Inbound{id: id}, opts \\ []) do
    Runner.enqueue(%{"work" => work, "id" => id}, Keyword.take(opts, [:runner]))
  end

  # The raw email in the store, under a key of its own.
  defp keep_raw(id, raw) do
    now = DateTime.utc_now()
    key = Path.join([Config.prefix(), Calendar.strftime(now, "%Y/%m"), id <> ".eml"])
    path = Path.join(System.tmp_dir!(), "letterbox-" <> id <> ".eml")
    checksum = Base.encode64(:crypto.hash(:sha256, raw))

    try do
      :ok = File.write!(path, raw)

      case Config.adapter().put(key, path, %{
             content_type: "message/rfc822",
             bytes: byte_size(raw),
             checksum: checksum
           }) do
        {:ok, _url} -> {:ok, %{key: key, bytes: byte_size(raw), checksum: checksum}}
        {:error, reason} -> {:error, {:store, reason}}
      end
    after
      File.rm(path)
    end
  end

  # What the list of messages shows, from the headers alone.
  defp summary(raw) do
    headers = raw |> head() |> Header.parse()
    from = Letterbox.Address.parse(Header.get(headers, "from"))

    %{
      from: from && String.slice(from.address, 0, 320),
      subject: headers |> Header.get("subject") |> Header.decode() |> truncate(2_000),
      message_id:
        headers
        |> Header.get("message-id")
        |> case do
          nil ->
            nil

          id ->
            id
            |> String.trim()
            |> String.trim_leading("<")
            |> String.trim_trailing(">")
            |> String.slice(0, 998)
        end
    }
  end

  defp truncate(nil, _max), do: nil
  defp truncate(text, max), do: String.slice(text, 0, max)

  defp recipients(nil), do: []
  defp recipients(list), do: Enum.map(list, &to_string/1)

  # The envelope's recipients, else those the headers name (To, Cc,
  # Delivered-To, X-Original-To), as the message's own `:recipients` are.
  defp recipients(envelope, raw) do
    case recipients(envelope) do
      [] -> raw |> head() |> Header.parse() |> header_recipients()
      list -> list
    end
  end

  defp header_recipients(headers) do
    ["to", "cc", "delivered-to", "x-original-to"]
    |> Enum.flat_map(&Header.get_all(headers, &1))
    |> Enum.flat_map(&Letterbox.Address.parse_list/1)
    |> Enum.map(& &1.address)
    |> Enum.uniq_by(&String.downcase/1)
  end

  defp head(raw) do
    case :binary.match(raw, ["\r\n\r\n", "\n\n"]) do
      {at, _length} -> binary_part(raw, 0, at)
      :nomatch -> raw
    end
  end

  defp by_external_id(ingress, external_id) do
    repo().one(
      from(inbound in Inbound,
        where: inbound.ingress == ^ingress and inbound.external_id == ^external_id
      ),
      prefix: Config.db_prefix()
    )
  end

  @doc false
  def get(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> repo().get(Inbound, id, prefix: Config.db_prefix())
      :error -> nil
    end
  end

  defp repo, do: Config.repo()
end
