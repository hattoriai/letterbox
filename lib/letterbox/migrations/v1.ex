defmodule Letterbox.Migrations.V1 do
  @moduledoc false
  # The messages that came in, one row each (Letterbox.Inbound).

  use PhoenixMountable.Migration, description: "Letterbox's table"

  def up(ctx) do
    create table(:letterbox_inbound, primary_key: false, prefix: ctx.prefix) do
      add :id, :binary_id, primary_key: true
      add :channel, :string, size: 16, null: false, default: "email"
      add :ingress, :string, size: 64, null: false
      add :external_id, :string, size: 255
      add :status, :string, size: 16, null: false
      add :mailbox, :string, size: 255
      add :recipients, {:array, :string}, null: false, default: []
      add :from, :string, size: 320
      add :subject, :text
      add :message_id, :string, size: 998
      add :raw_key, :string, size: 255
      add :raw_bytes, :bigint
      add :checksum, :string, size: 64
      add :attempts, :integer, null: false, default: 0
      add :error, :text
      add :meta, :map, null: false, default: %{}
      add :processed_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:letterbox_inbound, [:ingress, :external_id],
             where: "external_id IS NOT NULL",
             name: :letterbox_inbound_ingress_external_id_index,
             prefix: ctx.prefix
           )

    create index(:letterbox_inbound, [:status, :inserted_at], prefix: ctx.prefix)
    create index(:letterbox_inbound, [:inserted_at], prefix: ctx.prefix)
    create index(:letterbox_inbound, [:message_id], prefix: ctx.prefix)
  end

  def down(ctx) do
    drop_if_exists table(:letterbox_inbound, prefix: ctx.prefix)
  end
end
