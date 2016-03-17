defmodule Phoenix.Tracker.State do
  @moduledoc """
  Provides an ORWSOT CRDT.
  """
  alias Phoenix.Tracker.State

  defstruct replica: nil,
            context: %{},
            cloud: MapSet.new(),
            tab: nil,
            mode: :unset,
            delta: :unset,
            nodes: %{},
            range: {0, 0}

  @doc """
  Creates a new set for the replica.

  ## Examples

      iex> Phoenix.Tracker.State.new(:node1)
      %Phoenix.Tracker.State{...}

  """
  def new(replica) do
    reset_delta(%State{
      replica: replica,
      mode: :normal,
      tab: :ets.new(:tab, [:duplicate_bag]),
      nodes: %{replica => :up}})
  end

  @doc """
  Returns the causal context for the set.
  """
  def clocks(%State{replica: rep, context: ctx}), do: {rep, ctx}

  @doc """
  Adds a new element to the set.
  """
  def join(%State{} = state, pid, topic, key, meta \\ %{}) do
    add(state, pid, topic, key, meta)
  end

  @doc """
  Removes an element from the set.
  """
  def leave(%State{} = state, pid, topic, key) do
    remove(state, {{pid, topic}, {{key, :_}, :_}})
  end

  @doc """
  Removes all elements from the set for the given pid.
  """
  def leave(%State{} = state, pid) do
    remove(state, {{pid, :_}, :_})
  end

  @doc """
  Returns a list of elements in the set belonging to an online replica.
  """
  def online_list(%State{tab: tab} = state) do
    :ets.select(tab, Enum.map(up_nodes(state), fn replica ->
      {{:_, {:_, {replica, :_}}}, [], [:"$_"]}
    end))
  end

  @doc """
  Returns a list of elements for the topic who belong to an online replica.
  """
  def get_by_topic(%State{tab: tab} = state, topic) do
    :ets.select(tab, Enum.map(up_nodes(state), fn replica ->
      {{{:_, topic}, {:_, {replica, :_}}}, [], [:"$_"]}
    end))
  end

  @doc """
  Returns the element matching the pid, topic, and key.
  """
  def get_by_pid(%State{tab: tab}, pid, topic, key) do
    case :ets.match_object(tab, {{pid, topic}, {{key, :_}, :_}}) do
      [] -> nil
      [one] -> one
    end
  end

  @doc """
  Returns all elements for the pid.
  """
  def get_by_pid(%State{tab: tab}, pid) do
    :ets.match_object(tab, {{pid, :_}, :_})
  end

  @doc """
  Checks if set has a non-empty delta.
  """
  def has_delta?(%State{delta: %State{cloud: cloud}}) do
    MapSet.size(cloud) != 0
  end

  @doc """
  Resets the set's delta.
  """
  def reset_delta(%State{replica: replica} = state) do
    clock = clock(state)
    delta = %State{replica: replica,
                   tab: %{},
                   range: {clock, clock},
                   mode: :delta}
    %State{state | delta: delta}
  end

  @doc """
  Extracts the set's elements from ets into a mergable list.

  Used when merging two sets.
  """
  def extract(%State{tab: tab} = state) do
    map = foldl(tab, %{}, fn {{pid, topic}, {{key, meta}, id}}, acc ->
      Map.put(acc, id, {pid, topic, key, meta})
    end)
    {state, map}
  end

  @doc """
  Extracts the set's delta elements into a mergable list.

  Used when merging a delta into another set.
  """
  def extract_delta(%State{delta: delta}) do
    {delta, delta.tab}
  end

  @doc """
  Merges two sets, or a delta into a set.

  Returns a 3-tuple of the updated set, and the joiend and left elements.

  ## Examples

      iex> {s1, joined, left} =
           Phoenix.Tracker.State.merge(s1, Phoenix.Tracker.State.extract(s2))

      {%Phoenix.Tracker.State{}, [...], [...]}
  """
  def merge(%State{} = local, {%State{} = remote, remote_map}) do
    union_task = Task.async(fn -> MapSet.union(local.cloud, remote.cloud) end)
    joins = accumulate_joins(local, remote_map)
    {cloud, delta, adds, leaves} = observe_removes(local, remote, remote_map, joins, union_task)
    true = :ets.delete_all_objects(local.tab)
    true = :ets.insert(local.tab, adds)
    ctx = Map.merge(local.context, remote.context, fn _, a, b -> max(a, b) end)
    new_state = compact(%State{local | context: ctx, cloud: cloud, delta: delta})

    {new_state, joins, leaves}
  end
  defp accumulate_joins(local, remote_map) do
    Enum.reduce(remote_map, [], fn {id, {pid, topic, key, meta}}, adds ->
      if in?(local, id) do
        adds
      else
        [{{pid, topic}, {{key, meta}, id}} | adds]
      end
    end)
  end
  defp observe_removes(local, remote, remote_map, joins, union_task) do
    unioned_cloud = Task.await(union_task, :infinity)
    init = {unioned_cloud, local.delta, joins, []}

    foldl(local.tab, init, fn {_, {_, id}} = el, {cloud, delta, adds, leaves} ->
      if in?(remote, id) and not Map.has_key?(remote_map, id) do
        {MapSet.delete(cloud, id), remove_delta_id(delta, id), adds, [el | leaves]}
      else
        {cloud, delta, [el | adds], leaves}
      end
    end)
  end

  @doc """
  Marks a node as up in the set and returns rejoined users.
  """
  def node_up(%State{nodes: nodes} = state, replica) do
    {%State{state | nodes: Map.put(nodes, replica, :up)}, node_users(state, replica), []}
  end

  @doc """
  Marks a node as down in the set and returns left users.
  """
  def node_down(%State{nodes: nodes} = state, replica) do
    {%State{state | nodes: Map.put(nodes, replica, :down)}, [], node_users(state, replica)}
  end

  @doc """
  Removes all elements for nodes that are permanently gone.
  """
  # TODO: double check cleaning up cloud/delta for this case
  def remove_down_nodes(%State{context: ctx, tab: tab} = state, replica) do
    new_ctx = for {rep, clock} <- ctx, rep != replica, into: %{}, do: {rep, clock}
    true = :ets.match_delete(tab, {:_, {:_, {replica, :_}}})

    %State{state | context: new_ctx}
  end

  defp add(%State{} = state, pid, topic, key, meta) do
    state
    |> bump_clock()
    |> do_add(pid, topic, key, meta)
  end
  defp do_add(%State{tab: tab, delta: delta} = state, pid, topic, key, meta) do
    true = :ets.insert(tab, {{pid, topic}, {{key, meta}, id(state)}})
    new_delta = %State{delta | tab: Map.put(delta.tab, id(state), {pid, topic, key, meta})}
    %State{state | delta: new_delta}
  end

  defp remove(%State{tab: tab, cloud: cloud_before, delta: delta} = state, match_spec) do
    ids = Enum.map(:ets.match_object(tab, match_spec), fn {_, {{_, _}, id}} -> id end)
    true = :ets.match_delete(tab, match_spec)
    {pruned_cloud, new_delta} =
      Enum.reduce(ids, {cloud_before, delta}, fn id, {cloud, delta} ->
        {MapSet.delete(cloud, id), remove_delta_id(delta, id)}
      end)

    bump_clock(%State{state | cloud: pruned_cloud, delta: new_delta})
  end

  defp remove_delta_id(%State{mode: :delta, tab: tab, cloud: cloud} = delta, id) do
    %State{delta | cloud: MapSet.put(cloud, id), tab: Map.delete(tab, id)}
  end

  defp compact(%State{context: ctx, cloud: cloud} = state) do
    {new_ctx, new_cloud} = do_compact(ctx, Enum.sort(cloud))
    %State{state | context: new_ctx, cloud: new_cloud}
  end
  defp do_compact(ctx, cloud) do
    Enum.reduce(cloud, {ctx, MapSet.new()}, fn {replica, clock} = id, {ctx_acc, cloud_acc} ->
      case {Map.get(ctx_acc, replica), clock} do
        {nil, 1} ->
          {Map.put(ctx_acc, replica, clock), cloud_acc}
        {nil, _} ->
          {ctx_acc, MapSet.put(cloud_acc, id)}
        {ctx_clock, clock} when ctx_clock + 1 == clock ->
          {Map.put(ctx_acc, replica, clock), cloud_acc}
        {ctx_clock, clock} when ctx_clock >= clock ->
          {ctx_acc, cloud_acc}
        {_, _} ->
          {ctx_acc, MapSet.put(cloud_acc, id)}
      end
    end)
  end

  defp in?(%State{context: ctx, cloud: cloud}, {replica, clock} = id) do
    Map.get(ctx, replica, 0) >= clock or MapSet.member?(cloud, id)
  end

  defp id(%State{replica: rep} = state), do: {rep, clock(state)}

  defp clock(%State{replica: rep, context: ctx}), do: Map.get(ctx, rep, 0)

  defp bump_clock(%State{mode: :normal, replica: rep, cloud: cloud, context: ctx, delta: delta} = state) do
    %State{cloud: delta_cloud, range: delta_range} = delta
    new_clock = clock(state) + 1

    %State{state |
           cloud: MapSet.put(cloud, {rep, new_clock}),
           context: Map.put(ctx, rep, new_clock),
           delta: %State{delta |
                         cloud: MapSet.put(delta_cloud, {rep, new_clock}),
                         range: put_elem(delta_range, 1, new_clock)}}
  end

  defp up_nodes(%State{nodes: nodes})  do
    for {replica, :up} <- nodes, do: replica
  end

  defp foldl(tab, initial, func), do: :ets.foldl(func, initial, tab)

  defp node_users(%State{tab: tab}, replica) do
    :ets.match_object(tab, {:_, {:_, {replica, :_}}})
  end
end
