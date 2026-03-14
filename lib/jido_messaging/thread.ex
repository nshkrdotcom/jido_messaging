defmodule Jido.Messaging.Thread do
  @moduledoc """
  Canonical persisted thread model for `Jido.Messaging`.
  """

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Zoi.string(),
              room_id: Zoi.string(),
              external_thread_id: Zoi.string() |> Zoi.nullish(),
              delivery_external_room_id: Zoi.string() |> Zoi.nullish(),
              root_message_id: Zoi.string() |> Zoi.nullish(),
              root_external_message_id: Zoi.string() |> Zoi.nullish(),
              assigned_agent_id: Zoi.string() |> Zoi.nullish(),
              status: Zoi.enum([:active, :archived, :closed]) |> Zoi.default(:active),
              metadata: Zoi.map() |> Zoi.default(%{}),
              inserted_at: Zoi.struct(DateTime) |> Zoi.nullish(),
              updated_at: Zoi.struct(DateTime) |> Zoi.nullish()
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for Thread."
  def schema, do: @schema

  @doc "Creates a thread with generated ID and timestamps."
  def new(attrs) when is_map(attrs) do
    now = DateTime.utc_now()

    attrs
    |> Map.put_new(:id, Jido.Chat.ID.generate!())
    |> Map.put_new(:inserted_at, now)
    |> Map.put_new(:updated_at, now)
    |> then(&Jido.Chat.Schema.parse!(__MODULE__, @schema, &1))
  end
end
