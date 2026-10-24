defmodule Letterbox.Routing do
  @moduledoc """
  Which mailbox takes which message: the app's routes, in one module.

      defmodule MyApp.Mailboxes do
        use Letterbox.Routing

        route "support@example.com", to: MyApp.SupportMailbox
        route "billing@", to: MyApp.BillingMailbox
        route ~r/\\Areply\\+/, to: MyApp.RepliesMailbox
        route "@in.example.com", to: MyApp.SitesMailbox
        route &MyApp.Tickets.forwarded?/1, to: MyApp.ForwardsMailbox
        route :all, to: MyApp.UnknownMailbox
      end

      config :letterbox, routing: MyApp.Mailboxes

  A route matches a message's recipients (`Letterbox.Message`'s
  `:recipients`), each in its order, and the first route that matches one
  takes the message; the address it matched is the message's `:recipient`.
  A route is:

    * an address, `"support@example.com"`: that address in any case, with
      or without a sub-address (`support+urgent@example.com`);
    * a local part, `"billing@"`: at any domain, with or without a
      sub-address;
    * a domain, `"@in.example.com"`: any address there;
    * a regex, matched with the address in lowercase;
    * a function of the message, true for the messages it takes (its
      `:recipient` is then the first of its recipients);
    * `:all`, every message.

  A message no route takes is `"unrouted"`.
  """

  alias Letterbox.{Address, Message}

  @doc false
  defmacro __using__(_opts) do
    quote do
      import Letterbox.Routing, only: [route: 2]
      Module.register_attribute(__MODULE__, :letterbox_routes, accumulate: true)
      @before_compile Letterbox.Routing
    end
  end

  @doc "A route: what it matches, and the mailbox (`to:`) that takes the messages."
  defmacro route(pattern, opts) do
    mailbox = Keyword.fetch!(opts, :to)

    quote do
      @letterbox_routes {unquote(Macro.escape(pattern)), unquote(mailbox)}
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:letterbox_routes) |> Enum.reverse()

    quote do
      @doc false
      def __routes__,
        do: unquote(Enum.map(routes, fn {pattern, mailbox} -> {:{}, [], [pattern, mailbox]} end))
    end
  end

  @doc """
  The mailbox of a message and the recipient its route matched:
  `{:ok, mailbox, recipient}`, or `:none`.
  """
  @spec match(module(), Message.t()) :: {:ok, module(), Address.t() | nil} | :none
  def match(routing, %Message{} = message) do
    Enum.find_value(routing.__routes__(), :none, fn {pattern, mailbox} ->
      case matched(pattern, message) do
        :nomatch -> nil
        {:match, recipient} -> {:ok, mailbox, recipient}
      end
    end)
  end

  defp matched(:all, message), do: {:match, List.first(message.recipients)}

  defp matched(fun, message) when is_function(fun, 1) do
    if fun.(message), do: {:match, List.first(message.recipients)}, else: :nomatch
  end

  defp matched(pattern, message) do
    case Enum.find(message.recipients, &recipient?(pattern, &1)) do
      nil -> :nomatch
      recipient -> {:match, recipient}
    end
  end

  defp recipient?(%Regex{} = regex, address),
    do: Regex.match?(regex, String.downcase(address.address))

  defp recipient?("@" <> domain, address), do: Address.domain(address) == String.downcase(domain)

  defp recipient?(pattern, address) when is_binary(pattern) do
    case String.split(pattern, "@") do
      [local, ""] ->
        address |> Address.base() |> String.starts_with?(String.downcase(local) <> "@")

      [_local, _domain] ->
        Address.matches?(address, pattern)

      _other ->
        false
    end
  end
end
