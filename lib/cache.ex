defmodule Cache do
  alias Lace.Redis
  require Logger

  @guild_cache "guild_cache"
  @channel_cache "channel_cache"
  @role_cache "role_cache"
  @emoji_cache "emoji_cache"

  @user_hash "users"
  @user_zset "users-rc"
  
  ##################
  # Main functions #
  ##################

  def process do
    spawn fn -> get_event() end
    # Don't abuse redis too much
    # Artificially limit us to 100/s throughput
    Process.sleep 10
    process()
  end

  def get_event do
    # Read an event off the queue
    {:ok, data} = Redis.q ["LPOP", System.get_env("CACHE_QUEUE")]
    unless data == :undefined do
      Logger.debug "Got cache event: #{data}"
      event = data |> Poison.decode!
      process_event event
    end
  end

  ####################
  # Helper functions #
  ####################

  defp update_many(collection, list) do
    unless length(list) == 0 do
      Mongo.update_many :mongo, collection, list, [pool: DBConnection.Poolboy, continue_on_error: true, upsert: true]
    end
  end

  defp update_guild(raw_guild) do
    {channels,      raw_guild} = Map.pop(raw_guild, "channels")
    {members,       raw_guild} = Map.pop(raw_guild, "members")
    {_presences,    raw_guild} = Map.pop(raw_guild, "presences")
    {_voice_states, raw_guild} = Map.pop(raw_guild, "voice_states")
    {roles,         raw_guild} = Map.pop(raw_guild, "roles")
    {emojis,        raw_guild} = Map.pop(raw_guild, "emojis")
    # Do some cleaning
    channels
    |> Enum.map(fn(x) -> add_id(raw_guild, x) end)
    |> Enum.to_list
    |> update_channels

    roles
    |> Enum.map(fn(x) -> add_id(raw_guild, x) end)
    |> Enum.to_list
    |> update_roles

    emojis
    |> Enum.map(fn(x) -> add_id(raw_guild, x) end)
    |> Enum.to_list
    |> update_emojis

    # Dump it into db
    Mongo.update_one(:mongo, @guild_cache, %{"id": raw_guild["id"]}, %{"$set": raw_guild}, [pool: DBConnection.Poolboy, upsert: true])
    update_members_and_users raw_guild["id"], members

    update_channels channels
    update_roles roles
    update_emojis emojis

    # TODO: Put this in redis instead?
    # insert_many "voice_state_cache", voice_states

    # TODO: Do I even care about presences?
    #insert_many "presence_cache",    presences
  end

  defp update_channels(channels) do
    update_many @channel_cache, channels
  end

  defp update_roles(roles) do
    update_many @role_cache, roles
  end

  defp update_emojis(emojis) do
    update_many @emoji_cache, emojis
  end

  defp update_members_and_users(guild_id, list) do
    list
    # Gives us a list of [{user object, member object}]
    |> Enum.map(fn(m) -> member_to_user(guild_id, m) end)
    # Don't usually need to do any complex queries over users, 
    # so store them in redis
    # Chunks every 1k members so as to not overwhelm redis with a single
    # giant transaction, since other chunks will be trying to write too
    |> Enum.chunk_every(1000)
    |> Enum.each(fn(chunk) -> handle_user_chunk(guild_id, chunk) end)
  end

  @doc """
  Note that this method stores member objects in a *hash* that 
  corresponds to the guild. This is so that we can trivially do do a 
  fast-delete of all a guild's members, while still not losing the ability to
  query this info based on guild id

  User info is stored in a global hash, and uses a zset for reference-counting 
  users so that we can figure out when to add/remove them from the cache
  """
  defp handle_user_chunk(guild_id, chunk) do
    guild_key = "guild:#{guild_id}:members"
    Redis.t fn(worker) -> 
        for {user, member} <- chunk do
          Redis.q worker, ["HSET", @user_hash, user["id"], Poison.encode!(user)]
          Redis.q worker, ["ZINCRBY", @user_zset, 1, user["id"]]
          Redis.q worker, ["HSET", guild_key, user["id"], Poison.encode!(member)]
        end
      end
  end

  defp member_to_user(guild, member) do
    {user, member} = Map.pop member, "user"
    member = member |> Map.put("guild", guild["id"])
                    |> Map.put("user", user["id"])
    {user, member}
  end

  @doc """
  Ensure that entities always have a guild_id attached
  """
  defp add_id(guild, entity) do
    entity |> Map.put("guild_id", guild["id"])
  end

  ##############################
  # Event-processing functions #
  ##############################

  defp process_event(%{"t" => "GUILD_CREATE"} = event) do
    update_guild event["d"]
  end

  defp process_event(%{"t" => "GUILD_UPDATE"} = event) do
    update_guild event["d"]
  end

  defp process_event(%{"t" => "GUILD_DELETE"} = event) do
    guild = event["d"]
    guild_key = "guild:#{guild["id"]}:members"
    if is_nil guild["unavailable"] do
      Mongo.delete_one(:mongo, @guild_cache, %{"id": guild["id"]}, [pool: DBConnection.Poolboy])
      {:ok, ids} = Redis.q ["HKEYS", guild_key]
      Redis.q ["DEL", guild_key]
      ids
      |> Enum.chunk_every(1000)
      |> Enum.each(fn(chunk) -> 
          Redis.t fn(worker) -> 
              for id <- chunk do
                Redis.q worker, ["ZINCRBY", @user_zset, -1, id]
              end
            end
        end)
      # Garbage-collect when an id runs out of references
      {:ok, prunable_users} = Redis.q ["ZRANGEBYSCORE", @user_zset, "-inf", 0]
      Redis.q ["ZREMRANGEBYSCORE", @user_zset, "-inf", 0]
      prunable_users
      |> Enum.chunk_every(1000)
      |> Enum.each(fn(chunk) -> 
          Redis.t fn(worker) -> 
              for id <- chunk do
                Redis.q worker, ["HDEL", @user_hash, id]
              end
            end
        end)
    end
  end

  defp process_event(%{"t" => "CHANNEL_CREATE"} = event) do
    update_channels [event["d"]]
  end

  defp process_event(%{"t" => "CHANNEL_UPDATE"} = event) do
    update_channels [event["d"]]
  end

  defp process_event(%{"t" => "CHANNEL_DELETE"} = event) do
    Mongo.delete_one(:mongo, @channel_cache, %{"id": event["d"]["id"]}, [pool: DBConnection.Poolboy])
  end

  defp process_event(%{"t" => "GUILD_EMOJIS_UPDATE"} = event) do
    # TODO
  end

  defp process_event(%{"t" => "GUILD_MEMBER_ADD"} = event) do
    member = event["d"]
    update_members_and_users member["guild_id"], [member]
    Mongo.update_one(:mongo, @guild_cache, %{"id": member["guild_id"]}, %{"$inc": %{"member_count": 1}}, [pool: DBConnection.Poolboy, upsert: true])
  end

  defp process_event(%{"t" => "GUILD_MEMBER_REMOVE"} = event) do
    guild_id = event["d"]["guild_id"]
    user = event["d"]["user"]
    Redis.q ["HDEL", "guild:#{guild_id}:members", user["id"]]
    Redis.q ["ZINCRBY", @user_zset, -1, user["id"]]
    Mongo.update_one(:mongo, @guild_cache, %{"id": guild_id}, %{"$inc": %{"member_count": -1}}, [pool: DBConnection.Poolboy, upsert: true])
  end

  defp process_event(%{"t" => "GUILD_MEMBER_UPDATE"} = event) do
    member = event["d"]
    update_members_and_users member["guild_id"], [member]
  end

  defp process_event(%{"t" => "GUILD_MEMBERS_CHUNK"} = event) do
    chunk = event["d"]
    update_members_and_users chunk["guild_id"], chunk["members"]
  end

  defp process_event(%{"t" => "GUILD_ROLE_CREATE"} = event) do
    update_roles [event["d"]]
  end

  defp process_event(%{"t" => "GUILD_ROLE_UPDATE"} = event) do
    update_roles [event["d"]]
  end

  defp process_event(%{"t" => "GUILD_ROLE_DELETE"} = event) do
    Mongo.delete_one(:mongo, @role_cache, %{"id": event["d"]["role_id"]}, [pool: DBConnection.Poolboy])
  end

  defp process_event(%{"t" => "PRESENCE_UPDATE"} = _event) do
    # Make this not NOOP?
  end

  defp process_event(%{"t" => "USER_UPDATE"} = event) do
    user = event["d"]
    {:ok, cached_user} = Redis.q ["HGET", @user_hash, user["id"]]
    unless cached_user == :undefined do
      Redis.q ["HSET", @user_hash, user["id"], Map.merge(cached_user, user)]
    else
      Logger.warn "Got USER_UPDATE for unknown user: #{user["id"]}!"
    end
  end

  defp process_event(%{"t" => "VOICE_STATE_UPDATE"} = event) do
    # TODO
  end
  
  ##################
  # NOOP catch-all #
  ##################

  defp process_event(event) do
    Logger.debug "Got unknown event: #{inspect event}"
  end
end