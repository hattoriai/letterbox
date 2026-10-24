defmodule Letterbox.Test do
  @moduledoc """
  An app's tests of its mailboxes and routes.

      import Letterbox.Test

      test "photographs sent to a site are in its library", %{site: site} do
        inbound =
          deliver(
            from: "ana@example.com",
            to: "site+\#{site.inbound_token}@in.example.com",
            subject: "From the beach",
            attachments: [%{name: "praia.jpg", content_type: "image/jpeg", data: File.read!("test/fixtures/praia.jpg")}]
          )

        assert inbound.status == "delivered"
        assert [%{name: "praia.jpg"}] = Media.list(site)
      end

  `deliver/2` goes the whole way, as a webhook's message would: kept (in
  the app's store, `Storehouse.Memory` in tests), a row in the app's
  database (Ecto's sandbox), and given to its mailbox in the test's own
  process, at once. `message/2` makes a `Letterbox.Message` only, to call a
  mailbox's `process/1` with it; `mailbox_for/2` says which mailbox takes
  one.
  """

  alias Letterbox.{Email, Inbound, Message, Routing}

  @doc """
  An email made from `fields` (`Letterbox.Email.build/1`, or a raw email),
  received and given to its mailbox at once. Gives its row, with the
  status its mailbox left.

  Options: `:recipients` (the envelope's; by default the email's `To`,
  `Cc` and `Delivered-To`), `:ingress` (`"test"`), `:external_id`.
  """
  @spec deliver(keyword() | binary(), keyword()) :: Inbound.t()
  def deliver(fields_or_raw, opts \\ []) do
    raw = raw(fields_or_raw)

    {:ok, inbound} =
      Letterbox.ingest(
        raw,
        [runner: :inline, ingress: Keyword.get(opts, :ingress, "test")] ++
          Keyword.take(opts, [:recipients, :external_id, :meta])
      )

    Letterbox.get(inbound.id)
  end

  @doc """
  The `Letterbox.Message` a mailbox would get for an email made from
  `fields` (or a raw email). Options: `:recipients`, and `:recipient`, the
  address its route matched (`message.recipient`; by default the first
  recipient).
  """
  @spec message(keyword() | binary(), keyword()) :: Message.t()
  def message(fields_or_raw, opts \\ []) do
    message =
      fields_or_raw |> raw() |> Email.parse(Keyword.take(opts, [:recipients, :trusted_servers]))

    recipient = opts[:recipient] && Letterbox.Address.parse(opts[:recipient])
    %{message | recipient: recipient || List.first(message.recipients)}
  end

  @doc """
  The mailbox the app's routes give a message made from `fields`: `{:ok,
  mailbox}`, or `:none`.
  """
  @spec mailbox_for(keyword() | binary(), keyword()) :: {:ok, module()} | :none
  def mailbox_for(fields_or_raw, opts \\ []) do
    routing = Keyword.get_lazy(opts, :routing, &Letterbox.Config.routing/0)

    case Routing.match(routing, message(fields_or_raw, opts)) do
      {:ok, mailbox, _recipient} -> {:ok, mailbox}
      :none -> :none
    end
  end

  defp raw(raw) when is_binary(raw), do: raw
  defp raw(fields) when is_list(fields), do: Email.build(fields)
end
