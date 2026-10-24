defmodule Letterbox.Dev.ComposeLive do
  @moduledoc false
  # An email written here, with attachments, delivered as an ingress's
  # would be.

  use Phoenix.LiveView
  use PhoenixMountable.Path, mountable: Letterbox.Dev.Router

  import Letterbox.Dev.Components

  @fields ~w(from to cc subject text html)

  @impl true
  def mount(_params, _session, socket) do
    form =
      to_form(%{
        "from" => "Ana <ana@example.com>",
        "to" => "",
        "cc" => "",
        "subject" => "",
        "text" => "",
        "html" => ""
      })

    {:ok,
     socket
     |> assign(form: form, error: nil, page_title: "Write an email · Letterbox")
     |> allow_upload(:attachments, accept: :any, max_entries: 20, max_file_size: 25_000_000)}
  end

  @impl true
  def handle_event("validate", %{"email" => params}, socket),
    do: {:noreply, assign(socket, form: to_form(Map.take(params, @fields), as: :email))}

  def handle_event("cancel", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :attachments, ref)}

  def handle_event("send", %{"email" => params}, socket) do
    attachments =
      consume_uploaded_entries(socket, :attachments, fn %{path: path}, entry ->
        {:ok, %{name: entry.client_name, content_type: entry.client_type, data: File.read!(path)}}
      end)

    raw =
      Letterbox.Email.build(
        from: blank(params["from"]),
        to: list(params["to"]),
        cc: list(params["cc"]),
        subject: blank(params["subject"]),
        text: blank(params["text"]),
        html: blank(params["html"]),
        attachments: attachments
      )

    case Letterbox.ingest(raw, ingress: "dev") do
      {:ok, inbound} ->
        {:noreply, push_navigate(socket, to: ~m"/#{inbound.id}")}

      {:error, reason} ->
        {:noreply, assign(socket, error: "Letterbox could not keep it: #{inspect(reason)}")}
    end
  end

  defp blank(nil), do: nil
  defp blank(text), do: if(String.trim(text) == "", do: nil, else: text)

  defp list(nil), do: nil

  defp list(text) do
    case text |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) do
      [] -> nil
      addresses -> addresses
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page title="Write an email" mount={@mount}>
      <:actions>
        <.link navigate={~m"/"} class="lb-button">Messages</.link>
      </:actions>

      <p :if={@error} class="lb-alert">{@error}</p>

      <.form
        for={@form}
        as={:email}
        id="letterbox-email"
        phx-change="validate"
        phx-submit="send"
        class="lb-form"
      >
        <label>
          From <input type="text" name="email[from]" value={@form[:from].value} autocomplete="off" />
        </label>
        <label>
          To
          <input
            type="text"
            name="email[to]"
            value={@form[:to].value}
            placeholder="support@in.example.com, separated by commas"
            autocomplete="off"
            required
          />
        </label>
        <label>Cc <input type="text" name="email[cc]" value={@form[:cc].value} autocomplete="off" /></label>
        <label>
          Subject <input type="text" name="email[subject]" value={@form[:subject].value} />
        </label>
        <label>Text <textarea name="email[text]" rows="8">{@form[:text].value}</textarea></label>
        <details class="lb-details">
          <summary>HTML</summary>
          <textarea name="email[html]" rows="6">{@form[:html].value}</textarea>
        </details>

        <div class="lb-files" phx-drop-target={@uploads.attachments.ref}>
          <label class="lb-button">
            Attach files <.live_file_input upload={@uploads.attachments} class="lb-hidden" />
          </label>
          <span class="lb-muted">or drop them here</span>
          <ul :if={@uploads.attachments.entries != []}>
            <li :for={entry <- @uploads.attachments.entries}>
              {entry.client_name} <span class="lb-muted">{bytes(entry.client_size)}</span>
              <button type="button" phx-click="cancel" phx-value-ref={entry.ref} class="lb-link">
                Remove
              </button>
              <span :for={error <- upload_errors(@uploads.attachments, entry)} class="lb-error">
                {inspect(error)}
              </span>
            </li>
          </ul>
        </div>

        <button type="submit" class="lb-button lb-primary">Send to the app</button>
      </.form>
    </.page>
    """
  end
end
