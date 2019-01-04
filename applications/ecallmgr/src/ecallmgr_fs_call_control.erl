%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2012-2019, 2600Hz
%%% @doc
%%% @end
%%%-----------------------------------------------------------------------------
-module(ecallmgr_fs_call_control).

-behaviour(gen_listener).

-export([start_link/2]).

-export([control_q/1]).

-export([init/1
        ,handle_call/3
        ,handle_cast/2
        ,handle_info/2
        ,handle_event/4
        ,terminate/2
        ,code_change/3
        ]).

-include("ecallmgr.hrl").

-define(RESPONDERS, []).

-define(BINDINGS, [{'dialplan', []}
                  ,{'self', []}
                  ]).

-define(QUEUE_NAME, <<>>).
-define(QUEUE_OPTIONS, []).
-define(CONSUME_OPTIONS, []).

-define(SERVER, ?MODULE).


-type state() :: map().

%%%=============================================================================
%%% API
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec start_link(atom(), kz_term:proplist()) -> kz_types:startlink_ret().
start_link(Node, Options) ->
    gen_listener:start_link(?MODULE
                           ,[{'responders', ?RESPONDERS}
                            ,{'bindings', ?BINDINGS}
                            ,{'queue_name', ?QUEUE_NAME}
                            ,{'queue_options', ?QUEUE_OPTIONS}
                            ,{'consume_options', ?CONSUME_OPTIONS}
                            ]
                           ,[Node, Options]).


%%%=============================================================================
%%% gen_server callbacks
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc Initializes the server
%%
%% @end
%%------------------------------------------------------------------------------
-spec init([atom() | kz_term:proplist()]) -> {'ok', state()}.
init([Node, Options]) ->
    process_flag('trap_exit', 'true'),
    kz_util:put_callid(Node),
    lager:info("starting new fs amqp event listener for ~s", [Node]),
    {'ok', #{node => Node, options => Options}}.

-spec handle_call(any(), kz_term:pid_ref(), state()) -> kz_types:handle_call_ret_state(state()).
handle_call('control_q', _From, #{queue := Q}=State) ->
    {'reply', {'ok', Q, kz_amqp_channel:consumer_channel()}, State};
handle_call('control_q', _From, State) ->
    {'reply', {'error', 'no_queue'}, State};
handle_call(_Request, _From, State) ->
    {'reply', {'error', 'not_implemented'}, State}.

%%------------------------------------------------------------------------------
%% @doc Handling cast messages
%%
%% @end
%%------------------------------------------------------------------------------
-spec handle_cast(any(), state()) -> {'noreply', state()}.
handle_cast({'gen_listener',{'is_consuming', 'false'}}, State) ->
    {'noreply', State#{active => 'false'}};
handle_cast({'gen_listener',{'is_consuming', 'true'}}, State) ->
    {'noreply', State};
handle_cast({'gen_listener',{'created_queue', Q}}, State) ->
    {'noreply', State#{queue => Q}};
handle_cast(_Cast, State) ->
    lager:debug("unhandled cast: ~p", [_Cast]),
    {'noreply', State, 'hibernate'}.

%%------------------------------------------------------------------------------
%% @doc Handling all non call/cast messages
%%
%% @end
%%------------------------------------------------------------------------------
-spec handle_info(any(), state()) -> kz_types:handle_info_ret_state(state()).
handle_info(_Info, State) ->
    lager:debug("unhandled message: ~p", [_Info]),
    {'noreply', State}.

%%------------------------------------------------------------------------------
%% @doc Allows listener to pass options to handlers
%%
%% @end
%%------------------------------------------------------------------------------
-spec handle_event(kz_json:object(), basic_deliver(), amqp_basic(), state()) -> 'ignore'.
handle_event(JObj, _Deliver, Basic, _State) ->
    Props = [{'basic', Basic}],
    case kz_api:event_name(JObj) of
        <<"route_resp">> -> handle_route_resp(JObj, Props);
        ?ROUTE_WINNER_EVENT -> handle_route_winner(JObj, Props);
        Event -> handle_call_control(Event, JObj, Props)
    end.

handle_call_control(Event, JObj, _Props) ->
    kz_util:put_callid(JObj),
    case kz_api:deliver_to(JObj) of
        'undefined' -> lager:debug_unsafe("received event without deliver_to : ~s", [kz_json:encode(JObj, ['pretty'])]);
        Pid -> lager:debug("delivering ~s to ~s", [Event, Pid]),
               kz_term:to_pid(Pid) ! {'call_control', JObj}
    end,
    'ignore'.

handle_route_resp(JObj, Props) ->
    Pid = kz_term:to_pid(kz_api:reply_to(JObj)),
    Pid ! {'route_resp', JObj, Props},
    'ignore'.

handle_route_winner(JObj, Props) ->
    Pid = kz_term:to_pid(kz_api:reply_to(JObj)),
    Pid ! {'route_winner', JObj, Props},
    'ignore'.

%%------------------------------------------------------------------------------
%% @doc This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @end
%%------------------------------------------------------------------------------
-spec terminate(any(), state()) -> 'ok'.
terminate(_Reason, _State) ->
    lager:debug("fs amqp authn termination: ~p", [ _Reason]).

%%------------------------------------------------------------------------------
%% @doc Convert process state when code is changed
%%
%% @end
%%------------------------------------------------------------------------------
-spec code_change(any(), state(), any()) -> {'ok', state()}.
code_change(_OldVsn, State, _Extra) ->
    {'ok', State}.

-spec control_q(pid()) -> {'ok', kz_term:ne_binary(), pid()} | {'error', 'no_queue'}.
control_q(Pid) ->
    gen_listener:call(Pid, 'control_q').
