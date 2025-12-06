# Gemini Use-Case Model Mapping (Lumainus)

## Context
- Lumainus currently overrides models when using cached context; this scattered string usage leads to drift and surprises (e.g., cache forcing `gemini-2.5-flash`).
- We want a single source of truth for model selection based on use case, backed by gemini_ex’s model registry.

## Use Cases → Models (via gemini_ex atoms)
- `:cache_context` → `:pro_3_preview` (cache-compatible, higher quality)
- `:report_section` → `:pro_3_preview` (main section generation)
- `:quick_analysis` → `:flash_2_5` (fast/cheap path)

Resolve to model strings with `Gemini.Config.get_model/1` so updates flow from gemini_ex without touching Lumainus code.

## Plan
1) Persist use-case keys (strings) in DB instead of raw model strings (e.g., cache_settings.model = "cache_context").
2) On load, resolve use-case → model string; validate against gemini_ex registry; warn on unknown.
3) UI/Admin: show use-cases with their resolved models and token minima; prevent entry of raw model strings.
4) Section runner: when cached, resolve `:cache_context`; when uncached, resolve `:report_section`. No hardcoded `"google:gemini-*"` in code.
5) Include token minima per use-case for validation: derive from gemini_ex registry (e.g., pro_3_preview min_tokens 2048).

## Next Steps
- Add migration to convert existing model strings to use-case keys.
- Wire resolver in cache manager/section runner.
- Update admin UI options to list use-cases, not raw models.
