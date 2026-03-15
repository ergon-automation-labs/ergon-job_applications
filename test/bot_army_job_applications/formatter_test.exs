defmodule BotArmyJobApplications.FormatterTest do
  use ExUnit.Case
  doctest BotArmyJobApplications.Formatter

  alias BotArmyJobApplications.Formatter

  describe "format/2" do
    test "opportunity_discovered with title and company" do
      result = Formatter.format(:opportunity_discovered, %{
        "title" => "Senior Engineer",
        "company" => "Acme Corp"
      })

      assert result == "◆ Senior Engineer at Acme Corp just hit your filter. This one's worth your time."
    end

    test "application_submitted" do
      result = Formatter.format(:application_submitted, %{
        "title" => "Staff Engineer",
        "company" => "TechCo"
      })

      assert result == "◆ Application sent: Staff Engineer at TechCo. One down."
    end

    test "interview_scheduled" do
      result = Formatter.format(:interview_scheduled, %{
        "title" => "Principal Engineer",
        "company" => "FutureTech",
        "date" => "2026-04-01"
      })

      assert result == "◆ Interview locked: Principal Engineer at FutureTech on 2026-04-01. You've got this."
    end

    test "interview_feedback" do
      result = Formatter.format(:interview_feedback, %{
        "title" => "VP Engineering",
        "feedback" => "Strong technical depth, good communication"
      })

      assert result == "◆ Interview notes for VP Engineering: Strong technical depth, good communication"
    end

    test "offer_received" do
      result = Formatter.format(:offer_received, %{
        "title" => "CTO",
        "company" => "StartupXYZ"
      })

      assert result == "◆ Offer from StartupXYZ for CTO. We'll talk numbers."
    end

    test "rejection" do
      result = Formatter.format(:rejection, %{
        "title" => "Senior Backend Engineer",
        "company" => "OldCo"
      })

      assert result == "◆ OldCo passed on Senior Backend Engineer. Check. Next."
    end

    test "error" do
      result = Formatter.format(:error, %{"message" => "LinkedIn connection failed"})
      assert result == "◆ Something went wrong: LinkedIn connection failed"
    end

    test "unknown type returns default message with symbol" do
      result = Formatter.format(:unknown_type, %{})
      assert result == "◆ Something happened."
    end

    test "all formatted messages include the symbol" do
      messages = [
        Formatter.format(:opportunity_discovered, %{"title" => "Role", "company" => "Corp"}),
        Formatter.format(:application_submitted, %{"title" => "Role", "company" => "Corp"}),
        Formatter.format(:interview_scheduled, %{"title" => "Role", "company" => "Corp", "date" => "2026-04-01"}),
        Formatter.format(:offer_received, %{"title" => "Role", "company" => "Corp"}),
        Formatter.format(:rejection, %{"title" => "Role", "company" => "Corp"}),
        Formatter.format(:error, %{"message" => "Test"})
      ]

      Enum.each(messages, fn msg ->
        assert String.contains?(msg, "◆")
      end)
    end
  end
end
