defmodule Letterbox.Ingress.Relay do
  @moduledoc """
  Raw emails, posted as they are by whatever has them: a mail server's
  pipe (Postfix, Exim), a Cloudflare Email Worker, a script.

      config :letterbox, ingresses: [relay: [token: "a long random token"]]

  A request is a `POST` to its route (`/inbound/webhooks/relay`, as
  `mix letterbox.install` writes it) with the email as its body
  (`Content-Type: message/rfc822`), and the token as a bearer
  (`Authorization: Bearer <token>`) or as the password of basic auth (as
  Action Mailbox's relay takes it). Two headers help:

    * `X-Letterbox-Recipients` - the envelope's recipients, separated by
      commas: the addresses the mail server took it for.
    * `X-Letterbox-Id` - an id of the email's, to take it once only when it
      is posted twice.

  From Postfix, in `master.cf`:

      letterbox unix - n n - - pipe
        flags=Rq user=mail argv=/usr/bin/curl --fail --data-binary @-
          -H Content-Type:message/rfc822 -H Authorization:Bearer\\ <token>
          -H X-Letterbox-Recipients:${recipient}
          https://example.com/inbound/webhooks/relay

  From a Cloudflare Email Worker:

      export default {
        async email(message, env) {
          await fetch("https://example.com/inbound/webhooks/relay", {
            method: "POST",
            body: message.raw,
            headers: {
              "content-type": "message/rfc822",
              authorization: `Bearer ${env.LETTERBOX_TOKEN}`,
              "x-letterbox-recipients": message.to
            }
          });
        }
      };
  """

  @behaviour Letterbox.Ingress

  @impl true
  def verify(conn, _raw_body, opts) do
    with token when is_binary(token) and token != "" <- opts[:token],
         given when is_binary(given) <- given_token(conn),
         true <- Plug.Crypto.secure_compare(given, token) do
      :ok
    else
      _ -> :error
    end
  end

  defp given_token(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        String.trim(token)

      ["Basic " <> encoded] ->
        with {:ok, decoded} <- Base.decode64(String.trim(encoded)),
             [_user, password] <- :binary.split(decoded, ":") do
          password
        else
          _ -> nil
        end

      _other ->
        nil
    end
  end

  @impl true
  def handle(conn, raw_body, _opts) do
    recipients =
      conn
      |> Plug.Conn.get_req_header("x-letterbox-recipients")
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    id = conn |> Plug.Conn.get_req_header("x-letterbox-id") |> List.first()

    if String.trim(raw_body) == "",
      do: {:error, :empty},
      else: {:ok, [{:raw, raw_body, recipients: recipients, external_id: id}]}
  end
end
