defmodule Letterbox.Inbound do
  @moduledoc """
  A message that came in: one row each, in `letterbox_inbound`, with the
  raw email kept in the app's store (`:raw_key`).

  Its `:status` says where it is:

    * `"pending"` - its provider told of it (a webhook); Letterbox is
      fetching it.
    * `"received"` - kept, waiting for its mailbox.
    * `"processing"` - its mailbox has it.
    * `"delivered"` - its mailbox took it (`:ok`).
    * `"bounced"` - its mailbox refused it (`{:bounce, reason}`), or it
      was too large to keep: `:error` says why.
    * `"unrouted"` - no route took any of its recipients.
    * `"failed"` - its mailbox failed `:max_attempts` times, or its
      provider never gave it: `:error` has the last failure.

  A failed or bounced message can be processed again (`Letterbox.retry/1`).
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  @statuses ~w(pending received processing delivered bounced unrouted failed)

  schema "letterbox_inbound" do
    field :channel, :string, default: "email"
    field :ingress, :string
    field :external_id, :string
    field :status, :string, default: "received"
    field :mailbox, :string
    field :recipients, {:array, :string}, default: []
    field :from, :string
    field :subject, :string
    field :message_id, :string
    field :raw_key, :string
    field :raw_bytes, :integer
    field :checksum, :string
    field :attempts, :integer, default: 0
    field :error, :string
    field :meta, :map, default: %{}
    field :processed_at, :utc_datetime_usec
    timestamps()
  end

  @type t :: %__MODULE__{}

  @doc false
  def statuses, do: @statuses
end
