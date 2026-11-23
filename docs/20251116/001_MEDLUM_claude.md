# Medlum - Self-Aware LLM Runtime

**Tagline**: "Every token has a traceable decision path. Every claim has attributable evidence. Every response has measurable confidence."

## Core Concept

Turn the LLM from a black-box oracle into a **fully instrumented, auditable reasoning system** where every decision is visible, traceable, and statistically validated.

## Architecture

### Layer 0: Foundation (Elixir/OTP)
```
┌─────────────────────────────────────────┐
│  Supervision Tree                       │
│  ├─ LLM Connection Pool (GenServers)   │
│  ├─ Telemetry Registry                 │
│  ├─ Trace Buffer (ETS)                 │
│  └─ Health Monitor                     │
└─────────────────────────────────────────┘
```

### Layer 1: Instrumented LLM Core

**Instead of**: `llm.generate(prompt) -> text`

**We have**: 
```elixir
defmodule Medlum.Core do
  def traced_generate(prompt, opts \\ []) do
    trace_id = UUID.generate()
    
    # Start trace context
    Crucible.Trace.start_trace(trace_id, %{
      prompt: prompt,
      model: opts[:model],
      timestamp: DateTime.utc_now()
    })
    
    # Generate with full token-level telemetry
    result = with_telemetry(trace_id) do
      LLM.generate(prompt, opts)
    end
    
    # Record decision graph
    Crucible.Trace.record_generation(trace_id, %{
      tokens: result.tokens,
      probabilities: result.token_probs,
      attention_weights: result.attention,
      latency_per_token: result.timing
    })
    
    {:ok, result, trace_id}
  end
end
```

Every single token gets:
- Probability distribution
- Attention attribution (which prompt tokens influenced this?)
- Latency
- Alternative tokens considered
- Temperature/sampling params

### Layer 2: Multi-Agent Critic Pipeline

**Not** a single LLM call. Every response goes through:

```elixir
defmodule Medlum.Pipeline do
  def process_query(user_query) do
    trace_id = start_pipeline_trace(user_query)
    
    # Stage 1: Proposal Generation
    candidates = Proposer.generate_candidates(user_query, n: 3)
    |> trace_stage(:proposal, trace_id)
    
    # Stage 2: Parallel Critic Evaluation
    evaluations = candidates
    |> Enum.map(fn candidate ->
      Task.async(fn ->
        %{
          logic: LogicCritic.evaluate(candidate),
          grounding: GroundingCritic.evaluate(candidate),
          safety: SafetyCritic.evaluate(candidate),
          bias: BiasCritic.evaluate(candidate),
          novelty: NoveltyCritic.evaluate(candidate)
        }
      end)
    end)
    |> Task.await_many()
    |> trace_stage(:critics, trace_id)
    
    # Stage 3: Ensemble Voting
    selected = Crucible.Ensemble.vote(
      candidates,
      evaluations,
      strategy: :weighted_confidence
    )
    |> trace_stage(:ensemble, trace_id)
    
    # Stage 4: Statistical Validation
    validation = Crucible.Bench.validate_output(
      selected,
      baseline_distribution: get_baseline(),
      tests: [:ks_test, :chi_square, :effect_size]
    )
    |> trace_stage(:validation, trace_id)
    
    # Stage 5: Causal Attribution
    attribution = AttributionGraph.build(trace_id)
    
    %Response{
      text: selected.text,
      trace_id: trace_id,
      confidence: selected.confidence,
      attribution: attribution,
      validation: validation,
      full_trace: Crucible.Trace.get_trace(trace_id)
    }
  end
end
```

### Layer 3: Attribution Graph Engine

**The Killer Feature** - for every claim in the output, trace it back:

