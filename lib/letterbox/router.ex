defmodule Letterbox.Router do
  @moduledoc """
  Mounts Letterbox in the app's router.

      import Letterbox.Router

      # The ingresses' webhooks: no session, no CSRF token.
      pipeline :inbound do
        plug :accepts, ["json"]
      end

      scope "/" do
        pipe_through :inbound
        letterbox "/inbound"
      end

  `letterbox/2` mounts `POST /inbound/webhooks/:ingress` (`Letterbox.Plug`):
  `/inbound/webhooks/resend`, `/inbound/webhooks/relay`. It is a library
  mounted with [PhoenixMountable](https://hexdocs.pm/phoenix_mountable):
  ordinary routes in the app's router (`mix phx.routes` lists them), behind
  the app's own scopes and pipelines.
  """

  use PhoenixMountable,
    otp_app: :letterbox,
    macro: :letterbox,
    schema: Letterbox.Migrations

  routes do
    post "/webhooks/:ingress", Letterbox.Plug, :webhook
  end
end
