# Lumainus Web - Development Guide

## Overview

This is the Phoenix LiveView frontend for Lumainus - a HIPAA-compliant, FDA-authorized AI platform for clinical documentation summarization.

**Current Status:** UI Mockup with Hardcoded Data (No AI/LLM integration yet, no database)

## Quick Start

### Prerequisites

- Elixir 1.18+ (via asdf)
- Phoenix 1.8.1
- No database required (in-memory mockups)

### Running the Application

```bash
# From lumainus_web directory
cd /home/home/p/g/n/lumainus_web

# Get dependencies (first time only)
mix deps.get

# Set up assets (first time only)
mix assets.setup

# Start the Phoenix server
mix phx.server

# Or run in interactive mode
iex -S mix phx.server
```

### Access the Application

Open your browser to: **http://localhost:4000/reports**

## Features

### Current Implementation (MVP)

✅ **Left Pane - Document List**
- Shows 6 hardcoded medical documents
- Color-coded by category (Doctor's Notes, Labs, Radiology, etc.)
- Click to select and view details
- Categories:
  - Doctor's Note - Primary Care
  - Cardiology Consultation
  - Lab Report - Lipid Panel
  - Radiology - Chest X-Ray
  - Hospital Discharge Summary
  - Specialist Note - Infectious Disease

✅ **Main Pane - Clinical Summary Report**
- Chief Complaint
- History of Present Illness (HPI)
  - Present Illness
  - Past Medical History
  - Past Surgical History
  - Social History
- Medications
- Past Physical Exam Findings
- Review of Systems
- Laboratory Results
- Imaging Studies
- Pathology Results
- Assessment
- Plan

✅ **Provenance Tracking**
- Inline source citations (blue badges)
- Click source badge → opens source document modal
- Example: "Fatigue and chest discomfort (3-month history)|source:doc-001"

✅ **Document Detail Modal**
- Three view modes:
  - **Summary**: AI-generated summary (mockup)
  - **Cleaned**: Structured/formatted version
  - **Raw**: Original document text
- Toggle between views with tabs
- Close button to return to report

✅ **Professional Medical UI**
- Tailwind CSS styling
- Clean, clinical aesthetic
- Responsive layout
- Color-coded document categories

### Not Yet Implemented

❌ **AI/LLM Integration**
- No Gemini API calls yet
- No actual document processing
- Synapse multi-agent framework (planned)

❌ **Database**
- All data in-memory (mockups)
- No persistence
- No user accounts

❌ **Authentication**
- No login system yet
- Routes not protected
- Planned: Phoenix built-in auth or session-based

❌ **Document Upload**
- No file upload capability
- No document classification pipeline
- All documents are hardcoded in `MockDocuments` module

❌ **Real LLM Processing**
- No report generation from actual documents
- No provenance extraction from LLM
- No tool calling / structured outputs

## Architecture

### File Structure

```
lumainus_web/
├── lib/
│   ├── lumainus_web/
│   │   ├── medical/
│   │   │   └── mock_documents.ex    # Hardcoded test data
│   │   └── application.ex
│   └── lumainus_web_web/
│       ├── live/
│       │   └── reports_live.ex      # Main report UI
│       ├── router.ex                # Routes (/reports)
│       └── components/
├── assets/
│   ├── css/
│   │   └── app.css                  # Tailwind CSS
│   └── js/
│       └── app.js
└── priv/
    └── static/
```

### Data Model

**Document Structure:**
```elixir
%Document{
  id: "doc-001",
  type: "Doctor's Note - Primary Care",
  date: ~D[2024-11-10],
  provider: "Dr. Sarah Chen, MD",
  summary: "AI-generated summary...",
  raw_content: "Original document text...",
  cleaned_content: "Structured markdown version..."
}
```

**Report Structure:**
```elixir
%Report{
  patient_name: "John Doe",
  patient_mrn: "123456789",
  chief_complaint: "Text|source:doc-001",
  hpi: %{...},
  medications: [%{...}],
  labs: [%{...}],
  imaging: [%{...}],
  # ... all sections
}
```

### Provenance Format

Text content includes inline source citations:

```
"Patient has elevated LDL (165 mg/dL)|source:doc-003"
```

These are parsed and rendered as clickable badges that link to source documents.

## Next Steps

### Phase 1: Document Processing Pipeline
1. Add file upload capability
2. Integrate Gemini API via `gemini_ex`
3. Implement document classification
4. Build document summarization

### Phase 2: Report Generation
1. LLM-based report generation (one prompt per section)
2. Structured outputs with tool calling
3. Provenance extraction from LLM responses
4. Implement `|source:doc-xxx` tagging automatically

### Phase 3: Multi-Agent Framework
1. Integrate Synapse (Jido-based)
2. Build critic pipeline (from Lumainus architecture doc)
3. Add statistical validation
4. Implement attribution graphs

### Phase 4: Production Features
1. Add PostgreSQL (optional - could stay in-memory)
2. Implement authentication (Phoenix.LiveView.Auth or session-based)
3. Add user management
4. Deploy to production

### Phase 5: HIPAA Compliance
1. Encryption at rest/transit
2. Audit logging
3. BAA with cloud providers
4. Security risk assessment

## Development Notes

### Modifying Mock Data

Edit `lib/lumainus_web/medical/mock_documents.ex`:

- `list_documents/0` - Document list (left pane)
- `get_report/0` - Generated report (main pane)

### Adding New Report Sections

1. Add field to `Report` struct in `mock_documents.ex`
2. Add data in `get_report/0`
3. Add UI section in `reports_live.ex` render function
4. Use `<.report_section>` component

### Styling Changes

- Tailwind CSS classes in `reports_live.ex`
- Custom CSS in `assets/css/app.css`
- Color scheme: Blue primary, gray neutrals, category-specific accents

## Testing

```bash
# Run tests
mix test

# Run with coverage
mix test --cover

# Interactive testing
iex -S mix phx.server
```

## Troubleshooting

### Port 4000 already in use

```bash
# Change port in config/dev.exs
http: [ip: {127, 0, 0, 1}, port: 4001]
```

### Assets not loading

```bash
# Rebuild assets
mix assets.setup
mix assets.deploy
```

### Compilation errors

```bash
# Clean and recompile
mix clean
mix deps.clean --all
mix deps.get
mix compile
```

## Design Decisions

### Why no database for MVP?
- Faster iteration on UI
- No schema migrations during rapid development
- Easy to add later when data model stabilizes

### Why hardcoded data?
- Focus on UI/UX first
- Design the ideal output format
- Then build LLM pipeline to generate that format

### Why Phoenix LiveView?
- Real-time updates (future: streaming LLM responses)
- Rich interactivity without complex JS
- Server-side rendering = better SEO
- Elixir/OTP = great for agent framework (Synapse)

## Resources

- [Phoenix LiveView Docs](https://hexdocs.pm/phoenix_live_view/)
- [Tailwind CSS](https://tailwindcss.com/)
- [Gemini API](https://ai.google.dev/gemini-api/docs)
- [Lumainus Architecture Docs](../lumainus/docs/20251116/001_LUMAINUS_claude.md)
- [FDA Strategy Docs](../lumainus/docs/20251114/)
