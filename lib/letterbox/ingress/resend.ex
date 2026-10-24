defmodule Letterbox.Ingress.Resend do
  @moduledoc """
  [Resend](https://resend.com)'s inbound emails.

      config :letterbox, ingresses: [resend: [secret: "whsec_…", api_key: "re_…"]]

  In Resend, a webhook for the `email.received` event, to its route
  (`https://<app>/inbound/webhooks/resend`, as `mix letterbox.install`
  writes it), and its signing secret as
  `:secret`. `:api_key` is a key of the account, which reads its emails.

  The webhook carries an email's id and envelope, not the email: Letterbox
  answers it at once, then fetches the email (`GET /emails/receiving/:id`)
  and its raw message (`raw.download_url`) out of the request, tried again
  while Resend has not got it. The recipients are Resend's
  `received_for`, the addresses it took the email for (`Bcc` included).

  The request is signed by Svix (`svix-id`, `svix-timestamp`,
  `svix-signature`): an HMAC-SHA256 of `"<id>.<timestamp>.<body>"` with the
  secret (Base64, after `whsec_`), and one more than five minutes away is
  refused.

  Options: `:secret`, `:api_key`, `:base_url` (`https://api.resend.com`),
  and `:req_options`, given to `Req` (for tests, `plug:`).
  """

  @behaviour Letterbox.Ingress

  @tolerance 5 * 60

  @impl true
  def verify(conn, raw_body, opts) do
    with "whsec_" <> secret <- opts[:secret],
         [id] <- Plug.Conn.get_req_header(conn, "svix-id"),
         [timestamp] <- Plug.Conn.get_req_header(conn, "svix-timestamp"),
         [signatures] <- Plug.Conn.get_req_header(conn, "svix-signature"),
         {seconds, ""} <- Integer.parse(timestamp),
         true <- abs(System.system_time(:second) - seconds) <= @tolerance,
         {:ok, key} <- Base.decode64(secret) do
      expected =
        :crypto.mac(:hmac, :sha256, key, "#{id}.#{timestamp}.#{raw_body}") |> Base.encode64()

      signatures
      |> String.split(" ", trim: true)
      |> Enum.any?(fn
        "v1," <> signature -> Plug.Crypto.secure_compare(signature, expected)
        _other -> false
      end)
      |> if(do: :ok, else: :error)
    else
      _ -> :error
    end
  end

  @impl true
  def handle(_conn, raw_body, _opts) do
    case JSON.decode(raw_body) do
      {:ok, %{"type" => "email.received", "data" => %{"email_id" => id} = data}}
      when is_binary(id) ->
        recipients = List.wrap(data["received_for"] || data["to"])
        meta = Map.take(data, ["from", "subject", "message_id", "created_at"])
        {:ok, [{:fetch, id, recipients: recipients, meta: meta}]}

      {:ok, %{}} ->
        {:ok, []}

      _other ->
        {:error, :invalid_payload}
    end
  end

  @impl true
  def fetch(id, opts) do
    with {:ok, email} <- get(opts, "/emails/receiving/" <> URI.encode(id)),
         %{"raw" => %{"download_url" => url}} when is_binary(url) <- email,
         {:ok, raw} <- download(opts, url) do
      {:ok, raw, recipients: List.wrap(email["received_for"] || email["to"])}
    else
      %{} -> {:error, :no_raw_email}
      {:error, reason} -> {:error, reason}
    end
  end

  defp get(opts, path) do
    request =
      Req.new(
        [
          base_url: Keyword.get(opts, :base_url, "https://api.resend.com"),
          auth: {:bearer, Keyword.fetch!(opts, :api_key)},
          retry: false
        ] ++ Keyword.get(opts, :req_options, [])
      )

    case Req.get(request, url: path) do
      {:ok, %Req.Response{status: 200, body: %{} = body}} -> {:ok, body}
      {:ok, %Req.Response{status: status}} -> {:error, {:resend, status}}
      {:error, exception} -> {:error, exception}
    end
  end

  # The raw email, from the signed URL of Resend's storage: no key, no
  # decoding.
  defp download(opts, url) do
    request = Req.new([retry: false, decode_body: false] ++ Keyword.get(opts, :req_options, []))

    case Req.get(request, url: url) do
      {:ok, %Req.Response{status: 200, body: raw}} when is_binary(raw) -> {:ok, raw}
      {:ok, %Req.Response{status: status}} -> {:error, {:resend_download, status}}
      {:error, exception} -> {:error, exception}
    end
  end
end
