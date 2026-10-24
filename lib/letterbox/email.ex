defmodule Letterbox.Email do
  @moduledoc """
  The email channel: a raw email as a `Letterbox.Message` (`parse/2`), and
  an email made from fields (`build/1`), for tests and the development
  page.
  """

  alias Letterbox.{Address, Attachment, Message, MIME, Text}
  alias Letterbox.MIME.Header

  @doc """
  Reads a raw email (RFC 5322, as a mail server took it).

  Options:

    * `:recipients` - the addresses the mail server took it for (its
      envelope's `RCPT TO`), when the ingress knows them. They are the
      message's `:recipients`; without them, its `To`, `Cc`,
      `Delivered-To` and `X-Original-To` are.
    * `:trusted_servers` - the `authserv-id`s of the mail servers the app
      trusts to check senders (its provider's, its own), whose
      `Authentication-Results` give the message's `:verified_from`. Only
      a server that removes the headers others wrote in its name should be
      trusted (RFC 8601, section 5). None by default: no sender is
      verified.
    * `:max_depth` and `:max_parts`, as `Letterbox.MIME.parse/2`'s.
  """
  @spec parse(binary(), keyword()) :: Message.t()
  def parse(raw, opts \\ []) when is_binary(raw) do
    mime = MIME.parse(raw, Keyword.take(opts, [:max_depth, :max_parts]))
    headers = mime.headers

    addresses = fn name ->
      headers |> Header.get_all(name) |> Enum.flat_map(&Address.parse_list/1)
    end

    from =
      Address.parse(Header.get(headers, "from")) || Address.parse(Header.get(headers, "sender"))

    {text, html, attachments, lossy} = bodies(mime)

    %Message{
      channel: :email,
      from: from,
      verified_from: verified(from, headers, Keyword.get(opts, :trusted_servers, [])),
      to: addresses.("to"),
      cc: addresses.("cc"),
      bcc: addresses.("bcc"),
      reply_to: addresses.("reply-to"),
      recipients: recipients(opts[:recipients], headers, addresses),
      subject: headers |> Header.get("subject") |> Header.decode(),
      text: text,
      html: html,
      attachments: attachments,
      file_links: file_links(text, html),
      sent_at: headers |> Header.get("date") |> date(),
      message_id: headers |> Header.get("message-id") |> ids() |> List.first(),
      in_reply_to: headers |> Header.get("in-reply-to") |> ids(),
      references: headers |> Header.get("references") |> ids(),
      headers: headers,
      lossy: lossy,
      mime: mime,
      raw: raw
    }
  end

  defp recipients([_ | _] = envelope, _headers, _addresses),
    do:
      Enum.flat_map(envelope, &Address.parse_list/1) |> Enum.uniq_by(&String.downcase(&1.address))

  defp recipients(_none, _headers, addresses) do
    ["to", "cc", "delivered-to", "x-original-to"]
    |> Enum.flat_map(addresses)
    |> Enum.uniq_by(&String.downcase(&1.address))
  end

  # The body's text and HTML, and the rest as attachments. The texts are
  # the parts that are text/plain or text/html, not attached (no
  # `attachment` disposition, no file name); several (Apple Mail's text,
  # photograph, text) are joined. A file is inline when the HTML shows it.
  defp bodies(mime) do
    leaves = MIME.leaves(mime)
    {texts, rest} = Enum.split_with(leaves, &body?(&1, "text/plain"))
    {htmls, rest} = Enum.split_with(rest, &body?(&1, "text/html"))

    {text, text_lossy} = joined(texts)
    {html, html_lossy} = joined(Enum.take(htmls, 1))
    cids = if html, do: cids(html), else: MapSet.new()

    attachments =
      rest
      |> Enum.reject(&empty_multipart?/1)
      |> Enum.map(
        &Attachment.new(&1, &1.content_id != nil and MapSet.member?(cids, &1.content_id))
      )

    text = text || if(html, do: Text.from_html(html))
    {text, html, attachments, text_lossy or html_lossy}
  end

  defp body?(%MIME{type: type} = part, type),
    do:
      part.disposition != "attachment" and part.disposition_params["filename"] == nil and
        part.params["name"] == nil

  defp body?(_part, _type), do: false

  defp empty_multipart?(%MIME{type: "multipart/" <> _, body: body}), do: String.trim(body) == ""
  defp empty_multipart?(_part), do: false

  defp joined([]), do: {nil, false}

  defp joined(parts) do
    results = Enum.map(parts, &MIME.text/1)
    text = results |> Enum.map(&elem(&1, 1)) |> Enum.reject(&(&1 == "")) |> Enum.join("\n")
    {text, Enum.any?(results, &match?({:lossy, _}, &1))}
  end

  defp cids(html) do
    ~r/cid:([^"'\s>)]+)/i
    |> Regex.scan(html, capture: :all_but_first)
    |> Enum.map(fn [id] -> URI.decode(id) end)
    |> MapSet.new()
  end

  @file_links [
    mail_drop: ~r{https://www\.icloud\.com/attachment/\?[^\s"'<>]+},
    google_drive: ~r{https://(?:drive|docs)\.google\.com/[^\s"'<>]+},
    onedrive: ~r{https://(?:1drv\.ms|onedrive\.live\.com|[\w-]+\.sharepoint\.com)/[^\s"'<>]+},
    dropbox: ~r{https://(?:www\.)?dropbox\.com/(?:s|scl|sh)/[^\s"'<>]+},
    wetransfer: ~r{https://(?:we\.tl|wetransfer\.com/downloads)/[^\s"'<>]+}
  ]

  defp file_links(text, html) do
    content = Enum.join([text || "", html || ""], "\n")

    for {service, pattern} <- @file_links,
        [url] <- Regex.scan(pattern, content),
        url = url |> String.replace("&amp;", "&") |> String.trim_trailing("."),
        uniq: true,
        do: %{url: url, service: service}
  end

  # `<a@x> <b@y>`, or ids written with no brackets.
  defp ids(nil), do: []

  defp ids(value) do
    case Regex.scan(~r/<([^<>\s]+)>/, value, capture: :all_but_first) do
      [] -> value |> String.split() |> Enum.filter(&String.contains?(&1, "@"))
      ids -> Enum.map(ids, fn [id] -> id end)
    end
  end

  # The From is verified when the first Authentication-Results of a trusted
  # server says its domain passed DMARC, or DKIM (header.d) or SPF
  # (smtp.mailfrom) for that domain or one above it.
  defp verified(nil, _headers, _trusted), do: nil
  defp verified(_from, _headers, []), do: nil

  defp verified(%Address{} = from, headers, trusted) do
    trusted = Enum.map(trusted, &String.downcase/1)
    domain = Address.domain(from)

    results =
      headers
      |> Header.get_all("authentication-results")
      |> Enum.find(fn value -> authserv_id(value) in trusted end)

    if results && passed?(results, domain), do: from
  end

  defp authserv_id(value),
    do:
      value |> String.split(";") |> hd() |> String.split() |> List.first("") |> String.downcase()

  defp passed?(results, domain) do
    methods = results |> String.split(";") |> tl() |> Enum.map(&String.downcase/1)

    Enum.any?(methods, fn method ->
      cond do
        method =~ ~r/\bdmarc=pass\b/ -> aligned?(property(method, "header.from"), domain)
        method =~ ~r/\bdkim=pass\b/ -> aligned?(property(method, "header.d"), domain)
        method =~ ~r/\bspf=pass\b/ -> aligned?(property(method, "smtp.mailfrom"), domain)
        true -> false
      end
    end)
  end

  defp property(method, name) do
    case Regex.run(~r/\b#{Regex.escape(name)}=([^\s;]+)/, method, capture: :all_but_first) do
      [value] -> value |> String.split("@") |> List.last() |> String.trim("\"")
      nil -> nil
    end
  end

  defp aligned?(nil, _domain), do: false

  defp aligned?(checked, domain),
    do: domain == checked or String.ends_with?(domain, "." <> checked)

  @months ~w(jan feb mar apr may jun jul aug sep oct nov dec)

  @zones %{
    "ut" => 0,
    "utc" => 0,
    "gmt" => 0,
    "z" => 0,
    "est" => -500,
    "edt" => -400,
    "cst" => -600,
    "cdt" => -500,
    "mst" => -700,
    "mdt" => -600,
    "pst" => -800,
    "pdt" => -700
  }

  @doc false
  # RFC 5322's date (`Tue, 21 Oct 2026 10:00:00 +0100`) in UTC, as clients
  # write it: with or without the day's name and the seconds, a year of two
  # digits, a zone's name, a comment after it. nil when it is not one.
  @spec date(String.t() | nil) :: DateTime.t() | nil
  def date(nil), do: nil

  def date(value) do
    value = value |> String.replace(~r/\(.*?\)/, "") |> String.downcase()

    with [_all, day, month, year, hour, minute, second, zone] <-
           Regex.run(
             ~r/(\d{1,2})\s+([a-z]{3})[a-z]*\s+(\d{2,4})\s+(\d{1,2}):(\d{2})(?::(\d{2}))?\s*([+-]\d{4}|[a-z]+)?/,
             value
           ),
         month when is_integer(month) <- Enum.find_index(@months, &(&1 == month)),
         {:ok, naive} <-
           NaiveDateTime.new(
             year(String.to_integer(year)),
             month + 1,
             String.to_integer(day),
             String.to_integer(hour),
             String.to_integer(minute),
             if(second == "", do: 0, else: String.to_integer(second))
           ),
         {:ok, offset} <- offset(zone) do
      naive |> NaiveDateTime.add(-offset, :second) |> DateTime.from_naive!("Etc/UTC")
    else
      _other -> nil
    end
  end

  defp year(year) when year < 50, do: 2000 + year
  defp year(year) when year < 100, do: 1900 + year
  defp year(year), do: year

  defp offset(nil), do: {:ok, 0}
  defp offset(""), do: {:ok, 0}

  defp offset(<<sign, hours::binary-size(2), minutes::binary-size(2)>>) when sign in [?+, ?-] do
    seconds = String.to_integer(hours) * 3600 + String.to_integer(minutes) * 60
    {:ok, if(sign == ?-, do: -seconds, else: seconds)}
  end

  defp offset(name) do
    case Map.fetch(@zones, name) do
      {:ok, hhmm} -> {:ok, div(hhmm, 100) * 3600}
      :error -> {:ok, 0}
    end
  end

  @doc """
  An email made from fields, as a mail client would write it: for tests,
  the development page, and an app's own ingress.

      Letterbox.Email.build(
        from: "José Martínez <jose@example.com>",
        to: "photos+abc123@in.example.com",
        subject: "Férias",
        text: "Here they are.",
        attachments: [%{name: "praia.jpg", content_type: "image/jpeg", data: jpeg}]
      )

  Fields: `:from`, `:to`, `:cc`, `:reply_to` (an address or a list of
  them, as strings or `Letterbox.Address`), `:subject`, `:text`, `:html`,
  `:attachments` (maps or keywords of `:name`, `:content_type`, `:data`,
  and `:content_id` for one the HTML shows), `:message_id`,
  `:in_reply_to`, `:references`, `:date` (a `DateTime`, now by default),
  and `:headers`, a list of `{name, value}` more.
  """
  @spec build(keyword()) :: binary()
  def build(fields) do
    boundary = fn -> "letterbox-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower) end
    attachments = fields |> Keyword.get(:attachments, []) |> Enum.map(&Map.new/1)
    {inline, attached} = Enum.split_with(attachments, &Map.get(&1, :content_id))

    body = attach(body(fields, inline, boundary), attached, boundary)

    head =
      for {name, value} <- headers(fields), value != nil, into: "", do: "#{name}: #{value}\r\n"

    head <> body
  end

  defp body(fields, inline, boundary) do
    case {fields[:text], fields[:html]} do
      {text, nil} ->
        text_part("text/plain", text || "")

      {nil, html} ->
        related(text_part("text/html", html), inline, boundary)

      {text, html} ->
        multipart(
          "alternative",
          [
            text_part("text/plain", text),
            related(text_part("text/html", html), inline, boundary)
          ],
          boundary.()
        )
    end
  end

  defp attach(body, [], _boundary), do: body

  defp attach(body, attached, boundary),
    do: multipart("mixed", [body | Enum.map(attached, &file_part/1)], boundary.())

  defp headers(fields) do
    [
      {"From", optional(fields[:from], &addresses/1)},
      {"To", optional(fields[:to], &addresses/1)},
      {"Cc", optional(fields[:cc], &addresses/1)},
      {"Reply-To", optional(fields[:reply_to], &addresses/1)},
      {"Subject", optional(fields[:subject], &encode_header/1)},
      {"Date", date_header(fields[:date] || DateTime.utc_now())},
      {"Message-ID", "<" <> (fields[:message_id] || generated_id(fields[:from])) <> ">"},
      {"In-Reply-To", optional(fields[:in_reply_to], &id_list/1)},
      {"References", optional(fields[:references], &id_list/1)},
      {"MIME-Version", "1.0"}
    ] ++ Keyword.get(fields, :headers, [])
  end

  defp optional(nil, _fun), do: nil
  defp optional(value, fun), do: fun.(value)

  defp related(html_part, [], _boundary), do: html_part

  defp related(html_part, inline, boundary),
    do: multipart("related", [html_part | Enum.map(inline, &file_part/1)], boundary.())

  defp multipart(subtype, parts, boundary) do
    "Content-Type: multipart/#{subtype}; boundary=\"#{boundary}\"\r\n\r\n" <>
      Enum.map_join(parts, "", &"--#{boundary}\r\n#{&1}\r\n") <> "--#{boundary}--\r\n"
  end

  defp text_part(type, text) do
    "Content-Type: #{type}; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n" <>
      quoted_printable(text)
  end

  defp file_part(%{} = file) do
    name = Map.get(file, :name, "attachment")
    type = Map.get(file, :content_type, "application/octet-stream")
    disposition = if Map.get(file, :content_id), do: "inline", else: "attachment"

    "Content-Type: #{type}; name=\"#{encode_param(name)}\"\r\n" <>
      "Content-Disposition: #{disposition}; filename=\"#{encode_param(name)}\"\r\n" <>
      if(file[:content_id], do: "Content-ID: <#{file.content_id}>\r\n", else: "") <>
      "Content-Transfer-Encoding: base64\r\n\r\n" <> base64_lines(Map.fetch!(file, :data))
  end

  defp base64_lines(data) do
    data
    |> Base.encode64()
    |> chunks(76)
    |> Enum.join("\r\n")
  end

  defp chunks(text, size) when byte_size(text) <= size, do: [text]

  defp chunks(text, size) do
    <<chunk::binary-size(^size), rest::binary>> = text
    [chunk | chunks(rest, size)]
  end

  defp addresses(list) when is_list(list), do: Enum.map_join(list, ", ", &address/1)
  defp addresses(one), do: address(one)

  defp address(%Address{name: nil, address: address}), do: address
  defp address(%Address{name: name, address: address}), do: "#{encode_header(name)} <#{address}>"

  defp address(text) when is_binary(text) do
    case Address.parse(text) do
      nil -> text
      parsed -> address(parsed)
    end
  end

  defp id_list(ids) when is_list(ids), do: Enum.map_join(ids, " ", &"<#{&1}>")
  defp id_list(id), do: "<#{id}>"

  defp generated_id(from) do
    domain =
      case from && Address.parse(addresses(from)) do
        %Address{} = address -> Address.domain(address)
        nil -> "letterbox.local"
      end

    Base.encode16(:crypto.strong_rand_bytes(12), case: :lower) <> "@" <> domain
  end

  defp date_header(%DateTime{} = date), do: Calendar.strftime(date, "%a, %d %b %Y %H:%M:%S +0000")

  # A header's text: as it is in ASCII, else one encoded word (RFC 2047) of
  # UTF-8 in Base64.
  defp encode_header(text) do
    if ascii?(text) and not String.contains?(text, ["\r", "\n"]),
      do: text,
      else: "=?utf-8?B?" <> Base.encode64(text) <> "?="
  end

  defp encode_param(name), do: name |> encode_header() |> String.replace("\"", "'")

  defp ascii?(text), do: for(<<c <- text>>, reduce: true, do: (ok -> ok and c in 32..126))

  defp quoted_printable(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.split("\n")
    |> Enum.map_join("\r\n", &qp_line/1)
  end

  defp qp_line(line) do
    encoded =
      for <<c <- line>>, into: "" do
        if (c in 33..126 and c != ?=) or c == ?\s, do: <<c>>, else: "=" <> Base.encode16(<<c>>)
      end

    encoded
    |> String.replace(~r/ $/, "=20")
    |> soft_breaks()
  end

  # Lines of at most 76 characters, broken with `=` where an `=XX` is not
  # cut.
  defp soft_breaks(line) when byte_size(line) <= 76, do: line

  defp soft_breaks(line) do
    cut =
      case binary_part(line, 73, 2) do
        <<?=, _>> -> 73
        <<_, ?=>> -> 74
        _ -> 75
      end

    binary_part(line, 0, cut) <>
      "=\r\n" <> soft_breaks(binary_part(line, cut, byte_size(line) - cut))
  end
end
