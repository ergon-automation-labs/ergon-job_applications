defmodule BotArmyJobApplications.MixProject do
  use Mix.Project

  def project do
    [
      app: :bot_army_job_applications,
      version: "0.2.57",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [
        # Release name must match Salt/infra: .../current/bot_army_job_applications/bin/bot_army_job_applications
        bot_army_job_applications: [
          applications: [bot_army_job_applications: :permanent]
        ]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {BotArmyJobApplications.Application, []}
    ]
  end

  defp deps do
    [
      {:bot_army_library_core, path: "../bot_army_library_core"},
      {:bot_army_library_runtime, path: "../bot_army_library_runtime"},
      {:bot_army_library_learning, path: "../bot_army_library_learning"},
      {:ecto_sql, "~> 3.10"},
      {:postgrex, "~> 0.17"},
      {:jason, "~> 1.4"},
      {:logger_json, "~> 5.1"},
      {:elixir_uuid, "~> 1.2"},
      {:req, "~> 0.4"},

      # Development/Test
      {:ex_doc, "~> 0.30", only: :dev},
      {:credo, "~> 1.7", only: [:dev, :test]},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.17", only: :test},
      {:mox, "~> 1.0", only: :test}
    ]
  end
end
