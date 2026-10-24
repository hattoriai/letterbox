defmodule Letterbox.Config do
  @moduledoc """
  Letterbox's configuration, in the app's:

      config :letterbox,
        repo: MyApp.Repo,
        routing: MyApp.Mailboxes,
        ingresses: [
          resend: [secret: "whsec_…", api_key: "re_…"],
          relay: [token: "a long random token"]
        ]

    * `:repo` - the app's `Ecto.Repo`, where `letterbox_inbound` is
      (`Letterbox.Migrations`). Required.
    * `:routing` - the app's routes (`Letterbox.Routing`): which mailbox
      takes which message. Required.
    * `:ingresses` - how messages reach the app, each by its name in the
      webhook's path (`/…/webhooks/resend`): `Letterbox.Ingress.Resend`,
      `Letterbox.Ingress.Relay`, or `{module, opts}` of the app's own
      (`Letterbox.Ingress`).
    * `:trusted_servers` - the `authserv-id`s whose `Authentication-Results`
      verify senders (`Letterbox.Email.parse/2`). None by default.
    * `:adapter` - the Storehouse store of the raw emails. The default is
      Storehouse's own (`Storehouse.adapter/0`).
    * `:prefix` - the start of the raw emails' keys in the store
      (`"letterbox"`): `letterbox/2026/10/<id>.eml`.
    * `:max_bytes` - the largest email kept, in bytes (50 MB). A larger one
      is bounced, not kept.
    * `:max_attempts` - how many times a mailbox is tried before its
      message is `"failed"` (5).
    * `:runner` - what runs the work out of the request (`Letterbox.Runner`):
      Oban when the app runs it, else a process of Letterbox's.
    * `:db_prefix` - the database schema of the table, in PostgreSQL.
  """

  @doc false
  def repo do
    Application.get_env(:letterbox, :repo) ||
      raise ArgumentError, "Letterbox needs a repo: config :letterbox, repo: MyApp.Repo"
  end

  @doc false
  def routing do
    Application.get_env(:letterbox, :routing) ||
      raise ArgumentError,
            "Letterbox needs its routes: config :letterbox, routing: MyApp.Mailboxes"
  end

  @doc false
  def adapter, do: Application.get_env(:letterbox, :adapter) || Storehouse.adapter()

  @doc false
  def prefix, do: Application.get_env(:letterbox, :prefix, "letterbox")

  @doc false
  def max_bytes, do: Application.get_env(:letterbox, :max_bytes, 50_000_000)

  @doc false
  def max_attempts, do: Application.get_env(:letterbox, :max_attempts, 5)

  @doc false
  def trusted_servers, do: Application.get_env(:letterbox, :trusted_servers, [])

  @doc false
  def db_prefix, do: Application.get_env(:letterbox, :db_prefix)

  @builtin %{"resend" => Letterbox.Ingress.Resend, "relay" => Letterbox.Ingress.Relay}

  @doc false
  # The ingress of a name, as `{module, opts}`, or nil. The name comes from
  # a request's path: it is compared as a string, never made an atom.
  @spec ingress(String.t()) :: {module(), keyword()} | nil
  def ingress(name) when is_binary(name) do
    Application.get_env(:letterbox, :ingresses, [])
    |> Enum.find_value(fn {key, value} ->
      if Atom.to_string(key) == name, do: resolve(name, value)
    end)
  end

  defp resolve(_name, {module, opts}) when is_atom(module) and is_list(opts), do: {module, opts}
  defp resolve(_name, module) when is_atom(module) and module not in [nil, true], do: {module, []}

  defp resolve(name, opts) when is_list(opts) do
    case Map.fetch(@builtin, name) do
      {:ok, module} -> {module, opts}
      :error -> nil
    end
  end

  defp resolve(_name, _other), do: nil
end
