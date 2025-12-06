# Frontend Streaming Implementation Design

## Executive Summary

This document provides a detailed implementation plan for streaming raw LLM output in real-time to the `/reports` page while sections are running. The design leverages Phoenix LiveView's PubSub system to deliver streaming chunks from the backend to the frontend, displaying them in a "cool" gray monospace style alongside the existing spinner.

---

## 1. Architecture Overview

### Current State

**Current UI (lines 4256-4260):**
```heex
<%= if MapSet.member?(@running_sections, to_string(section_entry.section.id)) do %>
  <div class="section-output flex justify-center items-center py-12">
    <span class="loading loading-spinner loading-lg text-slate-400"></span>
  </div>
```

### Proposed Architecture

```
+-------------------+     PubSub      +------------------+
|  SectionRunner    |---------------->|   ReportsLive    |
|  (LLM Streaming)  |  :llm_chunk     |   (LiveView)     |
+-------------------+                 +------------------+
         |                                     |
         v                                     v
   {:llm_chunk,                         handle_info/2
    section_run_id,                     updates assigns
    chunk_text}                         @streaming_content
```

---

## 2. Socket Assigns - State Management

### New Assigns

Add to `load_workspace/1`:

```elixir
|> assign_new(:streaming_content, fn -> %{} end)
```

### Data Structure

```elixir
# streaming_content: map of section_id => accumulated text
%{
  "section-uuid-1" => "{\n  \"markdown\": \"## Patient History\\n\\nThe patient...",
  "section-uuid-2" => "{\n  \"markdown\": \"## Diagnosis\\n\\n..."
}
```

This structure:
- Supports multiple simultaneous streams ("Run All" scenario)
- Uses section_id as key for O(1) lookup
- Stores accumulated raw text (JSON/markdown as it arrives)

---

## 3. LiveView Changes

### 3.1 Handle Streaming Chunks

Add new `handle_info` clauses:

```elixir
# Handle incoming LLM stream chunk
def handle_info({:llm_chunk, %{section_run_id: section_run_id, text: text}}, socket) do
  section_id = find_section_id_for_run(socket, section_run_id)

  if section_id && MapSet.member?(socket.assigns.running_sections, section_id) do
    current = Map.get(socket.assigns.streaming_content, section_id, "")
    updated_content = current <> text

    # Truncate if too long (performance safeguard)
    truncated =
      if String.length(updated_content) > 10_000 do
        "..." <> String.slice(updated_content, -8000, 8000)
      else
        updated_content
      end

    {:noreply,
     assign(socket, :streaming_content,
       Map.put(socket.assigns.streaming_content, section_id, truncated))}
  else
    {:noreply, socket}
  end
end

# Helper to find section_id from section_run_id
defp find_section_id_for_run(socket, section_run_id) do
  socket.assigns.sections
  |> Enum.find_value(fn entry ->
    if entry.last_run && to_string(entry.last_run.id) == to_string(section_run_id) do
      to_string(entry.section.id)
    end
  end)
end
```

### 3.2 Clear Streaming State on Completion

Modify the existing `:section_run_updated` handler:

```elixir
def handle_info({:section_run_updated, record_set_id}, socket) do
  if socket.assigns.record_set.id == record_set_id do
    socket = load_workspace(socket)

    # Clean up streaming content for sections no longer running
    cleaned_streaming =
      socket.assigns.streaming_content
      |> Enum.filter(fn {section_id, _} ->
        MapSet.member?(socket.assigns.running_sections, section_id)
      end)
      |> Map.new()

    {:noreply, assign(socket, :streaming_content, cleaned_streaming)}
  else
    {:noreply, socket}
  end
end
```

---

## 4. Template Changes (HEEx)

### Running Section Display

Replace the spinner-only display with streaming content:

```heex
<%= if MapSet.member?(@running_sections, to_string(section_entry.section.id)) do %>
  <div class="section-output section-streaming">
    <%# Spinner row %>
    <div class="streaming-header">
      <span class="loading loading-spinner loading-md text-slate-400"></span>
      <span class="streaming-label">Generating...</span>
    </div>

    <%# Streaming content display %>
    <%= if Map.has_key?(@streaming_content, to_string(section_entry.section.id)) do %>
      <div
        class="streaming-content"
        id={"streaming-#{section_entry.section.id}"}
        phx-hook="StreamingScroll"
      >
        <pre><code>{Map.get(@streaming_content, to_string(section_entry.section.id), "")}</code></pre>
      </div>
    <% else %>
      <div class="streaming-waiting">
        <span class="text-slate-400 text-sm">Waiting for response...</span>
      </div>
    <% end %>
  </div>
<% else %>
  <%# ... existing completed section rendering ... %>
<% end %>
```

---

## 5. ASCII Wireframe

