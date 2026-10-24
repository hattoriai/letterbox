defmodule Letterbox.Ingress do
  @moduledoc """
  How messages reach the app: a provider's webhook, a relay, a module of
  the app's own. Each is named in the config, and its webhook is a route
  of the app's (`Letterbox.Plug`), `POST /inbound/webhooks/<name>` as
  `mix letterbox.install` writes it:

      config :letterbox,
        ingresses: [
          resend: [secret: "whsec_…", api_key: "re_…"],
          relay: [token: "…"],
          postmark: {MyApp.PostmarkIngress, token: "…"}
        ]

  Letterbox has `Letterbox.Ingress.Resend` and `Letterbox.Ingress.Relay`.

  ## Writing one

  An ingress checks a request (`verify/3`, with the body exactly as it was
  sent), and says what it brings (`handle/3`): raw emails, `{:raw, raw,
  opts}`, kept at once; or emails to fetch, `{:fetch, id, opts}`, which
  Letterbox fetches out of the request with `fetch/2`, tried again when the
  provider fails. The options of each are those of `Letterbox.ingest/2`
  (`:recipients`, `:external_id`, `:meta`); an email to fetch takes
  `:recipients` and `:meta`.
  """

  @type delivery :: {:raw, binary(), keyword()} | {:fetch, String.t(), keyword()}

  @doc "Whether the request is the ingress's: `:ok`, or `:error` (a `401`)."
  @callback verify(Plug.Conn.t(), raw_body :: binary(), opts :: keyword()) :: :ok | :error

  @doc "What the request brings: none (an event of another kind), one, or several."
  @callback handle(Plug.Conn.t(), raw_body :: binary(), opts :: keyword()) ::
              {:ok, [delivery()]} | {:error, term()}

  @doc """
  An email the ingress's provider has, by its id: `{:ok, raw, extra}`,
  where `extra` can give `:recipients`, or `{:error, reason}` to be tried
  again.
  """
  @callback fetch(id :: String.t(), opts :: keyword()) ::
              {:ok, binary(), keyword()} | {:error, term()}

  @optional_callbacks fetch: 2
end
