defmodule BotArmyJobApplications.FileStore do
  @moduledoc """
  File storage for uploaded resumes.
  Handles writing files to a shared directory that can be accessed by both surface and bot.
  """

  require Logger

  @doc """
  Store a file and return the path where it was stored.
  Accepts the binary content and returns {:ok, file_path}.
  """
  def store(filename, binary) when is_binary(filename) and is_binary(binary) do
    upload_dir = upload_dir()
    File.mkdir_p!(upload_dir)

    # Generate a unique filename to avoid collisions
    unique_filename = "#{UUID.uuid4()}_#{filename}"
    file_path = Path.join(upload_dir, unique_filename)

    case File.write(file_path, binary) do
      :ok ->
        Logger.info("Stored resume file: #{file_path}")
        {:ok, file_path}

      {:error, reason} ->
        Logger.error("Failed to store resume file: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Read a file from disk.
  """
  def read(file_path) when is_binary(file_path) do
    File.read(file_path)
  end

  @doc """
  Delete a file from disk.
  """
  def delete(file_path) when is_binary(file_path) do
    case File.rm(file_path) do
      :ok ->
        Logger.info("Deleted resume file: #{file_path}")
        :ok

      {:error, reason} ->
        Logger.error("Failed to delete resume file: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Get the upload directory path.
  """
  def upload_dir do
    System.get_env(
      "RESUME_UPLOAD_DIR",
      "/var/data/bot_army/job_applications/resumes"
    )
  end
end
