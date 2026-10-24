defmodule Letterbox.AddressTest do
  use ExUnit.Case, async: true

  alias Letterbox.Address

  test "lists as clients write them" do
    assert Address.parse_list(
             ~s|"Martínez, José" <jose+photos@Example.COM>, ana@example.com (Ana B), Team: c@x.org, d@x.org;|
           ) ==
             [
               %Address{name: "Martínez, José", address: "jose+photos@example.com"},
               %Address{name: "Ana B", address: "ana@example.com"},
               %Address{name: nil, address: "c@x.org"},
               %Address{name: nil, address: "d@x.org"}
             ]
  end

  test "an empty group and things that are not addresses are left out" do
    assert Address.parse_list("undisclosed-recipients:;") == []
    assert Address.parse_list("not an address, also@") == []
  end

  test "encoded names" do
    assert %Address{name: "José"} = Address.parse("=?utf-8?Q?Jos=C3=A9?= <jose@example.com>")
  end

  test "sub-addresses" do
    address = Address.parse("Site+AbC123@In.Example.com")

    assert Address.tag(address) == "AbC123"
    assert Address.base(address) == "site@in.example.com"
    assert Address.matches?(address, "site@in.example.com")
    assert Address.matches?(address, "SITE+abc123@in.example.com")
    refute Address.matches?(address, "other@in.example.com")
  end

  test "as a string" do
    assert to_string(%Address{name: "Ana", address: "a@x"}) == "Ana <a@x>"

    assert to_string(%Address{name: ~s(Martínez, "J"), address: "j@x"}) ==
             ~s("Martínez, \\"J\\"" <j@x>)
  end
end
