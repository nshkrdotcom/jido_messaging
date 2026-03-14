defmodule Jido.Messaging.AgentRunner do
  @moduledoc """
  GenServer that manages an agent's participation in a specific room thread.

  Each assigned thread gets its own AgentRunner process that:
  - Subscribes to room-level `message_added` signals
  - Filters down to one room/thread assignment
  - Invokes the configured handler
  - Delivers replies through `Jido.Messaging.Deliver`
  """

  use GenServer
  require Logger

  alias Jido.Chat.Participant
  alias Jido.Messaging.{Context, Deliver, Message, RoomServer, Signal}
  alias Jido.Messaging.Supervisor, as: MessagingSupervisor

  @schema Zoi.struct(
            __MODULE__,
            %{
              room_id: Zoi.string(),
              thread_id: Zoi.string(),
              agent_id: Zoi.string(),
              agent_config: Zoi.map(),
              instance_module: Zoi.any(),
              subscribed: Zoi.boolean() |> Zoi.default(false)
            },
            coerce: false
          )

  @type agent_config :: %{
          required(:agent_id) => String.t(),
          required(:handler) => (map(), map() -> {:reply, String.t()} | :noreply | {:error, term()}),
          required(:name) => String.t(),
          optional(:mention_handles) => [String.t()],
          optional(:trigger) => atom()
        }

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema."
  def schema, do: @schema

  @doc """
  Start an AgentRunner for an assigned room thread.

  Required options:
  - `:room_id`
  - `:thread_id`
  - `:agent_id`
  - `:agent_config`
  - `:instance_module`
  """
  def start_link(opts) do
    room_id = Keyword.fetch!(opts, :room_id)
    thread_id = Keyword.fetch!(opts, :thread_id)
    agent_id = Keyword.fetch!(opts, :agent_id)
    instance_module = Keyword.fetch!(opts, :instance_module)

    GenServer.start_link(
      __MODULE__,
      opts,
      name: via_tuple(instance_module, room_id, thread_id, agent_id)
    )
  end

  @doc "Generate a registry via tuple."
  def via_tuple(instance_module, room_id, thread_id, agent_id) do
    registry = Module.concat(instance_module, Registry.Agents)
    {:via, Registry, {registry, {room_id, thread_id, agent_id}}}
  end

  @doc "Get current runner state."
  def get_state(server), do: GenServer.call(server, :get_state)

  @doc "Gracefully stop the runner."
  def stop(server), do: GenServer.stop(server, :normal)

  @doc "Check if a thread-scoped agent runner is running."
  def whereis(instance_module, room_id, thread_id, agent_id) do
    registry = Module.concat(instance_module, Registry.Agents)

    case Registry.lookup(registry, {room_id, thread_id, agent_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @impl true
  def init(opts) do
    room_id = Keyword.fetch!(opts, :room_id)
    thread_id = Keyword.fetch!(opts, :thread_id)
    agent_id = Keyword.fetch!(opts, :agent_id)
    agent_config = Keyword.fetch!(opts, :agent_config)
    instance_module = Keyword.fetch!(opts, :instance_module)

    state =
      struct!(__MODULE__, %{
        room_id: room_id,
        thread_id: thread_id,
        agent_id: agent_id,
        agent_config: agent_config,
        instance_module: instance_module,
        subscribed: false
      })

    register_as_participant(state)
    send(self(), :subscribe)

    Logger.debug(
      "[Jido.Messaging.AgentRunner] Agent #{agent_id} started in room #{room_id} thread #{thread_id}"
    )

    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state), do: {:reply, state, state}

  @impl true
  def handle_info(:subscribe, state) do
    bus_name = MessagingSupervisor.signal_bus_name(state.instance_module)

    case Jido.Signal.Bus.subscribe(bus_name, "jido.messaging.room.message_added") do
      {:ok, _subscription_id} ->
        {:noreply, %{state | subscribed: true}}

      {:error, _reason} ->
        Process.send_after(self(), :subscribe, 100)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:signal, signal}, state) do
    handle_signal(signal, state)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Logger.debug(
      "[Jido.Messaging.AgentRunner] Agent #{state.agent_id} stopping in room #{state.room_id} thread #{state.thread_id}"
    )

    :ok
  end

  defp handle_signal(%{type: "jido.messaging.room.message_added"} = signal, state) do
    room_id = signal.data.room_id
    message = signal.data.message
    context = Map.get(signal.data, :context)

    if should_handle_message?(room_id, message, state) do
      handle_triggered_message(message, context, state)
    end
  end

  defp handle_signal(_signal, _state), do: :ok

  defp should_handle_message?(room_id, %Message{} = message, state) do
    room_id == state.room_id and
      message.thread_id == state.thread_id and
      message.sender_id != state.agent_id
  end

  defp handle_triggered_message(message, delivery_context, state) do
    Signal.emit_agent(:triggered, state.instance_module, state.room_id, state.agent_id, %{
      message_id: message.id,
      thread_id: state.thread_id
    })

    handler_context = %{
      room_id: state.room_id,
      thread_id: state.thread_id,
      agent_id: state.agent_id,
      agent_name: state.agent_config.name,
      mention_handles: Map.get(state.agent_config, :mention_handles, []),
      instance_module: state.instance_module,
      delivery_context: delivery_context
    }

    Signal.emit_agent(:started, state.instance_module, state.room_id, state.agent_id, %{
      message_id: message.id,
      thread_id: state.thread_id
    })

    case state.agent_config.handler.(message, handler_context) do
      {:reply, text} ->
        case send_reply(text, message, delivery_context, state) do
          {:ok, reply_message} ->
            Signal.emit_agent(:completed, state.instance_module, state.room_id, state.agent_id, %{
              message_id: message.id,
              thread_id: state.thread_id,
              response: :reply,
              reply_message_id: reply_message.id
            })

          {:error, reason} ->
            Signal.emit_agent(:failed, state.instance_module, state.room_id, state.agent_id, %{
              message_id: message.id,
              thread_id: state.thread_id,
              error: inspect(reason)
            })
        end

      :noreply ->
        Signal.emit_agent(:completed, state.instance_module, state.room_id, state.agent_id, %{
          message_id: message.id,
          thread_id: state.thread_id,
          response: :noreply
        })

      {:error, reason} ->
        Signal.emit_agent(:failed, state.instance_module, state.room_id, state.agent_id, %{
          message_id: message.id,
          thread_id: state.thread_id,
          error: inspect(reason)
        })
    end
  end

  defp send_reply(_text, _message, nil, _state), do: {:error, :missing_delivery_context}

  defp send_reply(text, original_message, %Context{} = delivery_context, state) do
    delivery_context =
      %{
        delivery_context
        | thread_id: state.thread_id,
          external_thread_id:
            delivery_context.external_thread_id || original_message.external_thread_id,
          delivery_external_room_id:
            delivery_context.delivery_external_room_id || original_message.delivery_external_room_id
      }

    Deliver.deliver_outgoing(state.instance_module, original_message, text, delivery_context,
      sender_id: state.agent_id,
      sender_name: state.agent_config.name
    )
  end

  defp send_reply(text, original_message, delivery_context, state) when is_map(delivery_context) do
    Deliver.deliver_outgoing(state.instance_module, original_message, text, delivery_context,
      sender_id: state.agent_id,
      sender_name: state.agent_config.name
    )
  end

  defp register_as_participant(state) do
    participant =
      Participant.new(%{
        id: state.agent_id,
        type: :agent,
        identity: %{name: state.agent_config.name},
        presence: :online
      })

    case RoomServer.whereis(state.instance_module, state.room_id) do
      nil -> :ok
      pid -> RoomServer.add_participant(pid, participant)
    end
  end
end
