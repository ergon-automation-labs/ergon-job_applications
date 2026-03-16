defmodule Mix.Tasks.JobApplications.SeedResume do
  @shortdoc "Seeds a minimal resume (identity, one role with bullets, skills) for artifact pipeline testing"
  @moduledoc """
  Creates one resume with:
  - identity (name, summary, summary_variants for platform/sre)
  - one role with two bullets (tags for ResumeComposer)
  - two skills

  Run with: mix job_applications.seed_resume

  Requires database and migrations run. Uses Repo directly so run outside test.
  """
  use Mix.Task

  @requirements ["app.config"]

  def run(_args) do
    Mix.Task.run("app.start")

    resume_id = create_resume()
    role_id = create_role(resume_id)
    create_bullets(role_id)
    create_skills(resume_id)

    IO.puts("Seeded resume #{resume_id} with 1 role (2 bullets) and 2 skills.")
    IO.puts("Use this resume_id with job.application.artifact.request (application_id + resume_id).")
  end

  defp create_resume do
    id = Ecto.UUID.generate()

    BotArmyJobApplications.Repo.insert!(%BotArmyJobApplications.Schemas.Resume{
      id: id,
      identity: %{
        "name" => "Seed User",
        "summary" => "Engineer with platform and reliability experience.",
        "summary_variants" => %{
          "platform" => "Platform engineer focused on developer tooling and internal systems.",
          "sre" => "SRE with experience in observability and incident response."
        }
      },
      metadata: %{
        "min_salary" => 175_000,
        "target_tags" => ["platform", "kubernetes", "reliability"]
      }
    })

    id |> to_string()
  end

  defp create_role(resume_id) do
    id = Ecto.UUID.generate()

    BotArmyJobApplications.Repo.insert!(%BotArmyJobApplications.Schemas.ResumeRole{
      id: id,
      resume_id: resume_id,
      title: "Senior Engineer",
      company: "Example Corp",
      start_date: ~D[2020-01-01],
      end_date: ~D[2024-01-01],
      framing_profiles: %{},
      sort_order: 0
    })

    id |> to_string()
  end

  defp create_bullets(role_id) do
    for {text, tags} <- [
          {"Built internal platform serving 50+ engineers; reduced deploy time by 40%.", ["platform", "developer_tooling"]},
          {"Owned SRE practices: on-call, runbooks, postmortems.", ["sre", "reliability"]}
        ] do
      BotArmyJobApplications.Repo.insert!(%BotArmyJobApplications.Schemas.ResumeBullet{
        id: Ecto.UUID.generate(),
        role_id: role_id,
        text: text,
        alt_phrasings: [],
        tags: tags,
        metrics: %{},
        strength: "strong",
        sort_order: 0
      })
    end
  end

  defp create_skills(resume_id) do
    for {name, tags} <- [
          {"Kubernetes", ["platform", "kubernetes", "orchestration"]},
          {"Elixir", ["platform", "backend"]}
        ] do
      BotArmyJobApplications.Repo.insert!(%BotArmyJobApplications.Schemas.Skill{
        id: Ecto.UUID.generate(),
        resume_id: resume_id,
        name: name,
        tags: tags,
        proficiency: "proficient",
        years: 5
      })
    end
  end
end
