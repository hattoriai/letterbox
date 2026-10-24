defmodule Letterbox.Dev.Router do
  @moduledoc """
  The development page: write an email to the app and see what became of
  it, as Action Mailbox's conductor does. Mounted in the app's router,
  where only developers reach it:

      import Letterbox.Dev.Router

      if Application.compile_env(:my_app, :dev_routes) do
        scope "/dev" do
          pipe_through :browser
          letterbox_dev "/letterbox"
        end
      end

  At `/dev/letterbox`:

    * the messages, the newest first, with their status, refreshed while
      they change;
    * a form to write an email, with attachments, that is delivered as an
      ingress's would be (`ingress: "dev"`), routed and given to its
      mailbox;
    * each message as its mailbox got it (`Letterbox.Message`): its status
      and error, Retry and Delete, its text, its HTML in a frame that runs
      no script and loads nothing from elsewhere, its attachments and its
      raw email.

  It is a page of its own, with its own style sheet and script, served
  under the mount: nothing to add to the app's assets. It is a library
  mounted with [PhoenixMountable](https://hexdocs.pm/phoenix_mountable), so
  it takes PhoenixMountable's options (`:as`, `:on_mount`, …).
  """

  use PhoenixMountable,
    otp_app: :letterbox,
    macro: :letterbox_dev,
    title: "Letterbox",
    layout: {PhoenixMountable.Layout, :root},
    schema: Letterbox.Migrations,
    assets:
      {PhoenixMountable.Assets.Embedded,
       css: "priv/static/letterbox-dev.css",
       js: "priv/static/letterbox-dev.js",
       prepend: [:phoenix, :phoenix_live_view, :phoenix_mountable]}

  # The repo of Letterbox's table, for the check that its migrations ran.
  @impl PhoenixMountable
  def repo(_mount), do: Letterbox.Config.repo()

  routes do
    live "/", Letterbox.Dev.MessagesLive, :index
    live "/new", Letterbox.Dev.ComposeLive, :new
    live "/:id", Letterbox.Dev.MessageLive, :show
    get "/:id/raw", Letterbox.Dev.Files, :raw
    get "/:id/files/:index", Letterbox.Dev.Files, :file
  end
end
