defmodule Letterbox.MIMETest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Letterbox.MIME
  alias Letterbox.MIME.Header

  describe "headers" do
    test "are unfolded, in their order, with names in lowercase" do
      headers =
        Header.parse("Subject: a long\r\n subject\r\nX-One: 1\r\nx-one: 2\r\nnot a header\r\n")

      assert headers == [{"subject", "a long subject"}, {"x-one", "1"}, {"x-one", "2"}]
      assert Header.get_all(headers, "x-one") == ["1", "2"]
    end

    test "encoded words are decoded, and the space between two goes" do
      assert Header.decode("=?UTF-8?Q?Jos=C3=A9?= =?UTF-8?Q?_Mart=C3=ADnez?=") == "José Martínez"
      assert Header.decode("=?iso-8859-1?q?F=E9rias?= no Algarve") == "Férias no Algarve"
      assert Header.decode("Re: =?utf-8?B?w6l0w6k=?=") == "Re: été"
    end

    test "a character whose bytes are split across two words is whole" do
      # "ção" in UTF-8 is c3 a7 c3 a3 6f; the encoder cut it after c3.
      assert Header.decode("=?utf-8?B?w6fD?= =?utf-8?B?o28=?=") == "ção"
    end

    test "raw UTF-8 in a header is kept, and raw Latin-1 is read as Windows-1252" do
      assert Header.decode("Olá") == "Olá"
      assert Header.decode(<<"Ol", 0xE1, " ", 0x80>>) == "Olá €"
    end

    test "a parameter of RFC 2231, in one piece and in several" do
      {type, params} = Header.params("attachment; filename*=utf-8''praia%20%C3%A0%20tarde.jpg")
      assert type == "attachment"
      assert params["filename"] == "praia à tarde.jpg"

      {_type, params} =
        Header.params(
          ~s(attachment; filename*0*=iso-8859-1''f%E9rias; filename*1="-2026"; filename*2*=.jpg)
        )

      assert params["filename"] == "férias-2026.jpg"
    end

    test "encoded words in a quoted parameter, as Outlook writes them" do
      {"image/jpeg", params} = Header.params(~s(image/jpeg; name="=?utf-8?B?cHJhaWEuanBn?="))
      assert params["name"] == "praia.jpg"
    end

    test "a semicolon in quotes does not end a parameter" do
      {_type, params} = Header.params(~s(attachment; filename="a;b.txt"; size=3))
      assert params == %{"filename" => "a;b.txt", "size" => "3"}
    end
  end

  describe "structure" do
    test "the hard email: alternative text and HTML, an inline image, an attachment" do
      root = MIME.parse(File.read!("test/fixtures/hard.eml"))

      assert root.type == "multipart/mixed"

      assert [
               %{type: "text/plain", path: [0, 0]},
               %{type: "text/html", path: [0, 1]},
               %{type: "image/png", content_id: "logo1", disposition: "inline"},
               %{type: "image/jpeg", disposition: "attachment"} = photo
             ] = MIME.leaves(root)

      assert photo.disposition_params["filename"] == "praia à tarde.jpg"
      assert MIME.decode(photo) == Base.decode64!("/9j/4AAQSkZJRg==")
    end

    test "bodies are sub-binaries of the email: nothing is copied" do
      # (Erlang copies a sub-binary under 64 bytes, which is cheaper: the
      # photograph is larger.)
      photo = :crypto.strong_rand_bytes(10_000)
      raw = Letterbox.Email.build(text: "x", attachments: [%{name: "p.jpg", data: photo}])
      [_text, part] = raw |> MIME.parse() |> MIME.leaves()

      assert :binary.referenced_byte_size(part.body) == byte_size(raw)
    end

    test "line breaks of LF only, and a multipart with no closing boundary" do
      raw = """
      Content-Type: multipart/mixed; boundary=b

      --b
      Content-Type: text/plain

      one
      --b
      Content-Type: text/plain

      two
      """

      assert [%{body: "one"}, %{body: "two\n"}] = raw |> MIME.parse() |> MIME.leaves()
    end

    test "a preamble and an epilogue are not parts" do
      raw =
        "Content-Type: multipart/mixed; boundary=\"x\"\r\n\r\npreamble\r\n--x\r\n\r\nbody\r\n--x--\r\nepilogue"

      assert [%{type: "text/plain", body: "body"}] = raw |> MIME.parse() |> MIME.leaves()
    end

    test "a boundary that starts another one does not split it" do
      raw =
        "Content-Type: multipart/mixed; boundary=a\r\n\r\n--a\r\nContent-Type: multipart/alternative; boundary=ab\r\n\r\n" <>
          "--ab\r\n\r\nin\r\n--ab--\r\n--a--\r\n"

      assert [%{body: "in"}] = raw |> MIME.parse() |> MIME.leaves()
    end

    test "a forwarded email is a part, with the email's parts in it" do
      raw =
        "Content-Type: multipart/mixed; boundary=a\r\n\r\n--a\r\n\r\nSee below.\r\n--a\r\n" <>
          "Content-Type: message/rfc822\r\n\r\nSubject: Inner\r\n\r\nInner body\r\n--a--\r\n"

      [_text, forwarded] = raw |> MIME.parse() |> MIME.leaves()

      assert forwarded.type == "message/rfc822"
      assert [%{headers: [{"subject", "Inner"}], body: "Inner body"}] = forwarded.parts
    end

    test "an email with no headers is all body, and a part with none is text/plain" do
      assert %MIME{type: "text/plain", body: "just text"} = MIME.parse("just text")
    end

    test "past the limits, a multipart is not split" do
      nested =
        Enum.reduce(1..30, "deep", fn i, inner ->
          "Content-Type: multipart/mixed; boundary=b#{i}\r\n\r\n--b#{i}\r\n#{inner}\r\n--b#{i}--\r\n"
        end)

      depth = fn depth, part ->
        if part.parts == [], do: 0, else: 1 + depth.(depth, hd(part.parts))
      end

      assert depth.(depth, MIME.parse(nested, max_depth: 5)) == 5
    end
  end

  describe "transfer encodings" do
    test "quoted-printable: escapes, soft line breaks, a stray =" do
      assert MIME.quoted_printable("Ol=E1, =\r\nsoft = stray=3D") == "Ol\xE1, soft = stray="
    end

    test "Base64 with line breaks and stray characters" do
      part = %MIME{encoding: "base64", body: "SGVs\r\nbG8s\r\n IHdv*cmxk"}
      assert MIME.decode(part) == "Hello, world"
    end

    property "Base64 streamed in chunks of any size is the same bytes" do
      check all(
              bytes <- binary(max_length: 4_000),
              chunk <- integer(1..300),
              width <- integer(4..120)
            ) do
        encoded = bytes |> Base.encode64() |> wrap(width)
        part = %MIME{encoding: "base64", body: encoded}

        assert part |> MIME.stream(chunk: chunk) |> Enum.join() == bytes
        assert MIME.decode(part) == bytes
      end
    end

    property "quoted-printable streamed in chunks of any size is the same text" do
      check all(text <- string(:printable, max_length: 2_000), chunk <- integer(1..200)) do
        encoded = Letterbox.Email.build(text: text) |> MIME.parse() |> Map.fetch!(:body)
        part = %MIME{encoding: "quoted-printable", body: encoded}

        assert part |> MIME.stream(chunk: chunk) |> Enum.join() == MIME.decode(part)
      end
    end
  end

  defp wrap(text, width) do
    text
    |> String.graphemes()
    |> Enum.chunk_every(width)
    |> Enum.map_join("\r\n", &Enum.join/1)
  end
end
