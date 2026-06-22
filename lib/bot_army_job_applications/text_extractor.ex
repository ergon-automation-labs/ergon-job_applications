defmodule BotArmyJobApplications.TextExtractor do
  @moduledoc """
  Extracts text from resume files (PDF, DOCX, TXT, MD).
  """

  require Logger

  @doc """
  Extract text from a resume file.

  Supports: .pdf, .docx, .txt, .md

  Returns: {:ok, text} or {:error, reason}
  """
  def extract(file_path, _original_filename) do
    if not File.exists?(file_path) do
      {:error, "file not found"}
    else
      ext = file_path |> Path.extname() |> String.downcase()

      case ext do
        ".pdf" -> extract_pdf(file_path)
        ".docx" -> extract_docx(file_path)
        ".txt" -> extract_txt(file_path)
        ".md" -> extract_markdown(file_path)
        _ -> {:error, "unsupported file format: #{ext}"}
      end
    end
  end

  defp extract_pdf(file_path) do
    case System.cmd("pdftotext", [file_path, "-"], stderr_to_stdout: true) do
      {text, 0} ->
        {:ok, String.trim(text)}

      {error, _code} ->
        Logger.warning("pdftotext failed for #{file_path}: #{error}")
        fallback_text_extraction(file_path)
    end
  rescue
    _e ->
      fallback_text_extraction(file_path)
  end

  defp extract_docx(file_path) do
    case System.cmd("python3", ["-m", "docx2txt", file_path], stderr_to_stdout: true) do
      {text, 0} ->
        {:ok, String.trim(text)}

      {error, _code} ->
        Logger.warning("docx2txt failed for #{file_path}: #{error}")
        fallback_text_extraction(file_path)
    end
  rescue
    _e ->
      fallback_text_extraction(file_path)
  end

  defp extract_txt(file_path) do
    case File.read(file_path) do
      {:ok, content} ->
        {:ok, String.trim(content)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_markdown(file_path) do
    case File.read(file_path) do
      {:ok, content} ->
        {:ok, String.trim(content)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fallback_text_extraction(file_path) do
    case File.read(file_path) do
      {:ok, content} ->
        text =
          content
          |> String.replace(<<0>>, "")
          |> String.replace(~r/[[:cntrl:]]/, " ")
          |> String.replace(~r/\s+/, " ")
          |> String.trim()

        if byte_size(text) > 100 do
          {:ok, text}
        else
          {:error, "unable to extract meaningful text from file"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
