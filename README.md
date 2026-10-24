# Letterbox

![Letterbox — Inbound email for Phoenix](https://raw.githubusercontent.com/hattoriai/letterbox/main/media/banner.png)

**Inbound email for Phoenix: emails to your app, kept, read and given to
your code.**

Replies to the notifications your app sends, a support address, receipts
forwarded to be filed, photographs emailed to a library. An email comes
in through your provider or a relay, Letterbox keeps it, reads it (its
text, its HTML, its attachments, who sent it) and gives it to the
mailbox your routes name.

> Early release. Before 1.0, a minor version may change the API.

## Install

```sh
mix igniter.install letterbox
```

or add `{:letterbox, "~> 0.1"}` and run `mix letterbox.install`. It
writes the migration of Letterbox's table, the webhooks' route, the
config, your routes and a first mailbox, and shows each change before it
writes (see `Mix.Tasks.Letterbox.Install`). Letterbox needs Elixir 1.18+,
Phoenix 1.7.14+ and Storehouse, which keeps the raw emails in your store.

## Your first mailbox

Routes say which mailbox takes which message:

```elixir
defmodule MyApp.Mailboxes do
  use Letterbox.Routing

  route "support@", to: MyApp.SupportMailbox
  route ~r/\Areply\+/, to: MyApp.RepliesMailbox
  route "@in.example.com", to: MyApp.SitesMailbox
  route :all, to: MyApp.Mailboxes.Inbox
end
```

A mailbox gets a `Letterbox.Message`:

```elixir
defmodule MyApp.SupportMailbox do
  use Letterbox.Mailbox

  @impl true
  def process(message) do
    MyApp.Tickets.open(message.from, message.subject, message.text)
  end
end
```

`:ok` delivers it; `{:bounce, reason}` refuses it for good; an error or
an exception tries it again, then marks it failed. Every message has a
row (`Letterbox.Inbound`) with its status, and its raw email in your
store, so a failed one can be retried once the bug is fixed.

## How emails reach your app

Your domain's mail goes to a provider, or a server of yours, which hands
it to Letterbox: that is an ingress. Point a domain's MX records at it
once (`in.example.com`), and every address there reaches your routes.

```elixir
# config/runtime.exs
config :letterbox,
  ingresses: [
    resend: [secret: System.fetch_env!("RESEND_WEBHOOK_SECRET"), api_key: System.fetch_env!("RESEND_API_KEY")],
    relay: [token: System.fetch_env!("LETTERBOX_RELAY_TOKEN")]
  ]
```

* **Resend** (`Letterbox.Ingress.Resend`): its webhook, signed, and the
  raw email fetched from its API out of the request.
* **A relay** (`Letterbox.Ingress.Relay`): the raw email posted as it is,
  with a token, from Postfix, a Cloudflare Email Worker or a script.
* **Your own** (`Letterbox.Ingress`), or `Letterbox.ingest/2` from your
  code.

The webhooks are a plain route of your router, yours to move and rename
(`Letterbox.Plug`):

```elixir
scope "/inbound" do
  pipe_through :webhooks
  post "/webhooks/:ingress", Letterbox.Plug, []
end
```

A signed webhook needs its body as it was sent: give your endpoint's
`Plug.Parsers` `body_reader: {Letterbox.RawBody, :read_body, []}`.

## Attachments

Nothing is decoded until you ask, and a large file is written to the
disk as it is decoded, never whole in memory:

```elixir
for attachment <- message.attachments, String.starts_with?(attachment.content_type, "image/") do
  Letterbox.Attachment.store(attachment,
    accept: Storehouse.Check.images(),
    owner: "sites/#{site.id}",
    room: Media.room(site),
    existing: &Media.by_checksum(site, &1)
  )
end
```

`store/2` keeps it with Storehouse, checked by its bytes, under your
limits, and gives back a file you have already (`:existing`) rather than
a copy. `:inline?` says whether the HTML shows it in its text, as a phone
does with the photographs of its body, and `message.file_links` the files
sent as links (Mail Drop, Google Drive, …).

## The development page

```elixir
import Letterbox.Dev.Router

if Application.compile_env(:my_app, :dev_routes) do
  scope "/dev" do
    pipe_through :browser
    letterbox_dev "/letterbox"
  end
end
```

At `/dev/letterbox`: write an email to your app, with attachments, and
see what became of it, its mailbox, its status, its text and HTML (in a
frame that runs nothing and loads nothing from elsewhere), its files and
its raw email; retry it, delete it.

## What you get

* **Email as mail clients write it.** A MIME parser of Letterbox's own:
  every charset of the WHATWG Encoding Standard (Latin-1 read as
  Windows-1252, as browsers do), encoded words split across lines, file
  names of RFC 2231, `LF` as well as `CRLF`, multiparts that never end.
  It copies nothing: each part is a sub-binary of the email.
* **Who sent it.** `message.from` is what the email says; `verified_from`
  is the sender a mail server you trust checked (DMARC, DKIM, SPF in its
  `Authentication-Results`).
* **Where it went.** The envelope's recipients, a `Bcc` included, and the
  one the route matched, `site+abc123@`, whose sub-address
  (`Letterbox.Address.tag/1`) can say whose it is.
* **Work out of the request.** On Oban when your app runs it, else a
  process of Letterbox's, with retries; waiting messages are resumed
  after a restart, and old ones deleted (`Letterbox.Sweeper`).
* **Tests without a provider.** `Letterbox.Test.deliver/2` goes the whole
  way in the test's process; `message/2` and `mailbox_for/2` test a
  mailbox and your routes on their own.
* **Telemetry** of each message kept and processed.

## How Letterbox compares

The Elixir libraries that receive email, as their documentation and code
describe them in October 2026. A correction is welcome as an issue.

| | Letterbox 0.1 | [mailroom](https://hex.pm/packages/mailroom) 0.7 | [gen_smtp](https://hex.pm/packages/gen_smtp) 1.3 | [mail](https://hex.pm/packages/mail) 0.5 |
|---|---|---|---|---|
| Webhooks of providers | Yes | No | No | No |
| A relay of raw emails | Yes | No | No | No |
| Polling a mailbox (IMAP, POP3) | Later | Yes | No | No |
| An SMTP server | Later | No | Yes | No |
| Routing to the app's code | Yes | No | No | No |
| Kept, with a status, retried | Yes | No | No | No |
| Charsets beyond UTF-8 and Latin-1 | All of WHATWG's | With a handler of yours | With iconv installed | No |
| RFC 2231 file names, read | Yes | No (mail's parser) | No (written only) | No |
| Attachments streamed to the disk | Yes | No | No | No |
| Senders verified | Yes | No | No | No |
| A development page | Yes | No | No | No |

## Roadmap

* **Replies**: the new words of a reply without the quoted email, in many
  languages and mail apps; auto-replies told apart; signed reply
  addresses; threads; answers sent with Swoosh that come back.
* **More ways in**: Postmark, Amazon SES, Mailgun and Cloudflare; bounces
  matched to what was sent; forwarded emails and their first sender.
* **An SMTP server in the app** (`gen_smtp`), and an email shown safely as
  a component of your own pages.
* **People's own mailboxes** over IMAP, Gmail and Microsoft Graph.
* Japanese, Chinese and Korean charsets of their own; until then,
  `Letterbox.Charset` takes a module of yours.

## Development

```sh
mix deps.get
DATABASE_URL=postgres://postgres:postgres@localhost/letterbox_test mix test
mix credo --strict
```

The charsets' tables are written from WHATWG's files: `mix run
scripts/charsets.exs`. The media are made in
[hattoriai/ideas](https://github.com/hattoriai/ideas).

## License

MIT. See [LICENSE](https://github.com/hattoriai/letterbox/blob/main/LICENSE).
