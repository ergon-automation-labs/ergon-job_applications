defmodule BotArmyJobApplications.Handlers.TuiCommandHandler do
  @moduledoc """
  Handles TUI-originated NATS commands and snapshot request/reply.

  - requests.job_applications.snapshot — reply with { "applications": [...] } in TUI shape
  - commands.job_applications.create — create application from TUI form
  - commands.job_applications.update — full application update from TUI edit form
  - commands.job_applications.update_status — set state from TUI status
  - commands.job_applications.add_note — append note to strategy
  - commands.job_applications.delete — delete application (stops ApplicationServer if running)
  """

  require Logger

  defp application_store do
    Application.get_env(
      :bot_army_job_applications,
      :application_store,
      BotArmyJobApplications.ApplicationStore
    )
  end

  defp listing_store do
    Application.get_env(
      :bot_army_job_applications,
      :listing_store,
      BotArmyJobApplications.ListingStore
    )
  end

  @doc """
  Build snapshot payload for TUI: list applications and map to TUI format.
  Returns map suitable for JSON: %{"applications" => [%{"id" => ..., "company" => ..., ...}, ...]}.
  """
  def get_snapshot(tenant_id) do
    case application_store().list(tenant_id) do
      {:ok, applications} ->
        mapped =
          applications
          |> Enum.map(&application_to_tui/1)

        %{"applications" => mapped}

      _ ->
        %{"applications" => []}
    end
  end

  @doc """
  Handle create command from TUI. Payload can be:
  1. listing_id: Apply directly from listings (looks up company/role from listing)
  2. company + role: Manual entry (requires both fields)

  Creates application and starts ApplicationServer; publishes snapshot.
  """
  def handle_create(message) when is_map(message) do
    %{tenant_id: tenant_id, user_id: user_id} = BotArmyCore.Tenant.extract_context(message)
    payload = message["payload"] || %{}

    with {company, role, jd_url} <- resolve_company_and_role(tenant_id, payload),
         true <- company != "" and role != "",
         create_payload <-
           build_create_payload(tenant_id, user_id, company, role, jd_url, payload),
         {:ok, application} <- application_store().create(create_payload) do
      finalize_application_creation(application, tenant_id)
    else
      false ->
        Logger.warning("TUI create: company and role required")
        {:error, :invalid_payload}

      {:error, reason} ->
        Logger.error("TUI create failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp resolve_company_and_role(tenant_id, payload) do
    listing_id = trim(payload["listing_id"])

    if listing_id != "" do
      case listing_store().get(tenant_id, listing_id) do
        {:ok, listing} ->
          {listing["company"] || "", listing["role_title"] || listing["title"] || "",
           listing["jd_url"] || ""}

        {:error, _reason} ->
          Logger.warning("TUI create: listing #{listing_id} not found")
          {"", "", ""}
      end
    else
      {trim(payload["company"]), trim(payload["role"]), trim(payload["jd_url"] || "")}
    end
  end

  defp build_create_payload(tenant_id, user_id, company, role, jd_url, payload) do
    status = trim(payload["status"]) || "Applied"
    stage = trim(payload["stage"])
    notes = trim(payload["notes"])
    state = tui_status_to_state(status)

    create_payload = %{
      "tenant_id" => tenant_id,
      "user_id" => user_id,
      "company" => company,
      "role_title" => role,
      "state" => state,
      "history" => [
        %{
          "from_state" => nil,
          "to_state" => state,
          "transitioned_at" =>
            NaiveDateTime.utc_now()
            |> NaiveDateTime.truncate(:second)
            |> NaiveDateTime.to_iso8601(),
          "metadata" => %{"reason" => "tui_create"}
        }
      ]
    }

    create_payload
    |> maybe_put("next_action", stage)
    |> maybe_put("strategy", notes)
    |> maybe_put("jd_url", jd_url)
    |> maybe_put_salary(payload)
  end

  defp maybe_put(payload, _key, ""), do: payload
  defp maybe_put(payload, key, value), do: Map.put(payload, key, value)

  defp maybe_put_salary(payload, %{"salary_min" => min, "salary_max" => max})
       when is_number(min) and is_number(max) do
    Map.put(payload, "salary_range", %{"min" => min, "max" => max})
  end

  defp maybe_put_salary(payload, _), do: payload

  defp finalize_application_creation(application, tenant_id) do
    state = application["state"]

    if not BotArmyJobApplications.Commands.terminal?(state) do
      BotArmyJobApplications.ApplicationSupervisor.start_child(application["id"])
    end

    Logger.info(
      "TUI create: application #{application["id"]} (#{application["company"]} / #{application["role_title"]})"
    )

    publish_snapshot(tenant_id)
    {:ok, application}
  end

  def handle_create(_), do: {:error, :invalid_payload}

  @doc """
  Handle full update from TUI edit form. Payload: id, company, role, status, stage, location, last_contact, notes.
  Updates application in store; appends history event if state changed; publishes snapshot.
  """
  def handle_update(message) when is_map(message) do
    %{tenant_id: tenant_id, user_id: _user_id} = BotArmyCore.Tenant.extract_context(message)
    payload = message["payload"] || %{}
    id = payload["id"]
    company = trim(payload["company"])
    role = trim(payload["role"])

    if not is_binary(id) or id == "" or company == "" or role == "" do
      Logger.warning("TUI update: id, company, and role required")
      {:error, :invalid_payload}
    else
      perform_update(tenant_id, id, company, role, payload)
    end
  end

  defp perform_update(tenant_id, id, company, role, payload) do
    case application_store().get(tenant_id, id) do
      {:ok, app} ->
        to_state = tui_status_to_state(trim(payload["status"]) || "Applied")
        new_history = build_history(app, to_state, payload)
        update_payload = build_update_payload(company, role, to_state, new_history, payload)

        case application_store().update(tenant_id, id, update_payload) do
          {:ok, _} ->
            Logger.info("TUI update: application #{id} (#{company} / #{role})")
            publish_snapshot(tenant_id)
            {:ok, id}

          {:error, reason} ->
            Logger.warning("TUI update failed for #{id}: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, :not_found} ->
        Logger.warning("TUI update: application #{id} not found")
        {:error, :not_found}
    end
  end

  defp build_history(app, to_state, payload) do
    from_state = app["state"] || "identified"
    old_history = app["history"] || []

    if from_state != to_state do
      event = %{
        "from_state" => from_state,
        "to_state" => to_state,
        "transitioned_at" =>
          NaiveDateTime.utc_now()
          |> NaiveDateTime.truncate(:second)
          |> NaiveDateTime.to_iso8601(),
        "metadata" => %{"reason" => "tui_edit"}
      }

      old_history ++ [event]
    else
      old_history
    end
  end

  defp build_update_payload(company, role, to_state, new_history, payload) do
    stage = trim(payload["stage"])
    notes = trim(payload["notes"])
    jd_url = trim(payload["jd_url"])

    salary_range =
      case {payload["salary_min"], payload["salary_max"]} do
        {min, max} when is_number(min) and is_number(max) -> %{"min" => min, "max" => max}
        _ -> nil
      end

    %{
      "company" => company,
      "role_title" => role,
      "state" => to_state,
      "next_action" => (stage != "" && stage) || nil,
      "strategy" => (notes != "" && notes) || nil,
      "history" => new_history,
      "jd_url" => (jd_url != "" && jd_url) || nil,
      "salary_range" => salary_range
    }
  end

  def handle_update(_), do: {:error, :invalid_payload}

  @doc """
  Handle delete from TUI. Payload: id.
  Deletes application from store, stops ApplicationServer if running, publishes snapshot.
  """
  def handle_delete(message) when is_map(message) do
    %{tenant_id: tenant_id, user_id: _user_id} = BotArmyCore.Tenant.extract_context(message)
    payload = message["payload"] || %{}
    id = payload["id"]

    if not is_binary(id) or id == "" do
      Logger.warning("TUI delete: id required")
      {:error, :invalid_payload}
    else
      case application_store().delete(tenant_id, id) do
        :ok ->
          try do
            BotArmyJobApplications.ApplicationSupervisor.stop_child(id)
          rescue
            _ -> :ok
          end

          Logger.info("TUI delete: application #{id}")
          publish_snapshot(tenant_id)
          :ok

        {:error, :not_found} ->
          Logger.warning("TUI delete: application #{id} not found")
          {:error, :not_found}

        {:error, reason} ->
          Logger.error("TUI delete failed for #{id}: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  def handle_delete(_), do: {:error, :invalid_payload}

  @doc """
  Handle update_status from TUI. Payload: id, status.
  Updates application state and history directly (no transition validation); publishes snapshot.
  """
  def handle_update_status(message) when is_map(message) do
    %{tenant_id: tenant_id, user_id: _user_id} = BotArmyCore.Tenant.extract_context(message)
    payload = message["payload"] || %{}
    id = payload["id"]
    status = trim(payload["status"])

    if not is_binary(id) or id == "" or not is_binary(status) or status == "" do
      Logger.warning("TUI update_status: id and status required")
      {:error, :invalid_payload}
    else
      to_state = tui_status_to_state(status)

      case application_store().get(tenant_id, id) do
        {:ok, app} ->
          from_state = app["state"] || "identified"

          event = %{
            "from_state" => from_state,
            "to_state" => to_state,
            "transitioned_at" =>
              NaiveDateTime.utc_now()
              |> NaiveDateTime.truncate(:second)
              |> NaiveDateTime.to_iso8601(),
            "metadata" => %{"triggered_by" => "tui"}
          }

          new_history = (app["history"] || []) ++ [event]

          case application_store().update(tenant_id, id, %{
                 "state" => to_state,
                 "history" => new_history
               }) do
            {:ok, _} ->
              Logger.info("TUI update_status: #{id} -> #{to_state}")
              publish_snapshot(tenant_id)
              :ok

            {:error, reason} ->
              Logger.warning("TUI update_status failed for #{id}: #{inspect(reason)}")
              {:error, reason}
          end

        {:error, :not_found} ->
          Logger.warning("TUI update_status: application #{id} not found")
          {:error, :not_found}
      end
    end
  end

  def handle_update_status(_), do: {:error, :invalid_payload}

  @doc """
  Handle add_note from TUI. Payload: id, note.
  Appends note to application strategy; publishes snapshot.
  """
  def handle_add_note(message) when is_map(message) do
    %{tenant_id: tenant_id, user_id: _user_id} = BotArmyCore.Tenant.extract_context(message)
    payload = message["payload"] || %{}
    id = payload["id"]
    note = trim(payload["note"])

    if not is_binary(id) or id == "" or not is_binary(note) or note == "" do
      Logger.warning("TUI add_note: id and note required")
      {:error, :invalid_payload}
    else
      case application_store().get(tenant_id, id) do
        {:ok, app} ->
          existing = app["strategy"] || ""
          new_strategy = if existing == "", do: note, else: existing <> "\n- " <> note

          case application_store().update(tenant_id, id, %{"strategy" => new_strategy}) do
            {:ok, _} ->
              Logger.info("TUI add_note: appended to #{id}")
              publish_snapshot(tenant_id)
              :ok

            {:error, reason} ->
              Logger.error("TUI add_note update failed: #{inspect(reason)}")
              {:error, reason}
          end

        {:error, :not_found} ->
          Logger.warning("TUI add_note: application #{id} not found")
          {:error, :not_found}
      end
    end
  end

  def handle_add_note(_), do: {:error, :invalid_payload}

  # Map bot application to TUI snapshot row
  defp application_to_tui(app) do
    pending_type =
      case app["pending_signal"] do
        %{"type" => t} when is_binary(t) -> t
        _ -> nil
      end

    {salary_min, salary_max} = salary_range_from_app(app)

    %{
      "id" => app["id"],
      "company" => app["company"] || "",
      "role" => app["role_title"] || "",
      "status" => state_to_tui_status(app["state"]),
      "stage" => app["next_action"] || "",
      "location" => "",
      "last_contact" => last_contact_from_app(app),
      "notes" => app["strategy"] || "",
      "pending_signal_type" => pending_type,
      "jd_url" => app["jd_url"] || "",
      "salary_min" => salary_min,
      "salary_max" => salary_max
    }
  end

  defp salary_range_from_app(app) do
    case app["salary_range"] do
      %{"min" => min, "max" => max} when is_number(min) and is_number(max) ->
        {min, max}

      _ ->
        {nil, nil}
    end
  end

  defp last_contact_from_app(app) do
    case app["history"] do
      list when is_list(list) and list != [] ->
        last = List.last(list)
        Map.get(last, "transitioned_at", app["updated_at"] || "")

      _ ->
        app["updated_at"] || ""
    end
  end

  defp state_to_tui_status(nil), do: "Applied"
  defp state_to_tui_status(""), do: "Applied"
  defp state_to_tui_status("identified"), do: "Applied"
  defp state_to_tui_status("drafting"), do: "Applied"
  defp state_to_tui_status("ready_to_submit"), do: "Applied"
  defp state_to_tui_status("submitted"), do: "Applied"
  defp state_to_tui_status("phone_screen"), do: "Screening"
  defp state_to_tui_status("technical"), do: "Interview"
  defp state_to_tui_status("offer"), do: "Offer"
  defp state_to_tui_status("accepted"), do: "Offer"
  defp state_to_tui_status("declined"), do: "Rejected"
  defp state_to_tui_status("rejected"), do: "Rejected"
  defp state_to_tui_status("ghosted"), do: "Rejected"
  defp state_to_tui_status(other), do: other

  defp tui_status_to_state(nil), do: "identified"
  defp tui_status_to_state(""), do: "identified"
  defp tui_status_to_state("Applied"), do: "identified"
  defp tui_status_to_state("Screening"), do: "phone_screen"
  defp tui_status_to_state("Interview"), do: "technical"
  defp tui_status_to_state("Offer"), do: "offer"
  defp tui_status_to_state("Rejected"), do: "rejected"
  defp tui_status_to_state(other), do: other

  defp trim(nil), do: ""
  defp trim(s) when is_binary(s), do: String.trim(s)
  defp trim(_), do: ""

  defp publish_snapshot(tenant_id) do
    snapshot = get_snapshot(tenant_id)
    BotArmyJobApplications.NATS.Publisher.publish_snapshot(snapshot)
  end
end
