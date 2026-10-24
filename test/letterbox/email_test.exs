defmodule Letterbox.EmailTest do
  use ExUnit.Case, async: true

  alias Letterbox.{Address, Attachment, Charset, Email}

  describe "parse/2" do
    test "the hard email" do
      message = Email.parse(File.read!("test/fixtures/hard.eml"))

      assert message.from == %Address{name: "José Martínez", address: "jose@example.com"}
      assert message.subject == "Férias no Algarve and more"
      assert message.text == "Olá, aqui estão as fotos € 100."
      assert message.html =~ "cid:logo1"
      assert message.message_id == "a1@example.com"
      refute message.lossy

      assert [
               %Attachment{name: nil, inline?: true},
               %Attachment{name: "praia à tarde.jpg", inline?: false}
             ] =
               message.attachments

      assert [%Attachment{name: "praia à tarde.jpg"}] = Letterbox.Message.files(message)
    end

    test "Apple Mail's text, photograph, text: the texts joined, the photograph attached" do
      raw =
        "From: a@example.com\r\nContent-Type: multipart/mixed; boundary=m\r\n\r\n" <>
          "--m\r\nContent-Type: text/plain\r\n\r\nBefore\r\n" <>
          "--m\r\nContent-Type: image/jpeg; name=IMG_1.jpg\r\nContent-Disposition: inline; filename=IMG_1.jpg\r\nContent-Transfer-Encoding: base64\r\n\r\n/9j/\r\n" <>
          "--m\r\nContent-Type: text/plain\r\n\r\nAfter\r\n--m--\r\n"

      message = Email.parse(raw)

      assert message.text == "Before\nAfter"
      assert [%Attachment{name: "IMG_1.jpg", inline?: false}] = message.attachments
    end

    test "text from the HTML when there is no plain text" do
      raw =
        "Content-Type: text/html\r\n\r\n<html><head><style>p{}</style></head><body><p>One&nbsp;&amp; two</p><p>Three<br>four</p></body></html>"

      assert Email.parse(raw).text == "One & two\n\nThree\nfour"
    end

    test "recipients: the envelope's when given, else To, Cc, Delivered-To and X-Original-To" do
      raw =
        "To: a@example.com\r\nCc: B <b@example.com>\r\nDelivered-To: a@example.com\r\nX-Original-To: c@example.com\r\n\r\nx"

      assert raw |> Email.parse() |> Map.fetch!(:recipients) |> Enum.map(& &1.address) ==
               ["a@example.com", "b@example.com", "c@example.com"]

      assert raw |> Email.parse(recipients: ["hidden@example.com"]) |> Map.fetch!(:recipients) ==
               [%Address{address: "hidden@example.com"}]
    end

    test "threads: Message-ID, In-Reply-To and References without brackets" do
      raw = "Message-ID: <m3@x>\r\nIn-Reply-To: <m2@x>\r\nReferences: <m1@x>\r\n  <m2@x>\r\n\r\nx"
      message = Email.parse(raw)

      assert {message.message_id, message.in_reply_to, message.references} ==
               {"m3@x", ["m2@x"], ["m1@x", "m2@x"]}
    end

    test "dates, as clients write them" do
      assert Email.date("Tue, 21 Oct 2026 10:00:00 +0100") == ~U[2026-10-21 09:00:00Z]
      assert Email.date("21 Oct 26 10:00 GMT") == ~U[2026-10-21 10:00:00Z]
      assert Email.date("Tue, 21 Oct 2026 10:00:00 -0500 (EST)") == ~U[2026-10-21 15:00:00Z]
      assert Email.date("not a date") == nil
    end

    test "links to files sent another way" do
      raw =
        "Content-Type: text/plain\r\n\r\nThe photos: https://www.icloud.com/attachment/?u=https%3A%2F%2Fcvws&uk=abc and " <>
          "https://drive.google.com/file/d/1aBc/view."

      assert [
               %{service: :mail_drop},
               %{service: :google_drive, url: "https://drive.google.com/file/d/1aBc/view"}
             ] =
               Email.parse(raw).file_links
    end
  end

  describe "verified senders" do
    @raw "Authentication-Results: mx.trusted.example; dkim=pass header.d=example.com; dmarc=pass header.from=example.com\r\n" <>
           "From: Ana <ana@example.com>\r\n\r\nHello"

    test "the From, when a trusted server says its domain passed" do
      assert %Address{address: "ana@example.com"} =
               Email.parse(@raw, trusted_servers: ["mx.trusted.example"]).verified_from
    end

    test "none without a trusted server, or from another one" do
      assert Email.parse(@raw).verified_from == nil
      assert Email.parse(@raw, trusted_servers: ["mx.other.example"]).verified_from == nil
    end

    test "none when what passed is another domain" do
      raw = String.replace(@raw, "From: Ana <ana@example.com>", "From: Ana <ana@bank.example>")
      assert Email.parse(raw, trusted_servers: ["mx.trusted.example"]).verified_from == nil
    end
  end

  describe "build/1" do
    test "reads back as it was written" do
      photo = :crypto.strong_rand_bytes(20_000)

      raw =
        Email.build(
          from: "José Martínez <jose@example.com>",
          to: ["photos+abc123@in.example.com", "Ana <ana@example.com>"],
          subject: "Férias — 2026",
          text: "Olá. " <> String.duplicate("long line ", 30),
          html: "<p>Olá</p><img src=\"cid:logo\">",
          attachments: [
            %{name: "praia à tarde.jpg", content_type: "image/jpeg", data: photo},
            %{name: "logo.png", content_type: "image/png", data: "PNG", content_id: "logo"}
          ],
          in_reply_to: "m1@example.com"
        )

      message = Email.parse(raw)

      assert message.from.name == "José Martínez"

      assert Enum.map(message.to, & &1.address) == [
               "photos+abc123@in.example.com",
               "ana@example.com"
             ]

      assert message.subject == "Férias — 2026"
      assert message.text == "Olá. " <> String.duplicate("long line ", 30)
      assert message.in_reply_to == ["m1@example.com"]

      [logo, jpeg] = Enum.sort_by(message.attachments, & &1.name)
      assert {logo.name, logo.inline?, Attachment.read(logo)} == {"logo.png", true, "PNG"}
      assert {jpeg.name, Attachment.read(jpeg)} == {"praia à tarde.jpg", photo}
    end
  end

  describe "attachments" do
    test "saved to a file as they are decoded, with their size and checksum" do
      data = :crypto.strong_rand_bytes(300_000)

      raw =
        Email.build(
          text: "x",
          attachments: [%{name: "a.bin", content_type: "application/octet-stream", data: data}]
        )

      [attachment] = Email.parse(raw).attachments
      path = Path.join(System.tmp_dir!(), "letterbox-test-#{System.unique_integer([:positive])}")

      assert {:ok, %{bytes: 300_000, checksum: checksum}} = Attachment.save(attachment, path)
      assert File.read!(path) == data
      assert checksum == Base.encode64(:crypto.hash(:sha256, data))
      File.rm!(path)
    end

    test "past :max_bytes, nothing is left" do
      raw =
        Email.build(
          text: "x",
          attachments: [%{name: "a.bin", data: :crypto.strong_rand_bytes(5_000)}]
        )

      [attachment] = Email.parse(raw).attachments
      path = Path.join(System.tmp_dir!(), "letterbox-test-#{System.unique_integer([:positive])}")

      assert Attachment.save(attachment, path, max_bytes: 1_000) == {:error, :too_large}
      refute File.exists?(path)
    end
  end

  describe "charsets" do
    test "WHATWG's: Latin-1 is Windows-1252, and the others by their labels" do
      assert Charset.decode(<<0x93, ?a, 0x94>>, "ISO-8859-1") == {:ok, "“a”"}
      assert Charset.decode(<<0xC7, 0xE8>>, "koi8-r") == {:ok, "гХ"}
      assert Charset.decode(<<0xE0>>, "windows-1251") == {:ok, "а"}
    end

    test "invalid UTF-8 and unknown charsets are lossy, never invalid" do
      assert {:lossy, text} = Charset.decode(<<"ok ", 0xFF, " ok">>, "utf-8")
      assert text == "ok � ok"
      assert {:lossy, "�"} = Charset.decode(<<0x82, 0xA0>>, "shift_jis")
    end
  end
end
