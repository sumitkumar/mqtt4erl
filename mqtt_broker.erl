-module(mqtt_broker).

-include_lib("mqtt.hrl").

-compile(export_all).

-export([start/0]).

-record(broker, {
  sub_pid,
  registry_pid
}).

-record(client_proxy, {
  broker,
  context,
  ping_timer
}).

start() ->
  case gen_tcp:listen(?MQTT_PORT, [binary, {active, false}]) of
    {ok, ListenSocket} ->
      Pid = spawn(fun() ->
        gen_tcp:controlling_process(ListenSocket, self()),
        server_loop(ListenSocket)
      end),
      {ok, Pid};
    {error, Reason} ->
        exit(Reason)
  end.

server_loop(ListenSocket) ->
  Broker = #broker{
    sub_pid = spawn_link(fun() -> subscriber_loop() end),
    registry_pid = spawn_link(fun() -> registry_loop() end)
  },
  {ok, ClientSocket} = gen_tcp:accept(ListenSocket),
  _ClientPid = spawn_link(fun() ->
    process_flag(trap_exit, true),
    Context = #context{
      socket = ClientSocket,
      pid = self()
    },
    spawn_link(fun() -> mqtt_core:recv_loop(Context) end),
    clientproxy_loop(#client_proxy{
      broker = Broker,
      context = Context
    })
  end),
  server_loop(ListenSocket).

clientproxy_loop(State) ->
  NewState = receive
    #mqtt{type = ?CONNECT, hint = O} ->
      ?LOG({client_loop, connect, O}),
      if
        O#connect_options.protocol_version /= ?PROTOCOL_VERSION ->
          mqtt_core:send(mqtt_core:construct_message({connack, 1}), State#client_proxy.context),
          exit({connect_refused, wrong_protocol_version});
        length(O#connect_options.client_id) < 1;
        length(O#connect_options.client_id) > 23 ->
          mqtt_core:send(mqtt_core:construct_message({connack, 2}), State#client_proxy.context),
          exit({connect_refused, invalid_clientid});
        true ->
          (State#client_proxy.broker)#broker.registry_pid ! {mqtt_registry, put, O#connect_options.client_id, self()},
          mqtt_core:send(mqtt_core:construct_message({connack, 0}), State#client_proxy.context)
      end,
      State#client_proxy{
        ping_timer = timer:apply_interval(O#connect_options.keepalive * 1000, mqtt_core, send_ping, [State#client_proxy.context])
      };
    #mqtt{type = ?SUBSCRIBE, hint = Hint} ->
      ?LOG({client_loop, subscribe, Hint}),
      {_, Subs} = Hint,
      (State#client_proxy.broker)#broker.sub_pid ! {sub, add, self(), Subs},
      mqtt_core:send(mqtt_core:construct_message({suback, Hint}), State#client_proxy.context),
      State;
    #mqtt{type = ?UNSUBSCRIBE, hint = Hint} ->
      ?LOG({client_loop, unsubscribe, Hint}),
      {MessageId, Unsubs} = Hint,
      (State#client_proxy.broker)#broker.sub_pid ! {sub, remove, self(), Unsubs},
      mqtt_core:send(mqtt_core:construct_message({unsuback, MessageId}), State#client_proxy.context),
      State;
    {received, Message} ->
      ?LOG({client_loop, got, Message}),
      {_, Topic, _} = Message#mqtt.hint,
      lists:foreach(fun({Pid, SubscribedQoS}) ->
        AdjustedMessage = if
          Message#mqtt.qos > SubscribedQoS ->
            Message#mqtt{qos = SubscribedQoS};
          _ ->
            Message
        end,
        Pid ! {deliver, AdjustedMessage} 
      end, get_subscribers(Topic, State)),
      State;
    {deliver, Message} ->
      ?LOG({client_loop, deliver, Message}),
      mqtt_core:send(Message, State#client_proxy.context),
      State;
    {'EXIT', FromPid, Reason} ->
      %% send the will!
      ?LOG({client_loop, got, exit, FromPid, Reason}),
      disconnect(State),
      exit(Reason);
    Message ->
      ?LOG({client_loop, got, Message}),
      State
  end,  
  clientproxy_loop(NewState).

disconnect(State) ->
  %% remove from registry
  %% remove from subscriptions
  timer:cancel(State#client_proxy.ping_timer).

subscriber_loop() ->
  subscriber_loop(dict:new()).
subscriber_loop(State) ->
  NewState = receive
    {sub, add, ClientPid, Subs} ->
      ?LOG({subscribers, add, ClientPid, Subs}),
      lists:foldl(fun(#sub{topic = Topic, qos = QoS}, InterimState) ->
        case dict:find(Topic, InterimState) of
          {ok, Subscribers} ->
            dict:store(Topic, [{ClientPid, QoS}|lists:keydelete(ClientPid, 1, Subscribers)], InterimState);
          error ->
            dict:store(Topic, [{ClientPid, QoS}], InterimState)
        end
      end, State, Subs);
    {sub, remove, ClientPid, all} ->
      ?LOG({subscribers, remove, ClientPid, all}),
      lists:foldl(fun(Topic, InterimState) ->
        Subscribers = dict:fetch(Topic, InterimState),
        dict:store(Topic, lists:keydelete(ClientPid, 1, Subscribers), InterimState)
      end, State, dict:fetch_keys(State));
    {sub, remove, ClientPid, Unubs} ->
      ?LOG({subscribers, remove, ClientPid, Unubs}),
      lists:foldl(fun(#sub{topic = Topic}, InterimState) ->
        case dict:find(Topic, InterimState) of
          {ok, Subscribers} ->
            dict:store(Topic, lists:keydelete(ClientPid, 1, Subscribers), InterimState);
          error ->
            InterimState
        end
      end, State, Unubs);
    {sub, get, Topic, FromPid} ->
      case dict:find(Topic, State) of
        {ok, Subscribers} ->
          FromPid ! {sub, ok, Subscribers};
        error ->
          FromPid ! {sub, ok, []}
      end,
      State;
    Message ->
      ?LOG({subscribers, got, Message})
  end,
  subscriber_loop(NewState).

get_subscribers(Topic, State) ->
  (State#client_proxy.broker)#broker.sub_pid ! {sub, get, Topic, self()},
  receive 
    {sub, ok, Subscribers} ->
      ?LOG({get_subscribers, got, Subscribers}),
      Subscribers;
    Message ->
      ?LOG({get_subscribers, got, Message})
  end.

registry_loop() ->
  registry_loop(dict:new()).
registry_loop(State) ->
  NewState = receive
    {mqtt_registry, put, ClientId, Pid} ->
      ?LOG({mqtt_registry, put, ClientId, Pid}),
      case dict:find(ClientId, State) of
        {ok, OldPid} ->
          ?LOG({mqtt_registry, killing_old, OldPid}),
          exit(OldPid, client_id_represented);
        error ->
          ignore
      end,
      dict:store(ClientId, Pid, State);
    Message ->
      ?LOG({mqtt_registry, unexpected_message, Message}),
      State
  end,
  registry_loop(NewState).
