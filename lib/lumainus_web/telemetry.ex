defmodule LumainusWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      # Telemetry poller will execute the given period measurements
      # every 10_000ms. Learn more here: https://hexdocs.pm/telemetry_metrics
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
      # Add reporters as children of your supervision tree.
      # {Telemetry.Metrics.ConsoleReporter, metrics: metrics()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # Phoenix Metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io"),

      # LLM Metrics
      summary("lumainus.llm.request.stop.duration",
        tags: [:model, :use_case, :mode],
        unit: {:native, :millisecond}
      ),
      sum("lumainus.llm.request.stop.input_tokens",
        tags: [:model, :use_case]
      ),
      sum("lumainus.llm.request.stop.output_tokens",
        tags: [:model, :use_case]
      ),
      sum("lumainus.llm.request.stop.cached_tokens",
        tags: [:model, :use_case]
      ),
      counter("lumainus.llm.request.start.system_time",
        tags: [:model, :use_case, :mode]
      ),
      counter("lumainus.llm.request.exception.duration",
        tags: [:model, :use_case, :error_type]
      ),
      counter("lumainus.llm.rate_limit.hit.retry_after_ms",
        tags: [:model, :reason]
      ),
      summary("lumainus.llm.concurrency.acquired.wait_ms",
        tags: [:model]
      ),
      counter("lumainus.llm.concurrency.rejected",
        tags: [:model, :reason]
      ),

      # Invocation Lifecycle Metrics
      counter("lumainus.llm.invocation.created.system_time",
        tags: [:model]
      ),
      counter("lumainus.llm.invocation.linked",
        tags: []
      ),
      summary("lumainus.llm.invocation.started.pending_ms",
        tags: [:model],
        unit: :millisecond
      ),
      counter("lumainus.llm.invocation.orphaned.logged.count",
        tags: [:model, :reason]
      ),
      summary("lumainus.llm.invocation.orphaned.logged.age_minutes",
        tags: [:model, :reason],
        unit: :minute
      ),
      counter("lumainus.llm.invocation.cleaned",
        tags: [:cleanup_type]
      ),

      # Rate limit wait metric (was missing)
      summary("lumainus.llm.rate_limit.wait.wait_ms",
        tags: [:model, :source],
        unit: :millisecond
      )
    ]
  end

  defp periodic_measurements do
    [
      # A module, function and arguments to be invoked periodically.
      # This function must call :telemetry.execute/3 and a metric must be added above.
      # {LumainusWeb, :count_users, []}
    ]
  end
end