```elixir
defmodule Medlum.Attribution do
  def build_claim_graph(response, trace_id) do
    # Parse response into atomic claims
    claims = ClaimExtractor.parse(response.text)
    
    # For each claim, build decision tree
    Enum.map(claims, fn claim ->
      %ClaimNode{
        text: claim.text,
        decision_path: trace_decision_path(claim, trace_id),
        evidence_sources: link_to_evidence(claim),
        critic_scores: get_critic_scores(claim, trace_id),
        token_attributions: get_token_attributions(claim, trace_id),
        confidence_bounds: calculate_confidence(claim, trace_id)
      }
    end)
    |> build_dag()
  end
  
  defp trace_decision_path(claim, trace_id) do
    # Which prompt components influenced this claim?
    # Which prior tokens in the response influenced it?
    # Which critic approved/rejected related candidates?
    # What temperature/sampling led to this phrasing?
    
    Crucible.Trace.query(trace_id, %{
      type: :claim_generation,
      claim_id: claim.id
    })
  end
end
```

### Layer 4: Real-Time Health Monitoring

```elixir
defmodule Medlum.HealthMonitor do
  use GenServer
  
  def init(_) do
    # Subscribe to all telemetry events
    :telemetry.attach_many(
      "luminous-health",
      [
        [:luminous, :response, :complete],
        [:luminous, :critic, :score],
        [:luminous, :validation, :result]
      ],
      &handle_telemetry/4,
      nil
    )
    
    {:ok, %{
      metrics: MetricsAggregator.new(),
      drift_detector: DriftDetector.new(),
      alert_thresholds: load_thresholds()
    }}
  end
  
  def handle_telemetry(event, measurements, metadata, state) do
    # Update rolling metrics
    metrics = MetricsAggregator.update(state.metrics, event, measurements)
    
    # Check for distribution drift
    case DriftDetector.check(state.drift_detector, measurements) do
      {:drift_detected, report} ->
        alert_ops_team(report)
        
      :ok ->
        :ok
    end
    
    # Check critic agreement rates
    if critic_disagreement_spiking?(metrics) do
      flag_for_review(metadata)
    end
    
    {:noreply, %{state | metrics: metrics}}
  end
end
```

## Demo App: "Medlum Chat" - The Transparent Research Assistant

### UI Layout

