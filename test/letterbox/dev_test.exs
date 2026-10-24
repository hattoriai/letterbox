defmodule Letterbox.DevTest do
  # The page's LiveViews are processes of their own: the sandbox is shared.
  use LetterboxTest.DataCase, async: false
  use PhoenixMountable.Test, host: LetterboxTest.Host

  @moduletag :db

  describe "the messages" do
    test "the newest first, with their status, by status", %{conn: conn} do
      deliver(
        from: "ana@example.com",
        to: "support@example.com",
        subject: "Delivered one",
        text: "x"
      )

      deliver(from: "bo@example.com", to: "bounce@example.com", subject: "Bounced one", text: "x")

      {:ok, view, html} = live(conn, "/dev/letterbox")
      assert html =~ "Delivered one"
      assert html =~ "Bounced one"

      html = view |> element("a", "bounced") |> render_click()
      assert html =~ "Bounced one"
      refute html =~ "Delivered one"
    end

    test "says what to do when there are none", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dev/letterbox")
      assert html =~ "No messages yet"
    end
  end

  test "an email written here goes to its mailbox, with its attachment", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/dev/letterbox/new")

    view
    |> file_input("form", :attachments, [
      %{name: "notes.txt", content: "the notes", type: "text/plain"}
    ])
    |> render_upload("notes.txt")

    {:error, {:live_redirect, %{to: to}}} =
      view
      |> form("form",
        email: %{
          from: "Ana <ana@example.com>",
          to: "support@example.com",
          subject: "Written here",
          text: "Hello"
        }
      )
      |> render_submit()

    {:ok, _view, html} = live(conn, to)

    assert html =~ "Written here"
    assert html =~ "delivered"
    assert html =~ "LetterboxTest.Recorder"
    assert html =~ "notes.txt"
    assert [%{ingress: "dev"}] = Letterbox.list()
  end

  describe "a message" do
    test "its HTML in a frame that runs nothing, its images in it", %{conn: conn} do
      inbound =
        deliver(
          to: "support@example.com",
          subject: "With HTML",
          text: "Plain",
          html: ~s(<p>Rich</p><img src="cid:logo"><img src="https://tracker.example/pixel.gif">),
          attachments: [
            %{name: "logo.png", content_type: "image/png", data: "PNG", content_id: "logo"}
          ]
        )

      {:ok, view, _html} = live(conn, "/dev/letterbox/#{inbound.id}")
      html = view |> element("button", "HTML") |> render_click()

      assert html =~ ~s(sandbox="")
      assert html =~ "default-src &#39;none&#39;; img-src data:"
      assert html =~ "data:image/png;base64," <> Base.encode64("PNG")
    end

    test "retried, and deleted", %{conn: conn} do
      inbound = deliver(to: "bounce@example.com", subject: "To retry", text: "x")
      {:ok, view, _html} = live(conn, "/dev/letterbox/#{inbound.id}")

      view |> element("button", "Retry") |> render_click()
      assert Letterbox.get(inbound.id).status == "bounced"

      view |> element("button", "Delete") |> render_click()
      assert Letterbox.get(inbound.id) == nil
    end

    test "one that is not there", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dev/letterbox/#{Ecto.UUID.generate()}")
      assert html =~ "This message is not here"
    end
  end

  describe "downloads" do
    setup do
      inbound =
        deliver(
          to: "support@example.com",
          text: "x",
          attachments: [
            %{name: "page.html", content_type: "text/html", data: "<script>alert(1)</script>"},
            %{name: "photo.jpg", content_type: "image/jpeg", data: "JPEG"}
          ]
        )

      %{inbound: inbound}
    end

    test "the raw email", %{conn: conn, inbound: inbound} do
      conn = get(conn, "/dev/letterbox/#{inbound.id}/raw")

      assert response(conn, 200) =~ "To: support@example.com"

      assert get_resp_header(conn, "content-disposition") == [
               ~s(attachment; filename="message.eml")
             ]
    end

    test "an attachment is downloaded, never shown as a page", %{conn: conn, inbound: inbound} do
      [html, _photo] =
        Enum.sort_by(
          Letterbox.message(inbound.id) |> elem(1) |> Map.fetch!(:attachments),
          & &1.name
        )

      index =
        Enum.find_index(
          elem(Letterbox.message(inbound.id), 1).attachments,
          &(&1.name == html.name)
        )

      conn = get(conn, "/dev/letterbox/#{inbound.id}/files/#{index}")

      assert response(conn, 200) == "<script>alert(1)</script>"
      assert get_resp_header(conn, "content-type") == ["application/octet-stream"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert [~s(attachment; filename="page.html")] = get_resp_header(conn, "content-disposition")
    end

    test "a missing one is a 404", %{conn: conn, inbound: inbound} do
      assert conn |> get("/dev/letterbox/#{inbound.id}/files/9") |> response(404)
    end
  end
end
