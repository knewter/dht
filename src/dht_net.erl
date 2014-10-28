%% @author Magnus Klaar <magnus.klaar@sgsstudentbostader.se>
%% @doc DHT networking code
%% @end
%% @private
-module(dht_net).

-behaviour(gen_server).

%%
%% Implementation notes
%%     RPC calls to remote nodes in the DHT are written by use of a gen_server proxy.
%%     The proxy maintains an internal correlation table from requests to replies so
%%     a given reply can be matched up with the correct requestor. It uses the
%%     standard gen_server:call/3 approach to handling calls in the DHT.
%%
%%     A timer is used to notify the server of requests that
%%     time out, if a request times out {error, timeout} is
%%     returned to the client. If a response is received after
%%     the timer has fired, the response is dropped.
%%
%%     The expected behavior is that the high-level timeout fires
%%     before the gen_server call times out, therefore this interval
%%     should be shorter then the interval used by gen_server calls.
%%
%% Lifetime interface. Mostly has to do with setup and configuration
-export([start_link/1, start_link/2, node_port/0]).

%% DHT API
-export([
         store/4,
         find_node/1,
         find_value/2,
         ping/1
]).

%% Private internal use
-export([handle_query/5]).

% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

% internal exports
-export([sync/0]).

-record(state, {
    socket :: inet:socket(),
    outstanding   :: gb_trees:tree(),
    tokens :: queue:queue()
}).

%
% Constants and settings
%
-define(TOKEN_LIFETIME, 5 * 60 * 1000).
-define(UDP_MAILBOX_SZ, 16).
-define(QUERY_TIMEOUT, 2000).

%
% Public interface
%

%% @doc Start up the DHT networking subsystem
%% @end
start_link(DHTPort) ->
    start_link(DHTPort, #{}).
    
%% @private
start_link(Port, Opts) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [Port, Opts], []).

%% @doc node_port/0 returns the (UDP) port number to which the DHT system is bound.
%% @end
-spec node_port() -> {inet:ip_address(), inet:port_number()}.
node_port() ->
    gen_server:call(?MODULE, node_port).

%% @private
request(Target, Q) ->
    gen_server:call(?MODULE, {request, Target, Q}).

%% @private
sync() ->
    gen_server:call(?MODULE, sync).

%% @doc ping/2 sends a ping to a node
%% Calling `ping(IP, Port)' will send a ping message to the IP/Port pair
%% and wait for a result to come back. Used to check if the node in the
%% other end is up and running.
%% @end
-spec ping({inet:ip_address(), inet:port_number()}) ->
      pang | {ok, dht:node_id(), benc:t()} | {error, Reason}
  when Reason :: term().
ping(Peer) ->
    case request(Peer, ping) of
        {error, timeout} -> pang;
        {response, _, ID, ping} -> {ok, ID}
    end.

%% @doc find_node/3 searches in the DHT for a given target NodeID
%% Search at the target IP/Port pair for the NodeID given by `Target'. May time out.
%% @end
-spec find_node(dht:node_t()) -> {ID, Nodes} | {error, Reason}
  when
    ID :: dht:node_id(),
    Nodes :: [dht:node_t()],
    Reason :: any().

find_node({N, IP, Port} = Node)  ->
    case request({IP, Port}, {find, node, N}) of
        {error, E} -> {error, E};
        {response, _, _, {find, node, Nodes}} ->
            dht_state:notify(Node, request_success),
            {nodes, N, Nodes}
    end.

-spec find_value(Peer, ID) ->
			  {nodes, ID, [Node]}
		    | {values, ID, Token, [Value]}
		    | {error, Reason}
	when
	  Peer :: {inet:ip_address(), inet:port_number()},
	  ID :: dht:id(),
	  Node :: dht:node_t(),
	  Token :: dht:token(),
	  Value :: dht:node_t(),
	  Reason :: any().
	    
find_value(Peer, IDKey)  ->
    case request(Peer, {find, value, IDKey}) of
        {error, Reason} -> {error, Reason};
        {response, _, ID, {find, node, Nodes}} ->
            {nodes, ID, Nodes};
        {response, _, ID, {find, value, Token, Values}} ->
            {values, ID, Token, Values}
    end.

-spec store(SockName, Token, ID, Port) -> {error, timeout} | dht:node_id()
  when
    SockName :: {inet:ip_address(), inet:port_number()},
    ID :: dht:id(),
    Token :: dht:token(),
    Port :: inet:port_number().

