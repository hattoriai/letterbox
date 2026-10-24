defmodule Letterbox.Mailbox do
  @moduledoc """
  The app's code that receives a message: one module for each kind
  (support, replies, photographs), named in the routes
  (`Letterbox.Routing`).

      defmodule MyApp.SitesMailbox do
        use Letterbox.Mailbox

        @impl true
        def process(message) do
          with %Site{} = site <- Sites.by_inbound_token(Letterbox.Address.tag(message.recipient)),
               %User{} = user <- Sites.member_by_email(site, message.verified_from) do
            Enum.each(message.attachments, &Media.add_from_email(site, user, &1))
          else
            nil -> {:bounce, :unknown_sender}
          end
        end
      end

  `process/1` runs out of the request, in a job (`Letterbox.Runner`), and
  gives:

    * `:ok` - done: the message is `"delivered"`;
    * `{:bounce, reason}` - refused, for good: the message is `"bounced"`,
      and not tried again;
    * `{:error, reason}`, or an exception - it is tried again, up to
      `:max_attempts` times, then `"failed"`.

  Anything else is `:ok`. A mailbox is tried again with the same message,
  so what it does should be safe to do twice (an attachment kept twice is
  one file, with Storehouse's `:existing`).
  """

  alias Letterbox.Message

  @callback process(Message.t()) :: :ok | {:bounce, term()} | {:error, term()} | term()

  @doc false
  defmacro __using__(_opts) do
    quote do
      @behaviour Letterbox.Mailbox
    end
  end
end
