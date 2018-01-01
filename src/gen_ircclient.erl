-module( gen_ircclient ).
-behaviour( gen_pnet ).

%%====================================================================
%% Exports
%%====================================================================

-export( [start_link/6, start_link/7] ).

-export( [code_change/3, handle_call/3, handle_cast/2, handle_info/2, init/1,
          terminate/2, trigger/3] ).

-export( [place_lst/0, trsn_lst/0, init_marking/2, preset/1, is_enabled/3,
          fire/3] ).

%%====================================================================
%% Exports
%%====================================================================

-include( "gen_ircclient.hrl" ).

%%====================================================================
%% Callback definitions
%%====================================================================

%%====================================================================
%% Record definitions
%%====================================================================

-record( irc_state, {socket, nick_name, user_name, real_name, channel} ).

%%====================================================================
%% API functions
%%====================================================================


-spec start_link( Server, Port, NickName, UserName, RealName, Channel ) -> gen_pnet:start_link_result()
when Server   :: string(),
     Port     :: pos_integer(),
     NickName :: string(),
     UserName :: string(),
     RealName :: string(),
     Channel  :: string().

start_link( Server, Port, NickName, UserName, RealName, Channel ) ->
  gen_pnet:start_link( ?MODULE, {Server, Port, NickName, UserName, RealName, Channel}, [] ).


-spec start_link( ServerName, Server, Port, NickName, UserName, RealName, Channel ) -> gen_pnet:start_link_result()
when ServerName :: gen_pnet:server_name(),
     Server     :: string(),
     Port       :: pos_integer(),
     NickName   :: string(),
     UserName   :: string(),
     RealName   :: string(),
     Channel    :: string().

start_link( ServerName, Server, Port, NickName, UserName, RealName, Channel ) ->
  gen_pnet:start_link( ServerName, ?MODULE, {Server, Port, NickName, UserName, RealName, Channel}, [] ).


%%====================================================================
%% Interface callback functions
%%====================================================================

-spec code_change( OldVsn :: _, NetState :: _, Extra :: _ ) ->
        {ok, _} | {error, _}.

code_change( _OldVsn, NetState, _Extra ) -> {ok, NetState}.


-spec handle_call( Request :: _, From :: {pid(), _}, NetState :: _ ) ->
              {reply, _}
            | {reply, _, #{ atom() => [_] }, #{ atom() => [_] }}
            | noreply
            | {noreply, #{ atom() => [_] }, #{ atom() => [_] }}
            | {stop, _, _}.

handle_call( _Request, _From, _NetState ) -> {reply, {error, bad_msg}}.


-spec handle_cast( Request :: _, NetState :: _ ) ->
              noreply
            | {noreply, #{ atom() => [_] }, #{ atom() => [_] }}
            | {stop, _}.

handle_cast( _Request, _NetState ) -> noreply.


-spec handle_info( Info :: _, NetState :: _ ) ->
              noreply
            | {noreply, #{ atom() => [_] }, #{ atom() => [_] }}
            | {stop, _}.

handle_info( {tcp_closed, Socket}, NetState ) ->
  #irc_state{ socket = Socket } = gen_pnet:get_usr_info( NetState ),
  {stop, tcp_closed};

handle_info( {tcp, Socket, [$P, $I, $N, $G|X]}, NetState ) ->
  #irc_state{ socket = Socket } = gen_pnet:get_usr_info( NetState ),
  ok = gen_tcp:send( Socket, "PONG"++X ),
  noreply;

handle_info( {tcp, Socket, Data}, NetState ) ->
  #irc_state{ socket = Socket } = gen_pnet:get_usr_info( NetState ),
  [LineAcc] = gen_pnet:get_ls( 'Data', NetState ),
  {noreply, #{ 'Data' => [LineAcc] }, #{ 'Data' => [LineAcc++Data] }};

handle_info( _Request, _NetState ) -> noreply.


-spec init( Args :: _ ) -> {ok, _}.

init( {Server, Port, NickName, UserName, RealName, Channel} ) ->

  % create socket
  {ok, Socket} = gen_tcp:connect( Server, Port, [list, {active, true}] ),

  #irc_state{ socket    = Socket,
              nick_name = NickName,
              user_name = UserName,
              real_name = RealName,
              channel   = Channel }.


-spec terminate( Reason :: _, NetState :: _ ) -> ok.

terminate( _Reason, _NetState ) -> ok.


-spec trigger( Place :: atom(), Token :: _, NetState :: _ ) ->
            pass | drop.

trigger( 'Outbox', connect, NetState ) ->

  #irc_state{ socket    = Socket,
              nick_name = NickName,
              user_name = UserName,
              real_name = RealName } = gen_pnet:get_usr_info( NetState ),

  % send registration info
  ok = gen_tcp:send( Socket,
                     io_lib:format( "NICK ~s\r\nUSER ~s * 8 :~s\r\n",
                     [NickName, UserName, RealName] ) ),

  drop;

trigger( _Place, _Token, _NetState ) -> pass.


%%====================================================================
%% Petri net callback functions
%%====================================================================

-spec place_lst() -> [atom()].

place_lst() -> ['Data', 'Inbox', 'Outbox', 'State'].


-spec trsn_lst() -> [atom()].

trsn_lst() -> [recv, drop_msg, request_connect, ack_connect].


-spec init_marking( Place :: atom(), UsrInfo :: _ ) -> [_].

init_marking( 'Data', _ )        -> [""];
init_marking( 'State', _ )       -> [connect];
init_marking( _Place, _UsrInfo ) -> [].


-spec preset( Trsn :: atom() ) -> [atom()].

preset( recv )            -> ['Data'];
preset( drop_msg )        -> ['Inbox'];
preset( request_connect ) -> ['State'];
preset( ack_connect )     -> ['State', 'Inbox'].


-spec is_enabled( Trsn :: atom(), Mode :: #{ atom() => [_]}, UsrInfo :: _ ) ->
        boolean().

is_enabled( recv, #{ 'Data' := [S] }, _ ) ->
  case string:find( S, "\r\n" ) of
    nomatch -> false;
    _       -> true
  end;

is_enabled( request_connect, #{ 'State' := [connect] }, _ ) ->
  true;

is_enabled( ack_connect, #{ 'State' := [await_connect],
                            'Inbox' := [#msg{ command = "376" }] }, _ ) ->
  true;

is_enabled( ack_connect, #{ 'State' := [await_connect],
                            'Inbox' := [#msg{ command = "422" }] }, _ ) ->
  true;

is_enabled( _Trsn, _Mode, _UsrInfo ) -> false.


-spec fire( Trsn :: atom(), Mode :: #{ atom() => [_] }, UsrInfo :: _ ) ->
            abort | {produce, #{ atom() => [_] }}.

fire( recv, #{ 'Data' := [S] }, _ ) ->
  [Prefix, Suffix] = string:split( S, "\r\n" ),
  Msg = gen_ircclient_parse:parse_msg( Prefix ),
  {produce, #{ 'Data' => [Suffix], 'Inbox' => [Msg] }};

fire( request_connect, _, _ ) ->
  {produce, #{ 'State' => [await_connect], 'Outbox' => [connect] }};

fire( ack_connect, _, _ ) ->
  {produce, #{ 'State' => [join] }}.