store(Peer, Token, IDKey, Port) ->
    case request(Peer, {store, Token, IDKey, Port}) of
        {error, R} -> {error, R};
        {response, _, ID, _} ->
            {ok, ID}
    end.

%% @private
handle_query(ping, Peer, Tag, OwnID, _Tokens) ->
    return(Peer, {response, Tag, OwnID, ping});
handle_query({find, node, ID}, Peer, Tag, OwnID, _Tokens) ->
     Nodes = filter_node(Peer, dht_state:closest_to(ID)),
     return(Peer, {response, Tag, OwnID, {find, node, Nodes}});
handle_query({find, value, ID}, Peer, Tag, OwnID, Tokens) ->
    Vs =
        case dht_store:find(ID) of
            [] -> filter_node(Peer, dht_state:closest_to(ID));
            Peers -> Peers
        end,
    RecentToken = queue:last(Tokens),
    return(Peer, {response, Tag, OwnID, {find, value, token_value(Peer, RecentToken), Vs}});
handle_query({store, Token, ID, Port}, {IP, _Port} = Peer, Tag, OwnID, Tokens) ->
    case is_valid_token(Token, Peer, Tokens) of
        false -> ok;
        true -> dht_store:store(ID, {IP, Port})
    end,
    return(Peer, {response, Tag, OwnID, store}).

-spec return({inet:ip_address(), inet:port_number()}, any()) -> 'ok'.
return(Peer, Response) ->
    ok = gen_server:call(?MODULE, {return, Peer, Response}).

%% CALLBACKS
%% ---------------------------------------------------

%% @private
init([DHTPort, Opts]) ->
    {ok, Base} = application:get_env(dht, listen_opts),
    {ok, Socket} = dht_socket:open(DHTPort, [binary, inet, {active, ?UDP_MAILBOX_SZ} | Base]),
    erlang:send_after(?TOKEN_LIFETIME, self(), renew_token),
    {ok, #state{
    	socket = Socket, 
    	outstanding = gb_trees:empty(),
    	tokens = init_tokens(Opts)}}.

