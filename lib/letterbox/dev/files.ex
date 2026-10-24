defmodule Letterbox.Dev.Files do
  @moduledoc false
  # A message's raw email and its attachments, from the development page.
  # Downloaded, never shown as a page of the app: an attachment is the
  # sender's, and could be HTML. Images the HTML shows are given as images,
  # of the few types a browser cannot run.

  @behaviour Plug

  import Plug.Conn

  @images ~w(image/png image/jpeg image/gif image/webp)

  @impl Plug
  def init(action), do: action

  @impl Plug
  def call(conn, :raw) do
    case Letterbox.raw(conn.path_params["id"]) do
      {:ok, raw} -> download(conn, "message.eml", "message/rfc822", raw, :attachment)
      {:error, _reason} -> send_resp(conn, 404, "Not found")
    end
  end

  def call(conn, :file) do
    with {index, ""} <- Integer.parse(conn.path_params["index"] || ""),
         {:ok, message} <- Letterbox.message(conn.path_params["id"]),
         %Letterbox.Attachment{} = attachment <- Enum.at(message.attachments, index) do
      data = Letterbox.Attachment.read(attachment)
      name = attachment.name || "attachment"

      if attachment.content_type in @images,
        do: download(conn, name, attachment.content_type, data, :inline),
        else: download(conn, name, "application/octet-stream", data, :attachment)
    else
      _missing -> send_resp(conn, 404, "Not found")
    end
  end

  defp download(conn, name, type, data, disposition) do
    conn
    |> put_resp_content_type(type, nil)
    |> put_resp_header("content-disposition", ~s(#{disposition}; filename="#{safe(name)}"))
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("content-security-policy", "default-src 'none'; sandbox")
    |> send_resp(200, data)
  end

  defp safe(name), do: String.replace(name, ~r/[^\w .\-]/u, "_")
end
