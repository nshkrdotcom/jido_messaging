defmodule Jido.Messaging.AgentRunnerTest do
  use ExUnit.Case, async: false

  import Jido.Messaging.TestHelpers

  alias Jido.Messaging.{AgentRunner, Ingest, Message}

  defmodule TestMessaging do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.ETS
  end

  defmodule NotifyChannel do
    @behaviour Jido.Chat.Adapter

    @impl true
    def channel_type, do: :notify

    @impl true
    def transform_incoming(_), do: {:error, :not_implemented}

    @impl true
    def send_message(room_id, text, opts) do
      send(notify_pid(), {:channel_send, room_id, text, opts})
      {:ok, %{message_id: "sent-" <> Integer.to_string(System.unique_integer([:positive]))}}
    end

    @impl true
    def open_thread(external_room_id, external_message_id, opts) do
      result = %{
        external_thread_id: "thread-" <> to_string(external_message_id),
        delivery_external_room_id: "delivery-" <> to_string(external_message_id)
      }

      send(notify_pid(), {:thread_opened, external_room_id, external_message_id, opts, result})
      {:ok, result}
    end

    defp notify_pid do
      :persistent_term.get({__MODULE__, :notify_pid})
    end
  end

  setup do
    start_supervised!(TestMessaging)
    :persistent_term.put({NotifyChannel, :notify_pid}, self())

    on_exit(fn ->
      :persistent_term.erase({NotifyChannel, :notify_pid})
    end)

    :ok
  end

  describe "thread-scoped runner lifecycle" do
    test "assign_thread/3 starts a runner keyed by room, thread, and agent" do
      room = create_room!("runner-room")
      thread = create_thread!(room.id, "ext-thread-1")

      assert {:ok, _agent_spec} =
               TestMessaging.register_agent(room.id, %{
                 agent_id: "alpha",
                 name: "Alpha",
                 handler: fn _, _ -> :noreply end
               })

      assert {:ok, assigned_thread} = TestMessaging.assign_thread(room.id, thread.id, "alpha")
      assert assigned_thread.assigned_agent_id == "alpha"
      assert {:ok, "alpha"} = TestMessaging.thread_assignment(room.id, thread.id)

      assert_eventually(fn ->
        AgentRunner.whereis(TestMessaging, room.id, thread.id, "alpha") != nil
      end)
    end

    test "assign_thread/3 is idempotent when the thread is already assigned to the same agent" do
      room = create_room!("runner-idempotent-room")
      thread = create_thread!(room.id, "ext-thread-idempotent")

      assert {:ok, _agent_spec} =
               TestMessaging.register_agent(room.id, %{
                 agent_id: "alpha",
                 name: "Alpha",
                 handler: fn _, _ -> :noreply end
               })

      assert {:ok, _assigned_thread} = TestMessaging.assign_thread(room.id, thread.id, "alpha")

      assert_eventually(fn ->
        AgentRunner.whereis(TestMessaging, room.id, thread.id, "alpha") != nil
      end)

      pid = AgentRunner.whereis(TestMessaging, room.id, thread.id, "alpha")

      assert {:ok, reassigned_thread} = TestMessaging.assign_thread(room.id, thread.id, "alpha")
      assert reassigned_thread.assigned_agent_id == "alpha"
      assert {:ok, "alpha"} = TestMessaging.thread_assignment(room.id, thread.id)
      assert AgentRunner.whereis(TestMessaging, room.id, thread.id, "alpha") == pid
    end

    test "register_agent/3 restores persisted thread assignments for that agent" do
      room = create_room!("runner-restore-room")

      {:ok, thread} =
        TestMessaging.save_thread(%{
          room_id: room.id,
          external_thread_id: "ext-thread-restored",
          delivery_external_room_id: "delivery-restored",
          assigned_agent_id: "alpha"
        })

      assert {:ok, _agent_spec} =
               TestMessaging.register_agent(room.id, %{
                 agent_id: "alpha",
                 name: "Alpha",
                 handler: fn _, _ -> :noreply end
               })

      assert {:ok, "alpha"} = TestMessaging.thread_assignment(room.id, thread.id)

      assert_eventually(fn ->
        AgentRunner.whereis(TestMessaging, room.id, thread.id, "alpha") != nil
      end)
    end

    test "assign_thread/3 rejects threads from a different room" do
      room_a = create_room!("runner-room-a")
      room_b = create_room!("runner-room-b")
      thread = create_thread!(room_a.id, "ext-thread-room-a")

      assert {:ok, _agent_spec} =
               TestMessaging.register_agent(room_b.id, %{
                 agent_id: "alpha",
                 name: "Alpha",
                 handler: fn _, _ -> :noreply end
               })

      assert {:error, :thread_room_mismatch} =
               TestMessaging.assign_thread(room_b.id, thread.id, "alpha")

      assert {:error, :thread_room_mismatch} =
               TestMessaging.thread_assignment(room_b.id, thread.id)

      assert {:error, :thread_room_mismatch} =
               TestMessaging.unassign_thread(room_b.id, thread.id)
    end

    test "thread assignment APIs reject threads from a nonexistent room id" do
      room = create_room!("runner-room-real")
      thread = create_thread!(room.id, "ext-thread-real")

      assert {:ok, _agent_spec} =
               TestMessaging.register_agent(room.id, %{
                 agent_id: "alpha",
                 name: "Alpha",
                 handler: fn _, _ -> :noreply end
               })

      assert {:ok, _assigned_thread} = TestMessaging.assign_thread(room.id, thread.id, "alpha")

      assert {:error, :thread_room_mismatch} =
               TestMessaging.assign_thread("missing-room", thread.id, "alpha")

      assert {:error, :thread_room_mismatch} =
               TestMessaging.thread_assignment("missing-room", thread.id)

      assert {:error, :thread_room_mismatch} =
               TestMessaging.unassign_thread("missing-room", thread.id)
    end

    test "thread_assignment/3 falls back to the persisted assignment when room state drifts" do
      room = create_room!("runner-fallback-room")
      thread = create_thread!(room.id, "ext-thread-fallback")

      assert {:ok, _agent_spec} =
               TestMessaging.register_agent(room.id, %{
                 agent_id: "alpha",
                 name: "Alpha",
                 handler: fn _, _ -> :noreply end
               })

      assert {:ok, _assigned_thread} = TestMessaging.assign_thread(room.id, thread.id, "alpha")
      room_server = ensure_room_server!(room)

      assert :ok = Jido.Messaging.RoomServer.unassign_thread(room_server, thread.id)
      assert {:ok, "alpha"} = TestMessaging.thread_assignment(room.id, thread.id)
    end

    test "assign_thread/3 rolls back persisted and room state when the agent supervisor is unavailable" do
      room = create_room!("runner-start-failure-room")
      thread = create_thread!(room.id, "ext-thread-start-failure")

      assert {:ok, _agent_spec} =
               TestMessaging.register_agent(room.id, %{
                 agent_id: "alpha",
                 name: "Alpha",
                 handler: fn _, _ -> :noreply end
               })

      room_server = ensure_room_server!(room)

      with_agent_supervisor_unavailable(TestMessaging, fn ->
        assert {:error, {:supervisor_unavailable, _reason}} =
                 Jido.Messaging.AgentSupervisor.start_agent(
                   TestMessaging,
                   room.id,
                   thread.id,
                   "alpha",
                   %{agent_id: "alpha", name: "Alpha", handler: fn _, _ -> :noreply end}
                 )

        assert {:error, {:start_agent_failed, {:supervisor_unavailable, _reason}}} =
                 TestMessaging.assign_thread(room.id, thread.id, "alpha")

        assert {:ok, nil} = TestMessaging.thread_assignment(room.id, thread.id)
        assert Jido.Messaging.RoomServer.thread_assignment(room_server, thread.id) == nil

        assert {:ok, persisted_thread} = TestMessaging.get_thread(thread.id)
        assert is_nil(persisted_thread.assigned_agent_id)
        assert AgentRunner.whereis(TestMessaging, room.id, thread.id, "alpha") == nil
      end)
    end

    test "agent supervisor restart rehydrates assigned runners" do
      room = create_room!("runner-supervisor-restart-room")
      thread = create_thread!(room.id, "ext-thread-restart")

      assert {:ok, _agent_spec} =
               TestMessaging.register_agent(room.id, %{
                 agent_id: "alpha",
                 name: "Alpha",
                 handler: fn _, _ -> :noreply end
               })

      assert {:ok, _assigned_thread} = TestMessaging.assign_thread(room.id, thread.id, "alpha")

      assert_eventually(fn ->
        AgentRunner.whereis(TestMessaging, room.id, thread.id, "alpha") != nil
      end, timeout: 500)

      original_runner = AgentRunner.whereis(TestMessaging, room.id, thread.id, "alpha")
      agent_supervisor_name = TestMessaging.__jido_messaging__(:agent_supervisor)
      original_supervisor = Process.whereis(agent_supervisor_name)
      assert is_pid(original_supervisor)

      Process.exit(original_supervisor, :kill)

      assert_eventually(fn ->
        restarted_supervisor = Process.whereis(agent_supervisor_name)
        restarted_runner = AgentRunner.whereis(TestMessaging, room.id, thread.id, "alpha")

        is_pid(restarted_supervisor) and restarted_supervisor != original_supervisor and
          is_pid(restarted_runner) and restarted_runner != original_runner
      end, timeout: 1_000)

      assert {:ok, "alpha"} = TestMessaging.thread_assignment(room.id, thread.id)
    end

    test "room server restart restores registered agents and thread assignments from live runners" do
      room = create_room!("runner-room-restart-room")
      thread = create_thread!(room.id, "ext-thread-room-restart")

      assert {:ok, _agent_spec} =
               TestMessaging.register_agent(room.id, %{
                 agent_id: "alpha",
                 name: "Alpha",
                 handler: fn _, _ -> :noreply end
               })

      assert {:ok, _assigned_thread} = TestMessaging.assign_thread(room.id, thread.id, "alpha")

      assert_eventually(fn ->
        AgentRunner.whereis(TestMessaging, room.id, thread.id, "alpha") != nil
      end, timeout: 500)

      original_room_server = ensure_room_server!(room)
      runner_pid = AgentRunner.whereis(TestMessaging, room.id, thread.id, "alpha")
      ref = Process.monitor(original_room_server)

      assert :ok = TestMessaging.stop_room_server(room.id)
      assert_receive {:DOWN, ^ref, :process, ^original_room_server, _reason}, 500
      assert AgentRunner.whereis(TestMessaging, room.id, thread.id, "alpha") == runner_pid

      {:ok, restarted_room_server} = TestMessaging.get_or_start_room_server(room)
      assert Process.alive?(restarted_room_server)

      assert_eventually(
        fn ->
          with {:ok, agents} <- TestMessaging.list_agents(room.id) do
            Enum.any?(agents, &(&1.agent_id == "alpha")) and
              Jido.Messaging.RoomServer.thread_assignment(restarted_room_server, thread.id) == "alpha"
          else
            _ -> false
          end
        end,
        timeout: 500
      )

      assert {:ok, "alpha"} = TestMessaging.thread_assignment(room.id, thread.id)
    end
  end

  describe "thread-scoped message handling" do
    test "runners only receive messages from their assigned thread" do
      test_pid = self()
      room = create_room!("routing-room")
      thread_a = create_thread!(room.id, "thread-a")
      thread_b = create_thread!(room.id, "thread-b")

      assert {:ok, _alpha_spec} =
               TestMessaging.register_agent(room.id, %{
                 agent_id: "alpha",
                 name: "Alpha",
                 handler: fn message, _context ->
                   send(test_pid, {:alpha_received, message.thread_id, message.id})
                   :noreply
                 end
               })

      assert {:ok, _beta_spec} =
               TestMessaging.register_agent(room.id, %{
                 agent_id: "beta",
                 name: "Beta",
                 handler: fn message, _context ->
                   send(test_pid, {:beta_received, message.thread_id, message.id})
                   :noreply
                 end
               })

      {:ok, _} = TestMessaging.assign_thread(room.id, thread_a.id, "alpha")
      {:ok, _} = TestMessaging.assign_thread(room.id, thread_b.id, "beta")

      room_pid = ensure_room_server!(room)

      :ok =
        Jido.Messaging.RoomServer.add_message(
          room_pid,
          message(room.id, "user-1", thread_a.id, "hello alpha"),
          nil
        )

      :ok =
        Jido.Messaging.RoomServer.add_message(
          room_pid,
          message(room.id, "user-2", thread_b.id, "hello beta"),
          nil
        )

      thread_a_id = thread_a.id
      thread_b_id = thread_b.id

      assert_receive {:alpha_received, ^thread_a_id, _message_id}, 1_000
      assert_receive {:beta_received, ^thread_b_id, _message_id}, 1_000
      refute_receive {:alpha_received, ^thread_b_id, _message_id}, 100
      refute_receive {:beta_received, ^thread_a_id, _message_id}, 100
    end
  end

  describe "auto-assignment from ingress" do
    test "a single logical agent mention opens a thread, assigns it, and routes the reply there" do
      test_pid = self()

      {:ok, room} =
        TestMessaging.get_or_create_room_by_external_binding(
          :notify,
          "bridge-auto",
          "room-auto",
          %{type: :channel}
        )

      assert {:ok, _agent_spec} =
               TestMessaging.register_agent(room.id, %{
                 agent_id: "alpha",
                 name: "Alpha",
                 handler: fn message, _context ->
                   send(test_pid, {:agent_handled, message.id, message.thread_id})
                   {:reply, "handled by alpha"}
                 end
               })

      incoming = %{
        external_room_id: "room-auto",
        external_user_id: "user-1",
        external_message_id: "root-1",
        text: "@alpha please handle this",
        chat_type: :channel
      }

      assert {:ok, message, context} =
               Ingest.ingest_incoming(TestMessaging, NotifyChannel, "bridge-auto", incoming)

      assert message.thread_id
      assert context.thread_id == message.thread_id

      assert_receive {:thread_opened, "room-auto", "root-1", _opts, result}, 1_000
      assert result.external_thread_id == "thread-root-1"

      assert {:ok, [thread]} = TestMessaging.list_threads(room.id)
      assert thread.id == message.thread_id
      assert thread.external_thread_id == "thread-root-1"
      assert thread.delivery_external_room_id == "delivery-root-1"
      assert thread.root_message_id == message.id
      assert {:ok, "alpha"} = TestMessaging.thread_assignment(room.id, thread.id)

      message_id = message.id
      thread_id = thread.id
      assert_receive {:agent_handled, ^message_id, ^thread_id}, 1_000

      assert_receive {:channel_send, "delivery-root-1", "handled by alpha", opts}, 1_000
      assert opts[:external_thread_id] == "thread-root-1"
      assert opts[:delivery_external_room_id] == "delivery-root-1"
    end

    test "ambiguous agent mentions do not auto-assign a thread" do
      {:ok, room} =
        TestMessaging.get_or_create_room_by_external_binding(
          :notify,
          "bridge-ambiguous",
          "room-ambiguous",
          %{type: :channel}
        )

      for agent_id <- ["alpha", "beta"] do
        assert {:ok, _agent_spec} =
                 TestMessaging.register_agent(room.id, %{
                   agent_id: agent_id,
                   name: String.capitalize(agent_id),
                   handler: fn _, _ -> {:reply, "should not run"} end
                 })
      end

      incoming = %{
        external_room_id: "room-ambiguous",
        external_user_id: "user-1",
        external_message_id: "root-2",
        text: "@alpha @beta who should handle this?",
        chat_type: :channel
      }

      assert {:ok, message, context} =
               Ingest.ingest_incoming(TestMessaging, NotifyChannel, "bridge-ambiguous", incoming)

      assert is_nil(message.thread_id)
      assert is_nil(context.thread_id)
      assert {:ok, []} = TestMessaging.list_threads(room.id)
      refute_receive {:thread_opened, _, _, _, _}, 200
      refute_receive {:channel_send, _, _, _}, 200
    end
  end

  describe "agent unregistration" do
    test "unregister_agent/2 clears persisted thread assignments" do
      room = create_room!("runner-unregister-room")
      thread = create_thread!(room.id, "ext-thread-unregister")

      assert {:ok, _agent_spec} =
               TestMessaging.register_agent(room.id, %{
                 agent_id: "alpha",
                 name: "Alpha",
                 handler: fn _, _ -> :noreply end
               })

      assert {:ok, _assigned_thread} = TestMessaging.assign_thread(room.id, thread.id, "alpha")
      assert {:ok, "alpha"} = TestMessaging.thread_assignment(room.id, thread.id)

      assert :ok = TestMessaging.unregister_agent(room.id, "alpha")
      assert {:ok, nil} = TestMessaging.thread_assignment(room.id, thread.id)

      assert {:ok, persisted_thread} = TestMessaging.get_thread(thread.id)
      assert is_nil(persisted_thread.assigned_agent_id)
      assert_eventually(fn ->
        AgentRunner.whereis(TestMessaging, room.id, thread.id, "alpha") == nil
      end, timeout: 500)
    end

    test "unregister_agent/2 clears persisted assignments even when room state lost the thread mapping" do
      room = create_room!("runner-unregister-drift-room")
      thread = create_thread!(room.id, "ext-thread-unregister-drift")

      assert {:ok, _agent_spec} =
               TestMessaging.register_agent(room.id, %{
                 agent_id: "alpha",
                 name: "Alpha",
                 handler: fn _, _ -> :noreply end
               })

      assert {:ok, _assigned_thread} = TestMessaging.assign_thread(room.id, thread.id, "alpha")

      assert_eventually(fn ->
        AgentRunner.whereis(TestMessaging, room.id, thread.id, "alpha") != nil
      end)

      room_server = ensure_room_server!(room)
      assert :ok = Jido.Messaging.RoomServer.unassign_thread(room_server, thread.id)
      assert {:ok, "alpha"} = TestMessaging.thread_assignment(room.id, thread.id)

      assert :ok = TestMessaging.unregister_agent(room.id, "alpha")
      assert {:ok, nil} = TestMessaging.thread_assignment(room.id, thread.id)

      assert {:ok, persisted_thread} = TestMessaging.get_thread(thread.id)
      assert is_nil(persisted_thread.assigned_agent_id)
      assert_eventually(fn ->
        AgentRunner.whereis(TestMessaging, room.id, thread.id, "alpha") == nil
      end, timeout: 500)
    end
  end

  defp create_room!(name) do
    {:ok, room} = TestMessaging.create_room(%{type: :group, name: name})
    room
  end

  defp create_thread!(room_id, external_thread_id) do
    {:ok, thread} =
      TestMessaging.save_thread(%{
        room_id: room_id,
        external_thread_id: external_thread_id,
        delivery_external_room_id: "delivery-" <> external_thread_id
      })

    thread
  end

  defp ensure_room_server!(room) do
    {:ok, pid} = TestMessaging.get_or_start_room_server(room)
    pid
  end

  defp message(room_id, sender_id, thread_id, text) do
    Message.new(%{
      room_id: room_id,
      sender_id: sender_id,
      role: :user,
      content: [%{type: :text, text: text}],
      thread_id: thread_id
    })
  end

  defp with_agent_supervisor_unavailable(instance_module, fun) when is_atom(instance_module) and is_function(fun, 0) do
    supervisor_name = instance_module.__jido_messaging__(:supervisor)
    agent_supervisor_name = instance_module.__jido_messaging__(:agent_supervisor)
    supervisor_pid = Process.whereis(supervisor_name)
    agent_supervisor_pid = Process.whereis(agent_supervisor_name)

    assert is_pid(supervisor_pid)
    assert is_pid(agent_supervisor_pid)

    :ok = :sys.suspend(supervisor_pid)
    Process.exit(agent_supervisor_pid, :kill)

    assert_eventually(fn ->
      Process.whereis(agent_supervisor_name) == nil
    end, timeout: 500)

    try do
      fun.()
    after
      :ok = :sys.resume(supervisor_pid)

      assert_eventually(fn ->
        is_pid(Process.whereis(agent_supervisor_name))
      end, timeout: 500)
    end
  end
end
