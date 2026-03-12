defmodule BotArmyJobApplications.Commands do
  @moduledoc """
  State machine definition for job applications.

  Defines valid transitions between application states and terminal states.
  """

  @valid_transitions %{
    "identified" => ["drafting"],
    "drafting" => ["ready_to_submit"],
    "ready_to_submit" => ["submitted"],
    "submitted" => ["phone_screen", "rejected", "ghosted"],
    "phone_screen" => ["technical", "rejected", "ghosted"],
    "technical" => ["offer", "rejected", "ghosted"],
    "offer" => ["accepted", "declined"]
  }

  @terminal_states ["accepted", "declined", "rejected", "ghosted"]

  @doc """
  Check if a transition from one state to another is valid.
  """
  def valid_transition?(from, to) do
    to in Map.get(@valid_transitions, from, [])
  end

  @doc """
  Check if a state is terminal (end state).
  """
  def terminal?(state) do
    state in @terminal_states
  end

  @doc """
  Get all valid next states from a given state.
  """
  def next_states(state) do
    Map.get(@valid_transitions, state, [])
  end

  @doc """
  Get all possible states (both non-terminal and terminal).
  """
  def all_states do
    (@valid_transitions |> Map.keys()) ++ @terminal_states
  end

  @doc """
  Create a state event for transition history.
  """
  def create_state_event(from_state, to_state, metadata \\ %{}) when is_binary(from_state) and is_binary(to_state) do
    if valid_transition?(from_state, to_state) do
      {:ok,
       %{
         "from_state" => from_state,
         "to_state" => to_state,
         "transitioned_at" => NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_iso8601(),
         "metadata" => metadata
       }}
    else
      {:error, :invalid_transition}
    end
  end
end
