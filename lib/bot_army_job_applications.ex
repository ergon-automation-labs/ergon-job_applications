defmodule BotArmyJobApplications do
  @moduledoc """
  Job Application Bot — manages job search lifecycle from listing discovery through artifact generation,
  pipeline state tracking, and email signal detection.

  This bot provides:
  - Resume as structured data (roles, bullets, skills)
  - Artifact generation (tailored cover letters and resumes)
  - Application state machine (identified → submitted → phone_screen → offer → accepted/declined)
  - Email signal detection (interview invites, rejections, offers)
  - Job listing discovery and scoring
  - Kanban dashboard for pipeline tracking
  - GTD Bot integration for action items

  ## Starting the Application

      BotArmyJobApplications.start_link([])

  """

  def start_link(opts) do
    Supervisor.start_link(
      [
        BotArmyJobApplications.Repo,
        {BotArmyJobApplications.NATS.Consumer, []}
      ],
      Supervisor.init_opts(opts)
    )
  end
end
