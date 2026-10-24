defmodule Letterbox.Dev.Components do
  @moduledoc false
  # The pieces of the development page: its frame, a message's status, a
  # time, a size.

  use Phoenix.Component
  use PhoenixMountable.Path, mountable: Letterbox.Dev.Router

  attr :title, :string, required: true
  attr :mount, :any, required: true
  slot :actions
  slot :inner_block, required: true

  def page(assigns) do
    ~H"""
    <div class="lb">
      <header class="lb-header">
        <a class="lb-brand" href={PhoenixMountable.Path.path(@mount, "/")}>
          <span class="lb-mark" aria-hidden="true"></span> Letterbox
        </a>
        <h1 class="lb-title">{@title}</h1>
        <div class="lb-actions">{render_slot(@actions)}</div>
      </header>
      <main class="lb-main">{render_slot(@inner_block)}</main>
    </div>
    """
  end

  attr :status, :string, required: true

  def status(assigns) do
    ~H"""
    <span class={"lb-status lb-status-#{@status}"}>{@status}</span>
    """
  end

  def ago(nil), do: ""

  def ago(%DateTime{} = at) do
    seconds = DateTime.diff(DateTime.utc_now(), at)

    cond do
      seconds < 60 -> "just now"
      seconds < 3_600 -> "#{div(seconds, 60)} min ago"
      seconds < 86_400 -> "#{div(seconds, 3_600)} h ago"
      true -> Calendar.strftime(at, "%d %b %Y, %H:%M")
    end
  end

  def bytes(nil), do: ""
  def bytes(bytes) when bytes < 1_024, do: "#{bytes} B"
  def bytes(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1_024, 1)} KB"
  def bytes(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  # Messages whose status can still change: the pages refresh while there
  # are some.
  def moving?(status), do: status in ["pending", "received", "processing"]
end
