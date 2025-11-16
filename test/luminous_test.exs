defmodule LuminousTest do
  use ExUnit.Case
  doctest Luminous

  test "greets the world" do
    assert Luminous.hello() == :world
  end
end
