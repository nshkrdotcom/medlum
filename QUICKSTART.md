# Lumainus - Quick Start Guide

## 🚀 Get Started in 30 Seconds

```bash
cd /home/home/p/g/n/lumainus_web
mix phx.server
```

Then open: **http://localhost:4000/reports**

## ✅ What You'll See

### Left Pane - Medical Documents (6 sample documents)
- **Doctor's Note** - Primary care visit (green badge)
- **Cardiology Consultation** - Specialist note (red badge)
- **Lab Report** - Lipid panel results (purple badge)
- **Radiology** - Chest X-ray (blue badge)
- **Hospital Discharge** - 3-day pneumonia stay (orange badge)
- **Infectious Disease** - Specialist consult (yellow badge)

Click any document to see details!

### Main Pane - Clinical Summary Report
Comprehensive patient summary with sections:
- Chief Complaint
- History of Present Illness (HPI)
- Medications
- Past Exam Findings
- Review of Systems
- Lab Results
- Imaging Studies
- Pathology
- Assessment
- Plan

### 🔗 Provenance Tracking (The Cool Part!)

Look for **blue badges** like this in the report:

> "Patient has elevated LDL (165 mg/dL) [doc-003]"

**Click the blue badge** → Modal pops up showing the source document!

Switch between:
- **Summary** - AI-generated summary
- **Cleaned** - Formatted/structured version
- **Raw** - Original document text

## 📁 Project Structure

```
lumainus_web/
├── lib/
│   ├── lumainus_web/
│   │   └── medical/
│   │       └── mock_documents.ex    ← All hardcoded data here
│   └── lumainus_web_web/
│       └── live/
│           └── reports_live.ex      ← Main UI component
├── DEVELOPMENT.md                   ← Detailed dev guide
└── QUICKSTART.md                    ← You are here!
```

## 🎯 Current Status

**This is a UI mockup with hardcoded data.**

✅ Working:
- Beautiful medical document UI
- Report generation display
- Provenance linking (click sources)
- Document detail modal (3 view modes)
- Professional styling

❌ Not implemented yet:
- No AI/LLM integration
- No database
- No authentication
- No file upload
- No real document processing

## 🔜 Next Steps

### Phase 1: Add Real LLM Processing

1. **Integrate Gemini API** (via `gemini_ex`)
   ```elixir
   # Add to mix.exs
   {:gemini_ex, "~> 0.1.0"}
   ```

2. **One Prompt Per Section**
   - Chief Complaint: 1 LLM call
   - HPI: 1 LLM call
   - Labs: 1 LLM call
   - etc.

3. **Structured Outputs with Tool Calling**
   ```elixir
   # Example for Chief Complaint
   Gemini.generate_content(
     prompt: "Extract chief complaint from these documents: #{docs}",
     tools: [
       %{
         type: "function",
         function: %{
           name: "extract_chief_complaint",
           parameters: %{
             text: "string",
             sources: ["doc-001", "doc-002"]
           }
         }
       }
     ]
   )
   ```

4. **Provenance Tagging**
   - LLM outputs: `"text|source:doc-001,doc-002"`
   - UI already handles this format!

### Phase 2: Document Upload

1. Add file upload LiveView component
2. Store uploaded files (temp directory or S3)
3. Auto-classify documents by type
4. Generate summaries with LLM

### Phase 3: Multi-Agent Framework (Synapse)

1. Add Synapse dependency
2. Build critic pipeline (see `docs/20251116/001_LUMAINUS_claude.md`)
3. Implement attribution graphs

### Phase 4: HIPAA + FDA Compliance

1. Add encryption (AES-256, TLS 1.2+)
2. Audit logging
3. BAA with cloud providers
4. Clinical validation studies

## 📖 Read More

- **DEVELOPMENT.md** - Full development guide
- **../lumainus/docs/20251116/001_LUMAINUS_claude.md** - Architecture design
- **../lumainus/docs/20251114/** - FDA regulatory strategy

## 🎨 UI Customization

All styling is in `lib/lumainus_web_web/live/reports_live.ex` using Tailwind CSS.

### Color Scheme
- **Primary**: Blue (`blue-600`, `blue-100`)
- **Success**: Green (Doctor's Notes)
- **Danger**: Red (Cardiology)
- **Info**: Purple (Labs)
- **Warning**: Orange (Hospital)
- **Neutral**: Gray

### Document Category Colors

Change in `get_category_color/1` function:

```elixir
defp get_category_color(type) do
  cond do
    String.contains?(type, "Doctor's Note") -> "bg-green-100 text-green-800"
    String.contains?(type, "Cardiology") -> "bg-red-100 text-red-800"
    # ... etc
  end
end
```

## 🐛 Common Issues

### Port 4000 in use?

```bash
# Option 1: Kill existing process
pkill -f "phx.server"

# Option 2: Use different port
# Edit config/dev.exs:
http: [port: 4001]
```

### Compilation errors?

```bash
mix clean
mix deps.get
mix compile
```

### Assets not loading?

```bash
mix assets.setup
```

## 💡 Pro Tips

1. **Use `iex -S mix phx.server`** for interactive debugging
2. **Edit mock data** in `lib/lumainus_web/medical/mock_documents.ex`
3. **LiveView auto-reloads** when you save files (in dev mode)
4. **Check browser console** for JavaScript errors
5. **Use Chrome DevTools** to inspect Tailwind classes

## 🎉 You're All Set!

The UI is fully functional - just waiting for real data!

**Next:** Start adding Gemini API integration or upload capability.

Questions? Check `DEVELOPMENT.md` or the main project docs.

---

**Built with:** Phoenix 1.8 • LiveView • Tailwind CSS • Elixir 1.18
**Status:** UI Mockup Complete ✅
**Next Phase:** LLM Integration 🚧
