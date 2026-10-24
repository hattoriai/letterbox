defmodule Letterbox.Plug do
  @moduledoc """
  The webhooks of the ingresses (`Letterbox.Ingress`), a route of the
  app's own router. `mix letterbox.install` writes one for every
  ingress, the ingress named by the path:

      scope "/inbound" do
        pipe_through :webhooks
        post "/webhooks/:ingress", Letterbox.Plug, []
      end

  The path, the scope and the pipeline are the app's to change: nothing
  in Letterbox depends on them. A route can also name its ingress, one
  route for each, at any path:

      post "/mail/resend", Letterbox.Plug, ingress: :resend
      post "/hooks/postfix", Letterbox.Plug, ingress: :relay

  The ingress is the route's `:ingress` option, else the `:ingress`
  parameter of its path. In an app without Phoenix's router, it is a Plug
  like any other (`forward "/inbound/resend", Letterbox.Plug, ingress:
  :resend`).

  It answers:

    * `204` - the request was the ingress's, and what it brought is kept
      (or, for an email to fetch, noted): the provider stops sending it.
      Again for a message already kept.
    * `401` - it was not the ingress's (`verify/3` refused it).
    * `404` - no ingress of that name.
    * `413` - the body is larger than `:max_bytes` (`Letterbox.Config`).
    * `422` - the ingress could not read it.
    * `500` - it could not be kept (the store, the database): the
      provider sends it again later.

  The route takes no session and no CSRF token: a provider has neither.
  Its pipeline must not have `:protect_from_forgery`.

  A signed webhook needs its body as it was sent: the plug declares it
  (`use PhoenixMountable.RawBody`), and the endpoint's `Plug.Parsers`
  keeps it with `body_reader: {PhoenixMountable.RawBody, :read_body,
  [MyAppWeb.Router]}`, which `mix letterbox.install` adds. A relay's raw
  email (`message/rfc822`) is passed by the parsers unread, and needs no
  copy.
  """

  @behaviour Plug

  use PhoenixMountable.RawBody

  import Plug.Conn

  alias Letterbox.{Config, Pipeline}
  alias PhoenixMountable.RawBody

  require Logger

  @impl Plug
  def init(opts) when is_list(opts) do
    case Keyword.get(opts, :ingress) do
      nil -> %{ingress: nil}
      name when is_atom(name) or is_binary(name) -> %{ingress: to_string(name)}
    end
  end

  @impl Plug
  def call(%{method: "POST"} = conn, opts) do
    case opts.ingress || conn.path_params["ingress"] do
      name when is_binary(name) -> webhook(conn, name)
      nil -> respond(conn, 404, "not_found")
    end
  end

  def call(conn, _opts), do: respond(conn, 405, "method_not_allowed")

  defp webhook(conn, name) do
    case Config.ingress(name) do
      nil -> respond(conn, 404, "not_found")
      {module, opts} -> webhook(conn, name, module, opts)
    end
  end

  defp webhook(conn, name, module, opts) do
    with {:body, {:ok, body, conn}} <- {:body, RawBody.fetch(conn, Config.max_bytes())},
         {:verify, :ok} <- {:verify, module.verify(conn, body, opts)},
         {:handle, {:ok, deliveries}} <- {:handle, module.handle(conn, body, opts)},
         :ok <- deliver_all(deliveries, name) do
      send_resp(conn, 204, "")
    else
      {:body, {:error, :too_large}} ->
        respond(conn, 413, "too_large")

      {:body, {:error, :no_raw_body}} ->
        Logger.error(
          "Letterbox cannot check a webhook: the endpoint read its body before the router. " <>
            "Give Plug.Parsers `body_reader: {PhoenixMountable.RawBody, :read_body, [MyAppWeb.Router]}`."
        )

        respond(conn, 500, "no_raw_body")

      {:body, {:error, _reason}} ->
        respond(conn, 400, "unreadable_body")

      {:verify, _refused} ->
        respond(conn, 401, "unauthorized")

      {:handle, {:error, reason}} ->
        respond(conn, 422, to_string_reason(reason))

      {:error, reason} ->
        Logger.error("Letterbox could not keep a message from #{name}: #{inspect(reason)}")
        respond(conn, 500, "not_kept")
    end
  end

  defp deliver_all(deliveries, ingress) do
    Enum.reduce_while(deliveries, :ok, fn delivery, :ok ->
      case deliver(delivery, ingress) do
        {:ok, _inbound} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp deliver({:raw, raw, opts}, ingress),
    do: Pipeline.ingest(raw, Keyword.put(opts, :ingress, ingress))

  defp deliver({:fetch, id, opts}, ingress),
    do:
      Pipeline.expect(
        ingress,
        id,
        Keyword.get(opts, :recipients, []),
        Keyword.get(opts, :meta, %{})
      )

  defp respond(conn, status, error) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(%{error: error}))
  end

  defp to_string_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp to_string_reason(_reason), do: "invalid"
end
