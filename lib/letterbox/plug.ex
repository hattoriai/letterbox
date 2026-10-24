defmodule Letterbox.Plug do
  @moduledoc """
  The webhooks of the ingresses (`Letterbox.Ingress`): `POST
  …/webhooks/:ingress`, mounted with `Letterbox.Router.letterbox/2`, or,
  in an app without Phoenix's router:

      forward "/inbound", Letterbox.Plug, :webhook

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

  The mount takes no session and no CSRF token: a provider has neither.
  Mount it in a pipeline without `:protect_from_forgery`.
  """

  @behaviour Plug

  import Plug.Conn

  alias Letterbox.{Config, Pipeline, RawBody}

  require Logger

  @impl Plug
  def init(action), do: action

  @impl Plug
  def call(%{method: "POST"} = conn, _action) do
    case ingress_name(conn) do
      nil -> respond(conn, 404, "not_found")
      name -> webhook(conn, name)
    end
  end

  def call(conn, _action), do: respond(conn, 405, "method_not_allowed")

  defp ingress_name(%{path_params: %{"ingress" => name}}) when is_binary(name), do: name

  defp ingress_name(%{path_info: path_info}) do
    case Enum.take(path_info, -2) do
      ["webhooks", name] -> name
      _other -> nil
    end
  end

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
            "Give Plug.Parsers `body_reader: {Letterbox.RawBody, :read_body, []}`."
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