```
+------------------------------------------------------------------+
| Section: Patient History                            [Run Section] |
+------------------------------------------------------------------+
|                                                                   |
|  [spinner] Generating...                                          |
|                                                                   |
|  +-------------------------------------------------------------+  |
|  | {                                                           |  |
|  |   "markdown": "## Patient History\n\nThe patient, a        |  |
|  |   45-year-old male, presented to the clinic with chief     |  |
|  |   complaint of persistent lower back pain radiating to     |  |
|  |   the left leg for approximately 3 weeks. The pain began   |  |
|  |   insidiously without any clear precipitating event.\n\n   |  |
|  |   ### Past Medical History\n\n- Hypertension (controlled   |  |
|  |   with lisinopril 10mg daily)\n- Type 2 Diabetes Mellitus  |  |
|  |   (HbA1c 7.2%)\n- [doc-001] Previous lumbar strain (2019)  |  |
|  |   \n\n### Current Medications\n\n- Lisinopril 10mg daily   |  |
|  |   [doc-002]\n- Metformin 500mg twice daily [doc-002:L45]   |  |
|  |   ..._                                                      |  |
|  +-------------------------------------------------------------+  |
|     ^                                                             |
|     |  Gray monospace text, auto-scrolling                        |
|     |  Semi-transparent dark background                           |
|                                                                   |
+-------------------------------------------------------------------+
```

---

## 6. CSS Styling

Add to the `<style>` block:

```css
/* Streaming Section Styles */
.section-streaming {
  display: flex;
  flex-direction: column;
  gap: 12px;
}

.streaming-header {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 8px 0;
}

.streaming-label {
  font-size: 13px;
  color: #64748b;
  font-weight: 500;
}

.streaming-content {
  background: #1e293b;
  border-radius: 8px;
  padding: 16px;
  max-height: 300px;
  overflow-y: auto;
  overflow-x: hidden;
  position: relative;
}

.streaming-content pre {
  margin: 0;
  white-space: pre-wrap;
  word-break: break-word;
}

.streaming-content code {
  font-family: 'SF Mono', 'Fira Code', 'JetBrains Mono', Consolas, monospace;
  font-size: 12px;
  line-height: 1.5;
  color: #94a3b8;
}

/* Blinking cursor effect at the end */
.streaming-content::after {
  content: '|';
  color: #3b82f6;
  animation: cursorBlink 1s step-end infinite;
  font-family: monospace;
}

@keyframes cursorBlink {
  50% { opacity: 0; }
}

/* Scrollbar styling for dark container */
.streaming-content::-webkit-scrollbar {
  width: 8px;
}

.streaming-content::-webkit-scrollbar-track {
  background: #334155;
  border-radius: 4px;
}

.streaming-content::-webkit-scrollbar-thumb {
  background: #475569;
  border-radius: 4px;
}

.streaming-content::-webkit-scrollbar-thumb:hover {
  background: #64748b;
}

.streaming-waiting {
  display: flex;
  justify-content: center;
  align-items: center;
  min-height: 100px;
  background: #f8fafc;
  border-radius: 8px;
  border: 1px dashed #e2e8f0;
}

/* Mobile responsiveness */
@media (max-width: 768px) {
  .streaming-content {
    max-height: 200px;
    padding: 12px;
  }

  .streaming-content code {
    font-size: 11px;
  }
}
```

---

## 7. JavaScript Hook for Auto-Scroll

Add to `assets/js/app.js`:

```javascript
Hooks.StreamingScroll = {
  mounted() {
    this.scrollToBottom()
    this.observer = new MutationObserver(() => {
      this.scrollToBottom()
    })
    this.observer.observe(this.el, {
      childList: true,
      subtree: true,
      characterData: true
    })
  },

  updated() {
    if (this.isNearBottom()) {
      this.scrollToBottom()
    }
  },

  destroyed() {
    if (this.observer) {
      this.observer.disconnect()
    }
  },

  scrollToBottom() {
    this.el.scrollTop = this.el.scrollHeight
  },

  isNearBottom() {
    const threshold = 50
    return (this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight) < threshold
  }
}
```

---

## 8. Performance Considerations

### Chunk Throttling (Backend)

```elixir
@batch_size 100  # characters
@batch_interval_ms 50  # milliseconds
```

### Content Truncation (Frontend)

Already handled in `handle_info` - keeps last 8000 characters.

### Memory Management

- Clear `streaming_content` entries on completion
- Truncate accumulated content if too long

---

## 9. Error Handling

Add error state handling:

```elixir
# New assign
|> assign_new(:streaming_errors, fn -> %{} end)

# Handle stream error
def handle_info({:llm_stream_error, section_run_id, error}, socket) do
  section_id = find_section_id_for_run(socket, section_run_id)

  if section_id do
    {:noreply,
     assign(socket, :streaming_errors,
       Map.put(socket.assigns.streaming_errors, section_id, error))}
  else
    {:noreply, socket}
  end
end
```

Template:

```heex
<%= if error = Map.get(@streaming_errors, to_string(section_entry.section.id)) do %>
  <div class="streaming-error">
    <span class="text-red-500 text-sm">Error: {error}</span>
  </div>
<% end %>
```

---

## 10. Transition from Streaming to Final

When the section completes:

1. `:section_run_updated` broadcast received
2. `load_workspace/1` refreshes sections with final output
3. `@running_sections` updated (section removed)
4. `@streaming_content` cleaned up
5. Template switches from streaming view to final markdown view
