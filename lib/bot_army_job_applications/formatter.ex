defmodule BotArmyJobApplications.Formatter do
  @moduledoc """
  Message formatting for Job Bot non-LLM notifications.

  Formats opportunity notifications, application status updates, and structured
  messages with Job Bot's career strategy voice.

  Reference: `/docs/north_star_docs/BOT_ARMY_PERSONALITY_NORTH_STAR.md`
  """

  require Logger
  alias BotArmyRuntime.Personality.Formatter

  @doc """
  Format opportunity discovered notification.

  Used when a new job opportunity matching your profile is found.
  """
  def format(:opportunity_discovered, %{"title" => title, "company" => company}) do
    Formatter.with_symbol(
      :job_bot,
      "#{title} at #{company} just hit your filter. This one's worth your time."
    )
  end

  @doc """
  Format application submitted notification.

  Used when an application is successfully submitted.
  """
  def format(:application_submitted, %{"title" => title, "company" => company}) do
    Formatter.with_symbol(:job_bot, "Application sent: #{title} at #{company}. One down.")
  end

  @doc """
  Format interview scheduled notification.

  Used when an interview is confirmed for a position.
  """
  def format(:interview_scheduled, %{"title" => title, "company" => company, "date" => date}) do
    Formatter.with_symbol(
      :job_bot,
      "Interview locked: #{title} at #{company} on #{date}. You've got this."
    )
  end

  @doc """
  Format interview feedback notification.

  Used to provide feedback after an interview completes.
  """
  def format(:interview_feedback, %{"title" => title, "feedback" => feedback}) do
    Formatter.with_symbol(
      :job_bot,
      "Interview notes for #{title}: #{feedback}"
    )
  end

  @doc """
  Format offer received notification.

  Used when a job offer comes in.
  """
  def format(:offer_received, %{"title" => title, "company" => company}) do
    Formatter.with_symbol(
      :job_bot,
      "Offer from #{company} for #{title}. We'll talk numbers."
    )
  end

  @doc """
  Format rejection notification.

  Used when a position is closed or you're no longer in consideration.
  """
  def format(:rejection, %{"title" => title, "company" => company}) do
    Formatter.with_symbol(
      :job_bot,
      "#{company} passed on #{title}. Check. Next."
    )
  end

  @doc """
  Format error notification.

  Used when something goes wrong.
  """
  def format(:error, %{"message" => message}) do
    Formatter.with_symbol(:job_bot, "Something went wrong: #{message}")
  end

  def format(_type, _data) do
    Logger.warning("Unknown Job formatter type")
    Formatter.with_symbol(:job_bot, "Something happened.")
  end
end
