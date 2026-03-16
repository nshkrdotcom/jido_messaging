defmodule Jido.Chat.RoomServerFeaturesTest do
  use ExUnit.Case, async: false

  alias Jido.Chat.{Participant, Room}
  alias Jido.Messaging.{Message, RoomServer, Thread}

  setup do
    start_supervised!(Jido.Messaging.TestMessaging)

    room = Room.new(%{type: :group, name: "Test Room"})
    {:ok, _pid} = RoomServer.start_link(room: room, instance_module: Jido.Messaging.TestMessaging)
    server = RoomServer.via_tuple(Jido.Messaging.TestMessaging, room.id)

    participant1 = Participant.new(%{type: :human, identity: %{name: "Alice"}})
    participant2 = Participant.new(%{type: :human, identity: %{name: "Bob"}})
    :ok = RoomServer.add_participant(server, participant1)
    :ok = RoomServer.add_participant(server, participant2)

    {:ok, server: server, room: room, p1: participant1, p2: participant2}
  end

  describe "thread-scoped history" do
    test "get_messages/2 filters by thread_id", %{server: server, room: room, p1: p1, p2: p2} do
      thread = Thread.new(%{room_id: room.id, external_thread_id: "thread-1"})

      root =
        Message.new(%{
          room_id: room.id,
          sender_id: p1.id,
          role: :user,
          content: [%{type: :text, text: "Root"}],
          thread_id: thread.id
        })

      reply =
        Message.new(%{
          room_id: room.id,
          sender_id: p2.id,
          role: :assistant,
          content: [%{type: :text, text: "Reply"}],
          thread_id: thread.id
        })

      other =
        Message.new(%{
          room_id: room.id,
          sender_id: p2.id,
          role: :user,
          content: [%{type: :text, text: "Other"}]
        })

      :ok = RoomServer.add_message(server, root)
      :ok = RoomServer.add_message(server, reply)
      :ok = RoomServer.add_message(server, other)

      assert Enum.map(RoomServer.get_messages(server), & &1.id) == [other.id, reply.id, root.id]
      assert Enum.map(RoomServer.get_messages(server, thread_id: thread.id), & &1.id) == [reply.id, root.id]
    end
  end

  describe "reactions and receipts" do
    test "tracks reactions and message receipts on the canonical message struct", %{
      server: server,
      room: room,
      p1: p1,
      p2: p2
    } do
      message =
        Message.new(%{
          room_id: room.id,
          sender_id: p1.id,
          role: :user,
          content: [%{type: :text, text: "Hello!"}]
        })

      :ok = RoomServer.add_message(server, message)

      assert {:ok, reacted} = RoomServer.add_reaction(server, message.id, p2.id, "👍")
      assert reacted.reactions["👍"] == [p2.id]

      assert {:ok, delivered} = RoomServer.mark_delivered(server, message.id, p2.id)
      assert delivered.status == :delivered
      assert delivered.receipts[p2.id].delivered_at

      assert {:ok, read} = RoomServer.mark_read(server, message.id, p2.id)
      assert read.status == :read
      assert read.receipts[p2.id].read_at
    end
  end

  describe "thread assignment api" do
    test "registers agents and assigns threads in room state", %{server: server, room: room} do
      thread = Thread.new(%{room_id: room.id, external_thread_id: "thread-1"})

      agent_spec = %{
        agent_id: "alpha",
        name: "Alpha",
        mention_handles: ["alpha"],
        trigger: :thread,
        handler: fn _, _ -> :noreply end
      }

      assert {:ok, _registered_spec} = RoomServer.register_agent(server, agent_spec)
      assert [registered] = RoomServer.list_agents(server)
      assert registered.agent_id == "alpha"

      assert :ok = RoomServer.assign_thread(server, thread.id, "alpha")
      assert RoomServer.thread_assignment(server, thread.id) == "alpha"
      assert RoomServer.list_thread_assignments(server) == %{thread.id => "alpha"}

      assert :ok = RoomServer.unassign_thread(server, thread.id)
      assert RoomServer.thread_assignment(server, thread.id) == nil
    end
  end

  describe "typing" do
    test "tracks typing indicators per thread id", %{server: server, p1: p1} do
      :ok = RoomServer.set_typing(server, p1.id, true, thread_id: "thread-123")

      assert [%{participant_id: participant_id, thread_id: "thread-123"}] = RoomServer.get_typing(server)
      assert participant_id == p1.id

      :ok = RoomServer.set_typing(server, p1.id, false, thread_id: "thread-123")
      assert RoomServer.get_typing(server) == []
    end
  end
end
