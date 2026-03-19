# Test to estimate payload size
listings = Enum.map(1..100, fn i ->
  %{
    "id" => "00000000-0000-0000-0000-#{String.pad_leading(Integer.to_string(i), 12, "0")}",
    "source" => "greenhouse",
    "source_url" => "https://jobs.greenhouse.io/company/jobs/#{i}",
    "company" => "Company #{i}",
    "role_title" => "Senior Software Engineer #{i}",
    "jd_text" => String.duplicate("Lorem ipsum dolor sit amet, consectetur adipiscing elit. ", 20),
    "jd_url" => "https://example.com/job/#{i}",
    "jd_tags" => ["python", "golang", "rust", "elixir"],
    "salary_range" => "$150k-$200k",
    "coverage_score" => 0.85,
    "status" => "new",
    "discovered_at" => "2026-03-19T17:26:35Z",
    "scored_at" => "2026-03-19T17:26:36Z",
    "dedup_hash" => "hash#{i}",
    "created_at" => "2026-03-19T17:26:35Z",
    "updated_at" => "2026-03-19T17:26:35Z"
  }
end)

response = %{"ok" => true, "listings" => listings, "total" => 1394}
json = Jason.encode!(response)
size_bytes = byte_size(json)
size_mb = size_bytes / (1024 * 1024)

IO.puts("Response size: #{size_bytes} bytes (#{Float.round(size_mb, 2)} MB)")
IO.puts("NATS default max_payload: 1 MB")
IO.puts("Exceeds limit: #{size_bytes > 1024 * 1024}")
