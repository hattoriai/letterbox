defmodule Letterbox.RoutingTest do
  use ExUnit.Case, async: true

  import Letterbox.Test

  test "an address, with or without a sub-address, in any case" do
    assert mailbox_for(to: "Support@Example.com") == {:ok, LetterboxTest.Recorder}
    assert mailbox_for(to: "support+urgent@example.com") == {:ok, LetterboxTest.Recorder}
  end

  test "a local part at any domain, a regex, a domain" do
    assert mailbox_for(to: "photos@in.example.com") == {:ok, LetterboxTest.Photos}
    assert mailbox_for(to: "reply+t0k3n@example.com") == {:ok, LetterboxTest.Recorder}
    assert mailbox_for(to: "anyone@sites.example.com") == {:ok, LetterboxTest.Recorder}
  end

  test "nothing takes an address no route has" do
    assert mailbox_for(to: "nobody@example.com") == :none
  end

  test "the first route that matches any recipient, and the recipient it matched" do
    message = message(to: "nobody@example.com", cc: "photos+abc@in.example.com")

    assert {:ok, LetterboxTest.Photos, recipient} =
             Letterbox.Routing.match(LetterboxTest.Mailboxes, message)

    assert recipient.address == "photos+abc@in.example.com"
  end

  test "functions and :all" do
    defmodule Everything do
      use Letterbox.Routing
      route(&String.contains?(&1.subject || "", "urgent"), to: Urgent)
      route(:all, to: Rest)
    end

    assert mailbox_for([to: "a@x.org", subject: "urgent!"], routing: Everything) == {:ok, Urgent}
    assert mailbox_for([to: "a@x.org", subject: "later"], routing: Everything) == {:ok, Rest}
  end
end
