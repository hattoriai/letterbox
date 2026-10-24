defmodule Letterbox.Message do
  @moduledoc """
  A message that came to the app, as its mailbox gets it.

  Its fields are a message's, whatever brought it: who sent it, to whom,
  its subject, its text and HTML, its files, when it was sent. Email is
  the one channel there is (`channel: :email`); the email's own are kept
  beside them: its headers, `Message-ID` and references, its structure
  and the raw email.

    * `:id` - the message's row (`Letterbox.Inbound`).
    * `:from` - the sender (`Letterbox.Address`), as the email says it.
      Anyone can write any `From`.
    * `:verified_from` - the sender, when a mail server the app trusts
      checked it: the `From` whose domain passed DMARC, or DKIM or SPF
      for that domain, in that server's `Authentication-Results` (see
      `Letterbox.Email.parse/2`'s `:trusted_servers`). nil otherwise. Act
      on this one, not on `:from`, for what only a known sender may do.
    * `:to`, `:cc`, `:bcc`, `:reply_to` - its addresses, as the email says.
    * `:recipient` - the recipient its route matched (`Letterbox.Routing`):
      the address it came in by, `site+abc123@in.example.com`, whose
      sub-address (`Letterbox.Address.tag/1`) can say whose it is.
    * `:recipients` - where it was delivered: the addresses the mail
      server took it for (an ingress's envelope, Resend's
      `received_for`), else those of `To`, `Cc`, `Delivered-To` and
      `X-Original-To`. An address in `Bcc` is only here.
    * `:subject`, `:text`, `:html` - in UTF-8. `:text` is the plain text
      the email has, or text from its HTML when it has none. `:lossy` is
      true when some of it could not be read (a charset no one knows).
    * `:attachments` - its files (`Letterbox.Attachment`), those its HTML
      shows (`inline?: true`) included.
    * `:file_links` - links in its text to files sent another way, too
      large for an email: Apple's Mail Drop, Google Drive, OneDrive,
      Dropbox, WeTransfer. `%{url: …, service: :mail_drop | …}`.
    * `:sent_at` - its `Date`, in UTC, or nil.
    * `:message_id`, `:in_reply_to`, `:references` - the email's ids,
      without their angle brackets: what threads it to what was sent.
    * `:headers` - all the email's headers (`Letterbox.MIME.Header`),
      undecoded; `header/2` gives one decoded.
    * `:mime` - its structure (`Letterbox.MIME`), and `:raw`, the email as
      it came.
  """

  alias Letterbox.{Address, Attachment, MIME}
  alias Letterbox.MIME.Header

  defstruct [
    :id,
    :from,
    :verified_from,
    :recipient,
    :subject,
    :text,
    :html,
    :sent_at,
    :message_id,
    :mime,
    :raw,
    channel: :email,
    to: [],
    cc: [],
    bcc: [],
    reply_to: [],
    recipients: [],
    attachments: [],
    file_links: [],
    in_reply_to: [],
    references: [],
    headers: [],
    lossy: false
  ]

  @type t :: %__MODULE__{
          id: term(),
          channel: :email,
          from: Address.t() | nil,
          verified_from: Address.t() | nil,
          to: [Address.t()],
          cc: [Address.t()],
          bcc: [Address.t()],
          reply_to: [Address.t()],
          recipient: Address.t() | nil,
          recipients: [Address.t()],
          subject: String.t() | nil,
          text: String.t() | nil,
          html: String.t() | nil,
          attachments: [Attachment.t()],
          file_links: [%{url: String.t(), service: atom()}],
          sent_at: DateTime.t() | nil,
          message_id: String.t() | nil,
          in_reply_to: [String.t()],
          references: [String.t()],
          headers: [Header.t()],
          lossy: boolean(),
          mime: MIME.t() | nil,
          raw: binary() | nil
        }

  @doc "The first value of a header (any case), decoded to UTF-8, or nil."
  @spec header(t(), String.t()) :: String.t() | nil
  def header(%__MODULE__{headers: headers}, name),
    do: headers |> Header.get(String.downcase(name)) |> Header.decode()

  @doc "Every value of a header (any case), decoded."
  @spec headers(t(), String.t()) :: [String.t()]
  def headers(%__MODULE__{headers: headers}, name),
    do: headers |> Header.get_all(String.downcase(name)) |> Enum.map(&Header.decode/1)

  @doc """
  Whether it was delivered to `address` (a string, any case, with or
  without its sub-address).
  """
  @spec delivered_to?(t(), String.t()) :: boolean()
  def delivered_to?(%__MODULE__{recipients: recipients}, address),
    do: Enum.any?(recipients, &Address.matches?(&1, address))

  @doc "Its attachments the HTML does not show in its text."
  @spec files(t()) :: [Attachment.t()]
  def files(%__MODULE__{attachments: attachments}), do: Enum.reject(attachments, & &1.inline?)
end
