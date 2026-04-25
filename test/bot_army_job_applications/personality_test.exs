defmodule BotArmyJobApplications.PersonalityTest do
  use ExUnit.Case
  @moduletag :core
  doctest BotArmyJobApplications.Personality

  alias BotArmyJobApplications.Personality

  describe "system_prompt/0" do
    test "returns a non-empty system prompt" do
      prompt = Personality.system_prompt()
      assert is_binary(prompt)
      assert String.length(prompt) > 100
    end

    test "includes bot symbol in prompt" do
      prompt = Personality.system_prompt()
      assert String.contains?(prompt, "◆")
    end

    test "includes role description" do
      prompt = Personality.system_prompt()
      assert String.contains?(prompt, "ruthless career strategist")
    end

    test "includes voice principles" do
      prompt = Personality.system_prompt()
      assert String.contains?(prompt, "Direct")
      assert String.contains?(prompt, "Confident")
      assert String.contains?(prompt, "Strategic")
    end

    test "includes example messages" do
      prompt = Personality.system_prompt()
      assert String.contains?(prompt, "L4 transition")
    end
  end

  describe "symbol/0" do
    test "returns Job bot symbol" do
      assert Personality.symbol() == "◆"
    end
  end
end
