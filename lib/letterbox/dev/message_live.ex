defmodule Letterbox.Dev.MessageLive do
  @moduledoc false
  # A message as its mailbox got it: its status and error, Retry and Delete,
  # its text and HTML, its attachments, headers and raw email.

  use Phoenix.LiveView
  use PhoenixMountable.Path, mountable: Letterbox.Dev.Router

  import Letterbox.Dev.Components

  @refresh 1_000

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@refresh, :refresh)
    {:ok, socket |> assign(id: id, tab: "text") |> load()}
  end

  @impl true
  def handle_info(:refresh, socket) do
    if socket.assigns.inbound && moving?(socket.assigns.inbound.status),
      do: {:noreply, load(socket)},
      else: {:noreply, socket}
  end

  @impl true
  def handle_event("tab", %{"tab" => tab}, socket), do: {:noreply, assign(socket, tab: tab)}

  def handle_event("retry", _params, socket) do
    case Letterbox.retry(socket.assigns.inbound) do
      {:ok, _inbound} -> {:noreply, load(socket)}
      {:error, reason} -> {:noreply, put_flash(socket, :error, "Not retried: #{inspect(reason)}")}
    end
  end

  def handle_event("delete", _params, socket) do
    :ok = Letterbox.delete(socket.assigns.inbound)
    {:noreply, push_navigate(socket, to: ~m"/")}
  end

  defp load(socket) do
    inbound = Letterbox.get(socket.assigns.id)

    message =
      case inbound && Letterbox.message(inbound) do
        {:ok, message} -> message
        _none -> nil
      end

    assign(socket,
      inbound: inbound,
      message: message,
      page_title: "#{(inbound && inbound.subject) || "Message"} · Letterbox"
    )
  end

  # The HTML in a frame: no script runs (sandbox), and nothing loads from
  # elsewhere (its policy). The images of the message itself (cid:) are in
  # it, as data: (a sandboxed frame's origin is no one's, so it could not
  # load them from this page): the few image types a browser cannot run, of
  # 2 MB at most.
  @images ~w(image/png image/jpeg image/gif image/webp)

  defp srcdoc(message) do
    html =
      Enum.reduce(message.attachments, message.html, fn
        %{content_id: cid, content_type: type, encoded_bytes: bytes} = attachment, html
        when is_binary(cid) and type in @images and bytes < 2_800_000 ->
          data = "data:#{type};base64," <> Base.encode64(Letterbox.Attachment.read(attachment))
          String.replace(html, "cid:" <> cid, data)

        _other, html ->
          html
      end)

    ~s(<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">) <>
      html
  end

  @impl true
  def render(%{inbound: nil} = assigns) do
    ~H"""
    <.page title="Not found" mount={@mount}>
      <:actions><.link navigate={~m"/"} class="lb-button">Messages</.link></:actions>
      <p class="lb-empty">This message is not here: it was deleted, or never was.</p>
    </.page>
    """
  end

  def render(assigns) do
    ~H"""
    <.page title={@inbound.subject || "(no subject)"} mount={@mount}>
      <:actions>
        <.link navigate={~m"/"} class="lb-button">Messages</.link>
        <button
          :if={@inbound.status in ~w(delivered bounced unrouted failed) and @inbound.raw_key}
          phx-click="retry"
          class="lb-button"
        >
          Retry
        </button>
        <button phx-click="delete" data-confirm="Delete this message and its raw email?" class="lb-button">
          Delete
        </button>
      </:actions>

      <p :if={Phoenix.Flash.get(@flash, :error)} class="lb-alert">
        {Phoenix.Flash.get(@flash, :error)}
      </p>

      <section class="lb-summary">
        <dl>
          <dt>Status</dt>
          <dd><.status status={@inbound.status} /></dd>
          <dt>Mailbox</dt>
          <dd>{@inbound.mailbox || "none"}</dd>
          <dt>Attempts</dt>
          <dd>{@inbound.attempts}</dd>
          <dt>Ingress</dt>
          <dd>{@inbound.ingress} <span :if={@inbound.external_id} class="lb-muted">{@inbound.external_id}</span></dd>
          <dt>Received</dt>
          <dd>{ago(@inbound.inserted_at)}</dd>
          <dt>Size</dt>
          <dd>{bytes(@inbound.raw_bytes)}</dd>
        </dl>
        <pre :if={@inbound.error} class="lb-error-box">{@inbound.error}</pre>
      </section>

      <section :if={@message} class="lb-message">
        <dl class="lb-addresses">
          <dt>From</dt>
          <dd>
            {to_string(@message.from || "")}
            <span :if={@message.verified_from} class="lb-verified">verified</span>
          </dd>
          <dt>To</dt>
          <dd>{Enum.map_join(@message.to, ", ", &to_string/1)}</dd>
          <dt :if={@message.cc != []}>Cc</dt>
          <dd :if={@message.cc != []}>{Enum.map_join(@message.cc, ", ", &to_string/1)}</dd>
          <dt>Delivered to</dt>
          <dd>{Enum.map_join(@message.recipients, ", ", & &1.address)}</dd>
        </dl>

        <nav class="lb-tabs">
          <button
            :for={{tab, label} <- [{"text", "Text"}, {"html", "HTML"}, {"headers", "Headers"}]}
            phx-click="tab"
            phx-value-tab={tab}
            class={["lb-tab", @tab == tab && "lb-current"]}
          >
            {label}
          </button>
          <a href={~m"/#{@inbound.id}/raw"} class="lb-tab">Raw email</a>
        </nav>

        <pre :if={@tab == "text"} class="lb-text">{@message.text}</pre>
        <iframe
          :if={@tab == "html" and @message.html}
          sandbox=""
          srcdoc={srcdoc(@message)}
          class="lb-html"
          title="The email's HTML"
        >
        </iframe>
        <p :if={@tab == "html" and is_nil(@message.html)} class="lb-empty">This email has no HTML.</p>
        <table :if={@tab == "headers"} class="lb-table lb-headers">
          <tr :for={{name, value} <- @message.headers}>
            <th>{name}</th>
            <td>{Letterbox.MIME.Header.decode(value)}</td>
          </tr>
        </table>

        <h2 :if={@message.attachments != []}>Attachments</h2>
        <ul :if={@message.attachments != []} class="lb-attachments">
          <li :for={{attachment, index} <- Enum.with_index(@message.attachments)}>
            <a href={~m"/#{@inbound.id}/files/#{index}"}>{attachment.name || "(no name)"}</a>
            <span class="lb-muted">{attachment.content_type}</span>
            <span :if={attachment.inline?} class="lb-muted">shown in the text</span>
          </li>
        </ul>

        <h2 :if={@message.file_links != []}>Files sent as links</h2>
        <ul :if={@message.file_links != []} class="lb-attachments">
          <li :for={link <- @message.file_links}>
            <span class="lb-muted">{link.service}</span> {link.url}
          </li>
        </ul>
      </section>
    </.page>
    """
  end
end