init_tokens(#{ tokens := Toks}) -> queue:from_list(Toks);
init_tokens(#{}) -> queue:from_list([random_token() || _ <- lists:seq(1, 3)]).

%% @private
handle_call({request, Peer, Request}, From, State) ->
    case send_query(Peer, Request, From, State) of
        {ok, S} -> {noreply, S};
        {error, Reason} -> {reply, {error, Reason}, State}
    end;
handle_call({return, {IP, Port}, Response}, _From, #state { socket = Socket } = State) ->
    Packet = dht_proto:encode(Response),
    case dht_socket:send(Socket, IP, Port, Packet) of
        ok -> {reply, ok, State};
        {error, _Reason} = E -> {reply, E, State}
    end;
handle_call(sync, _From, #state{} = State) ->
    {reply, ok, State};
handle_call(node_port, _From, #state { socket = Socket } = State) ->
    {ok, SockName} = dht_socket:sockname(Socket),
    {reply, SockName, State}.

%% @private
handle_cast(_Msg, State) ->
    {noreply, State}.

%% @private
handle_info({request_timeout, _, Key}, State) ->
    HandledState = handle_request_timeout(Key, State),
    {noreply, HandledState};
handle_info(renew_token, State) ->
    erlang:send_after(?TOKEN_LIFETIME, self(), renew_token),
    {noreply, handle_recycle_token(State)};
handle_info({udp_passive, Socket}, #state { socket = Socket } = State) ->
	ok = inet:setopts(Socket, [{active, ?UDP_MAILBOX_SZ}]),
	{noreply, State};
handle_info({udp, _Socket, IP, Port, Packet}, State) when is_binary(Packet) ->
    {noreply, handle_packet({IP, Port}, Packet, State)};
handle_info({stop, Caller}, #state{} = State) ->
    Caller ! stopped,
    {stop, normal, State};
handle_info(Msg, State) ->
    error_logger:error_msg("Unkown message in handle info: ~p", [Msg]),
    {noreply, State}.

%% @private
terminate(_, _State) ->
    ok.

%% @private
code_change(_, State, _) ->
    {ok, State}.

%% INTERNAL FUNCTIONS
%% ---------------------------------------------------

%% Handle a request timeout by unblocking the calling process with `{error, timeout}'
handle_request_timeout(Key, #state { outstanding = Outstanding } = State) ->
	case gb_trees:lookup(Key, Outstanding) of
	    none -> State;
	    {value, {Client, _Timeout}} ->
	        ok = gen_server:reply(Client, {error, timeout}),
	        State#state { outstanding = gb_trees:delete(Key, Outstanding) }
	 end.

%%
%% Token renewal is called whenever the tokens grows too old.
%% Cycle the tokens to make sure they wither and die over time.
%%
handle_recycle_token(#state { tokens = Tokens } = State) ->
    Cycled = queue:in(random_token(), queue:drop(Tokens)),
    State#state { tokens = Cycled }.

%%
%% Handle an incoming UDP message on the socket
%%
handle_packet({IP, Port} = Peer, Packet,
              #state { outstanding = Outstanding, tokens = Tokens } = State) ->
    Self = dht_state:node_id(), %% @todo cache this locally. It can't change.
    case view_packet_decode(Packet) of
        invalid_decode ->
            State;
        {valid_decode, Tag, M} ->
            Key = {Peer, Tag},
            case {gb_trees:lookup(Key, Outstanding), M} of
                {none, {response, _, _, _}} -> State; %% No recipient
                {none, {error, _, _, _, _}} -> State; %% No Recipient
                {none, {query, Tag, PeerID, Query}} ->
                  %% Incoming request
                  spawn_link(fun() -> dht_state:insert_node({PeerID, IP, Port}) end),
                  spawn_link(fun() -> ?MODULE:handle_query(Query, Peer, Tag, Self, Tokens) end),
                  State;
                {{value, {Client, TRef}}, _} ->
                  %% Handle blocked client process
                  erlang:cancel_timer(TRef),
                  respond(Client, M),
                  State#state { outstanding = gb_trees:delete(Key, Outstanding) }
            end
    end.


%% respond/2 handles correlated responses for processes using the `dht_net' framework.
respond(_Client, {query, _, _, _} = M) -> exit({message_to_ourselves, M});
respond(Client, M) -> gen_server:reply(Client, M).

%% view_packet_decode/1 is a view on the validity of an incoming packet
view_packet_decode(Packet) ->
    case dht_proto:decode(Packet) of
        {error, Tag, _ID, _Code, _Msg} = E -> {valid_decode, Tag, E};
        {response, Tag, _ID, _Reply} = R -> {valid_decode, Tag, R};
        {query, Tag, _ID, _Query} = Q -> {valid_decode, Tag, Q}
    end.

unique_message_id(Peer, Active) ->
    unique_message_id(Peer, Active, 16).
	
unique_message_id(Peer, Active, K) when K > 0 ->
    IntID = random:uniform(16#FFFF),
    MsgID = <<IntID:16>>,
    case gb_trees:is_defined({Peer, MsgID}, Active) of
        true ->
            %% That MsgID is already in use, recurse and try again
            unique_message_id(Peer, Active, K-1);
        false -> MsgID
    end.

%
% Generate a random token value. A token value is used to filter out bogus store
% requests, or at least store requests from nodes that never sends find_value requests.
%
random_token() ->
    ID0 = random:uniform(16#FFFF),
    ID1 = random:uniform(16#FFFF),
    <<ID0:16, ID1:16>>.

send_query({IP, Port} = Peer, Query, From, #state { outstanding = Active, socket = Socket } = State) ->
    Self = dht_state:node_id(), %% @todo cache this locally. It can't change.
    MsgID = unique_message_id(Peer, Active),
    Packet = dht_proto:encode({query, MsgID, Self, Query}),

    case dht_socket:send(Socket, IP, Port, Packet) of
        ok ->
            TRef = erlang:send_after(?QUERY_TIMEOUT, self(),
                                     {request_timeout, self(), {Peer, MsgID}}),

            Key = {Peer, MsgID},
            Value = {From, TRef},
            {ok, State#state { outstanding = gb_trees:insert(Key, Value, Active) }};
        {error, Reason} ->
            {error, Reason}
    end.

%% @doc Delete node with `IP' and `Port' from the list.
filter_node({IP, Port}, Nodes) ->
    [X || {_NID, NIP, NPort}=X <- Nodes, NIP =/= IP orelse NPort =/= Port].

%% @todo consider the safety of using phash2 here
token_value({IP, Port}, Token) ->
    Hash = erlang:phash2({IP, Port, Token}),
    <<Hash:32>>.

is_valid_token(TokenValue, Peer, Tokens) ->
    ValidValues = [token_value(Peer, Token) || Token <- queue:to_list(Tokens)],
    lists:member(TokenValue, ValidValues).
