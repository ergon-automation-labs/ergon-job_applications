defmodule BotArmyJobApplications.TextExtractor do
  @moduledoc """
  Extracts text from various resume file formats (PDF, DOCX, XLSX, MD, TXT).
  """

  require Logger

  @doc """
  Extract text from a file.
  Supports: .md, .txt, .pdf, .docx, .doc
  Returns {:ok, text} or {:error, reason}
  """
  def extract(file_path, original_filename)
      when is_binary(file_path) and is_binary(original_filename) do
    extension = Path.extname(original_filename) |> String.downcase()

    case extension do
      ".md" -> extract_markdown(file_path)
      ".txt" -> extract_text(file_path)
      ".pdf" -> extract_pdf(file_path)
      ".docx" -> extract_docx(file_path)
      ".doc" -> extract_doc(file_path)
      _ -> {:error, {:unsupported_format, extension}}
    end
  end

  # Extract from Markdown (simple file read)
  defp extract_markdown(file_path) do
    File.read(file_path)
  end

  # Extract from plain text
  defp extract_text(file_path) do
    File.read(file_path)
  end

  # Extract from PDF using pdftotext command
  defp extract_pdf(file_path) do
    case System.cmd("pdftotext", [file_path, "-"]) do
      {text, 0} ->
        {:ok, text}

      {_output, code} ->
        Logger.error("pdftotext failed with exit code #{code}")
        {:error, {:pdf_extraction_failed, code}}
    end
  rescue
    e ->
      Logger.error("pdftotext not available: #{inspect(e)}")
      {:error, {:pdftotext_not_available, e}}
  end

  # Extract from DOCX (Office Open XML)
  defp extract_docx(file_path) do
    extract_office_xml(file_path)
  end

  # Extract from DOC (legacy Office format) - treat like DOCX for now
  defp extract_doc(file_path) do
    extract_office_xml(file_path)
  end

  # Extract text from Office XML format (DOCX/XLSX have same internal structure)
  defp extract_office_xml(file_path) do
    with {:ok, zip_data} <- File.read(file_path),
         {:ok, files} <- :zip.unzip(zip_data, [:memory]),
         {:ok, doc_xml} <- find_document_xml(files) do
      text = parse_office_xml(doc_xml)
      {:ok, text}
    else
      {:error, reason} ->
        Logger.error("Failed to extract from Office document: #{inspect(reason)}")
        {:error, reason}
    end
  rescue
    e ->
      Logger.error("Error extracting from Office document: #{inspect(e)}")
      {:error, {:office_extraction_failed, e}}
  end

  # Find the document.xml file in the Office package
  defp find_document_xml(files) do
    case Enum.find(files, fn {name, _content} ->
           String.contains?(to_string(name), "word/document.xml")
         end) do
      {_name, content} -> {:ok, content}
      nil -> {:error, :document_xml_not_found}
    end
  end

  # Parse Office XML and extract text content
  defp parse_office_xml(xml) when is_binary(xml) do
    # Simple approach: remove all XML tags and keep text content
    xml
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp parse_office_xml(xml) when is_list(xml) do
    xml
    |> List.to_string()
    |> parse_office_xml()
  end
end