```
┌─────────────────────────────────────────────────────────────┐
│  User: What's the evidence for vitamin C preventing colds?  │
└─────────────────────────────────────────────────────────────┘

┌─ DECISION PIPELINE ─────────────────────────────────────────┐
│ [●●●●●○○] Processing...                                      │
│                                                              │
│ ✓ Proposal Generation (3 candidates, 1.2s)                  │
│   ├─ Candidate A: Medical consensus summary                 │
│   ├─ Candidate B: Nuanced meta-analysis cite                │
│   └─ Candidate C: General health advice                     │
│                                                              │
│ ✓ Critic Evaluation (parallel, 0.8s)                        │
│   ├─ Logic:     A:0.92  B:0.95  C:0.78                      │
│   ├─ Grounding: A:0.67  B:0.91  C:0.45 ← B wins             │
│   ├─ Safety:    A:1.00  B:1.00  C:1.00                      │
│   ├─ Bias:      A:0.88  B:0.93  C:0.81                      │
│   └─ Novelty:   A:0.75  B:0.82  C:0.71                      │
│                                                              │
│ ✓ Ensemble Vote: Candidate B selected (confidence: 0.89)    │
│                                                              │
│ ✓ Statistical Validation                                    │
│   ├─ KS test vs baseline: p=0.72 (no drift)                │
│   ├─ Cohen's d effect size: 0.12 (negligible)              │
│   └─ Evidence coverage: 100% (3/3 claims cited)            │
└──────────────────────────────────────────────────────────────┘

┌─ RESPONSE ──────────────────────────────────────────────────┐
│                                                              │
│ Research shows vitamin C supplementation has minimal effect │
│ on cold prevention in the general population¹. However, it  │
│ may reduce cold duration by ~8% in some studies². The       │
│ evidence is strongest for people under extreme physical     │
│ stress³.                                                     │
│                                                              │
│ [Show Full Attribution Graph] [Export Trace] [Challenge]    │
└──────────────────────────────────────────────────────────────┘

┌─ ATTRIBUTION GRAPH (Click to expand) ───────────────────────┐
│                                                              │
│ Claim 1: "minimal effect on cold prevention"                │
│ ├─ Evidence: Cochrane Review 2013 (29 trials, N=11,306)    │
│ ├─ Token Attribution:                                       │
│ │  └─ "minimal" (p=0.73) influenced by prompt: "evidence"  │
│ │  └─ "prevention" (p=0.91) from cited abstract           │
│ ├─ Critic Scores:                                          │
│ │  └─ Logic: 0.95, Grounding: 0.92, Safety: 1.0          │
│ └─ Confidence: HIGH (bootstrap CI: [0.88, 0.96])          │
│                                                              │
│ Claim 2: "reduce cold duration by ~8%"                      │
│ ├─ Evidence: Same Cochrane review, subgroup analysis        │
│ ├─ Token Attribution:                                       │
│ │  └─ "~8%" (p=0.81) - hedging due to heterogeneity flag  │
│ ├─ Critic Scores:                                          │
│ │  └─ Logic: 0.88, Grounding: 0.85, Safety: 1.0          │
│ └─ Confidence: MEDIUM (wide effect size range in source)   │
│                                                              │
│ Claim 3: "strongest for extreme physical stress"            │
│ ├─ Evidence: Subgroup in same meta-analysis                 │
│ ├─ Critic Scores:                                          │
│ │  └─ Logic: 0.91, Grounding: 0.89, Safety: 1.0          │
│ └─ Confidence: MEDIUM-HIGH                                  │
└──────────────────────────────────────────────────────────────┘

┌─ SYSTEM HEALTH ──────────────────────────────────────────────┐
│ Response Time: 2.3s (p50: 1.8s, p95: 4.2s) ✓                │
│ Critic Agreement: 94% (baseline: 91%, δ: +3%) ✓             │
│ Evidence Coverage: 100% (baseline: 78%, δ: +22%) ✓          │
│ Distribution Drift: NONE (KS test p=0.72) ✓                 │
│ Safety Interventions (24h): 0 ✓                             │
└──────────────────────────────────────────────────────────────┘
```

### Key Features

1. **Full Decision Transparency**: User sees the ENTIRE pipeline, not just final output
2. **Traceable Claims**: Every assertion links back to evidence + decision path
3. **Real-Time Health**: System shows you when it's drifting or uncertain
4. **Exportable Traces**: Download the full JSON trace for auditing
5. **Challenge Mode**: User can flag claims, triggering re-evaluation with stricter critics

## Technical Stack

```
Frontend (LiveView)
├─ Real-time pipeline status updates
├─ Interactive attribution graph visualization
└─ Health metrics dashboard

Backend (Elixir/OTP)
├─ Medlum.Core (instrumented LLM calls)
├─ Medlum.Pipeline (multi-agent critics)
├─ Medlum.Attribution (causal graphs)
├─ Medlum.HealthMonitor (drift detection)
└─ Crucible Framework
    ├─ crucible_trace (decision logging)
    ├─ crucible_bench (statistical validation)
    ├─ crucible_ensemble (voting)
    ├─ ExDataCheck (quality gates)
    └─ LlmGuard (safety)

Data Layer
├─ PostgreSQL (traces, metrics)
├─ TimescaleDB (time-series telemetry)
└─ Neo4j (attribution graphs)
```

## Why This Changes Everything

**Traditional LLM**: "Here's an answer" (trust me)

**Medlum**: "Here's an answer, here's how I decided it, here's the evidence, here's my confidence bounds, here's the full trace, here's how I compare to my baseline behavior, and here's a real-time health check showing I'm not drifting"

It's the difference between a black-box AI and a **collaborator you can actually trust and audit**.

Want me to spec out the actual Elixir modules in detail?
