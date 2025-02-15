defmodule Oban.Stager do
  @moduledoc false

  use GenServer

  import Ecto.Query, only: [distinct: 2, select: 3, where: 3]

  alias Oban.{Engine, Job, Notifier, Peer, Plugin, Repo}
  alias __MODULE__, as: State

  @type option :: Plugin.option() | {:interval, pos_integer()}

  defstruct [
    :conf,
    :timer,
    interval: :timer.seconds(1),
    limit: 5_000,
    mode: :global,
    ping_at_tick: 0,
    swap_at_tick: 5,
    tick: 0
  ]

  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)

    conf = Keyword.fetch!(opts, :conf)

    if conf.stage_interval == :infinity do
      :ignore
    else
      state = %State{conf: conf, interval: conf.stage_interval}

      GenServer.start_link(__MODULE__, state, name: name)
    end
  end

  @impl GenServer
  def init(state) do
    Process.flag(:trap_exit, true)

    # Stager is no longer a plugin, but init event is essential for auto-allow and backward
    # compatibility.
    :telemetry.execute([:oban, :plugin, :init], %{}, %{conf: state.conf, plugin: __MODULE__})

    {:ok, state, {:continue, :start}}
  end

  @impl GenServer
  def handle_continue(:start, %State{} = state) do
    Notifier.listen(state.conf.name, :stager)

    if state.conf.insert_trigger do
      :telemetry.attach_many(
        "oban-stager",
        [[:oban, :engine, :insert_job, :stop], [:oban, :engine, :insert_all_jobs, :stop]],
        &__MODULE__.handle_insert/4,
        []
      )
    end

    state =
      state
      |> schedule_staging()
      |> check_notify_mode()

    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, %State{timer: timer}) do
    if is_reference(timer), do: Process.cancel_timer(timer)

    :telemetry.detach("oban-stager")

    :ok
  end

  @impl GenServer
  def handle_info(:stage, %State{} = state) do
    meta = %{conf: state.conf, plugin: __MODULE__}

    :telemetry.span([:oban, :plugin], meta, fn ->
      case check_leadership_and_stage(state) do
        {:ok, extra} when is_map(extra) ->
          {:ok, Map.merge(meta, extra)}

        error ->
          {:error, Map.put(meta, :error, error)}
      end
    end)

    state =
      state
      |> schedule_staging()
      |> check_notify_mode()

    {:noreply, state}
  end

  def handle_info({:notification, :stager, _payload}, %State{} = state) do
    if state.mode == :local do
      :telemetry.execute([:oban, :stager, :switch], %{}, %{conf: state.conf, mode: :global})
    end

    {:noreply, %{state | ping_at_tick: 60, mode: :global, swap_at_tick: 65, tick: 0}}
  end

  @doc false
  def handle_insert(_event, _measure, meta, _) do
    payload =
      case meta do
        %{job: %{queue: queue}} ->
          [%{queue: queue}]

        %{jobs: jobs} ->
          for %{queue: queue} <- jobs, uniq: true, do: %{queue: queue}

        _ ->
          []
      end

    Notifier.notify(meta.conf, :insert, payload)
  end

  defp check_leadership_and_stage(state) do
    leader? = Peer.leader?(state.conf)

    Repo.transaction(state.conf, fn ->
      {:ok, staged} = stage_scheduled(state, leader?: leader?)

      notify_queues(state, leader?: leader?)

      %{staged_count: length(staged), staged_jobs: staged}
    end)
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, error}
  end

  defp stage_scheduled(state, leader?: true) do
    Engine.stage_jobs(state.conf, Job, limit: state.limit)
  end

  defp stage_scheduled(_state, _leader), do: {:ok, []}

  defp notify_queues(%State{conf: conf, mode: :global}, leader?: true) do
    query =
      Job
      |> where([j], j.state == "available")
      |> where([j], not is_nil(j.queue))
      |> select([j], %{queue: j.queue})
      |> distinct(true)

    payload = Repo.all(conf, query)

    Notifier.notify(conf, :insert, payload)
  end

  defp notify_queues(%State{conf: conf, mode: :local}, _leader) do
    match = [{{{conf.name, {:producer, :"$1"}}, :"$2", :_}, [], [{{:"$1", :"$2"}}]}]

    for {queue, pid} <- Registry.select(Oban.Registry, match) do
      send(pid, {:notification, :insert, %{"queue" => queue}})
    end
  end

  defp notify_queues(_state, _leader), do: :ok

  # Scheduling

  defp schedule_staging(state) do
    timer = Process.send_after(self(), :stage, state.interval)

    %{state | timer: timer}
  end

  defp check_notify_mode(state) do
    if state.tick >= state.ping_at_tick do
      Notifier.notify(state.conf.name, :stager, %{ping: :pong})
    end

    if state.mode == :global and state.tick == state.swap_at_tick do
      :telemetry.execute([:oban, :stager, :switch], %{}, %{conf: state.conf, mode: :local})

      %{state | mode: :local}
    else
      %{state | tick: state.tick + 1}
    end
  end
end
