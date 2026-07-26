defmodule ChushutsuTest do
  use ExUnit.Case
  doctest Chushutsu

  test "greets the world" do
    assert Chushutsu.hello() == :world
  end
end
