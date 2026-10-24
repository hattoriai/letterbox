defmodule Letterbox.Dev.MessagesLive do
  @moduledoc false
  # The messages, the newest first, by status.

  use Phoenix.LiveView
  use PhoenixMountable.Path, mountable: Letterbox.Dev.Router

  import Letterbox.Dev.Components

  @statuses ~w(pending received processing delivered bounced unrouted failed)
  @refresh 1_500

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@refresh, :refresh)
    {:ok, assign(socket, statuses: @statuses)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    status = if params["status"] in @statuses, do: params["status"]
    {:noreply, socket |> assign(status: status) |> load()}
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    messages = Letterbox.list(status: socket.assigns.status, limit: 100)
    assign(socket, messages: messages, page_title: "Letterbox")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page title="Messages" mount={@mount}>
      <:actions>
        <.link navigate={~m"/new"} class="lb-button lb-primary">Write an email</.link>
      </:actions>

      <nav class="lb-tabs" aria-label="Status">
        <.link patch={~m"/"} class={["lb-tab", is_nil(@status) && "lb-current"]}>All</.link>
        <.link
          :for={status <- @statuses}
          patch={~m"/?#{[status: status]}"}
          class={["lb-tab", @status == status && "lb-current"]}
        >
          {status}
        </.link>
      </nav>

      <p :if={@messages == []} class="lb-empty">
        No messages yet. <.link navigate={~m"/new"}>Write one</.link>
        to see it go to its mailbox.
      </p>

      <table :if={@messages != []} class="lb-table">
        <thead>
          <tr>
            <th>Status</th>
            <th>From</th>
            <th>Subject</th>
            <th>To</th>
            <th>Mailbox</th>
            <th>Received</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={message <- @messages}>
            <td><.status status={message.status} /></td>
            <td>{message.from}</td>
            <td>
              <.link navigate={~m"/#{message.id}"} class="lb-subject">
                {message.subject || "(no subject)"}
              </.link>
            </td>
            <td class="lb-muted">{Enum.join(message.recipients, ", ")}</td>
            <td class="lb-muted">{message.mailbox}</td>
            <td class="lb-muted">{ago(message.inserted_at)}</td>
          </tr>
        </tbody>
      </table>
    </.page>
    """
  end
end
