defmodule Letterbox.RawBody do
  @moduledoc """
  A body reader for `Plug.Parsers`, for the webhooks whose signature is of
  the body as it was sent (Resend's, signed by Svix).

  An endpoint whose `Plug.Parsers` reads JSON (a Phoenix app's does) reads
  the body before the router. This reader reads it as
  `Plug.Conn.read_body/2` does, and keeps a copy of it for the requests to
  a path `…/webhooks/<ingress>` only:

      plug Plug.Parsers,
        parsers: [:urlencoded, :multipart, :json],
        pass: ["*/*"],
        body_reader: {Letterbox.RawBody, :read_body, []},
        json_decoder: Phoenix.json_library()

  A relay's raw email (`message/rfc822`) is not read by the parsers at all
  (`pass: ["*/*"]`), so it needs no copy. An app with Tayori can keep
  Tayori's reader (`Tayori.RawBody`): Letterbox reads the copy it keeps.
  """

  @doc "Reads the body, as `Plug.Conn.read_body/2`, and keeps a copy of a webhook's."
  @spec read_body(Plug.Conn.t(), keyword()) ::
          {:ok, binary(), Plug.Conn.t()} | {:more, binary(), Plug.Conn.t()} | {:error, term()}
  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} -> {:ok, body, keep(conn, body)}
      {:more, body, conn} -> {:more, body, keep(conn, body)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp keep(conn, body) do
    if webhook_path?(conn.path_info) do
      Plug.Conn.put_private(conn, :letterbox_raw_body, [
        Map.get(conn.private, :letterbox_raw_body, []),
        body
      ])
    else
      conn
    end
  end

  defp webhook_path?(["webhooks", _ingress]), do: true
  defp webhook_path?([_ | rest]), do: webhook_path?(rest)
  defp webhook_path?([]), do: false

  @doc false
  # The body of a request, as it was sent: read here, or kept when the
  # endpoint's parsers read it first. At most `max` bytes.
  @spec fetch(Plug.Conn.t(), pos_integer()) ::
          {:ok, binary(), Plug.Conn.t()} | {:error, :too_large | :no_raw_body | term()}
  def fetch(%{body_params: %Plug.Conn.Unfetched{}} = conn, max), do: read_all(conn, max, [])

  def fetch(conn, max) do
    case conn.private[:letterbox_raw_body] || conn.private[:tayori_raw_body] do
      nil ->
        # The parsers passed it (a raw email, `pass: ["*/*"]`): unread.
        case read_all(conn, max, []) do
          {:ok, "", _conn} -> {:error, :no_raw_body}
          result -> result
        end

      kept ->
        body = IO.iodata_to_binary(kept)
        if byte_size(body) > max, do: {:error, :too_large}, else: {:ok, body, conn}
    end
  end

  defp read_all(conn, max, acc) do
    case Plug.Conn.read_body(conn, length: min(max, 8_000_000), read_length: 1_000_000) do
      {:ok, body, conn} ->
        total = IO.iodata_to_binary([acc, body])
        if byte_size(total) > max, do: {:error, :too_large}, else: {:ok, total, conn}

      {:more, body, conn} ->
        acc = [acc, body]
        if IO.iodata_length(acc) > max, do: {:error, :too_large}, else: read_all(conn, max, acc)

      {:error, reason} ->
        {:error, reason}
    end
  end
end
