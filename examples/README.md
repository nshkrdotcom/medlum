# Examples

This directory contains runnable samples that exercise the Lumainus HTTP API.

## Upload the sample PDF

1. Ensure services are running:
   - Start the Docling service (see `scripts/setup_docling_service.sh` or the systemd unit).
   - Start the Phoenix app: `mix phx.server`.
2. Run the helper script from the project root:

   ```bash
   ./examples/upload_sample.sh
   ```

   The script uploads `docling_service/testPdf.pdf` to `http://localhost:4000/api/uploads`.

3. You should see a JSON response similar to:

   ```json
   {
     "filename": "testPdf.pdf",
     "queued_job": "pdf_ingest",
     "status": "pending",
     "upload_id": "bfb068ab-5b8c-4b38-a9a4-758f3a7cee53"
   }
   ```

Pass a custom file by providing a path:

```bash
./examples/upload_sample.sh path/to/your.pdf
```

Override the API URL by setting `API_URL`:

```bash
API_URL=http://localhost:4001/api/uploads ./examples/upload_sample.sh
```

## Track ingestion progress

1. Upload a PDF as shown above (or let the tracking script do it for you).
2. Run the tracker to upload `docling_service/testPdf.pdf` and poll `/api/uploads/:id/status` until the job completes:

   ```bash
  ./examples/track_sample.sh
   ```

   The script prints each stage (`queued`, `downloading`, `docling`, `parsing`, `completed`) with the reported percent complete and message text. It uses `python3` (or falls back to `python`, overridable via `PYTHON_BIN`). Override the target API host or polling interval:

   ```bash
   API_BASE=http://localhost:4001 POLL_INTERVAL=1 PYTHON_BIN=python ./examples/track_sample.sh path/to/file.pdf
   ```
