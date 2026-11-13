-module(roadrunner_cowmachine_ws_tests).

-include_lib("eunit/include/eunit.hrl").

%% `roadrunner_cowmachine_ws` translates Cowboy WebSocket callbacks and their
%% results; it touches no connection, so its callbacks are called directly.

-define(WS, roadrunner_cowmachine_ws).

session(Fun) ->
    #{handler => roadrunner_cowmachine_ws_fake, state => Fun, req => #{path => ~"/ws"}}.

returning(Result) ->
    session(fun(_Call) -> Result end).

init_runs_websocket_init_test() ->
    S = session(fun(init) -> {reply, {text, ~"hi"}, new} end),
    ?assertMatch({reply, [{text, ~"hi"}], #{state := new}}, ?WS:init(S)).

init_without_websocket_init_test() ->
    S = #{handler => roadrunner_cowmachine_ws_bare, state => st, req => #{}},
    ?assertEqual({ok, S}, ?WS:init(S)).

frames_reach_websocket_handle_test() ->
    Self = self(),
    S = session(fun(Call) ->
        Self ! Call,
        {ok, s}
    end),
    {ok, _} = ?WS:handle_frame(#{opcode => text, payload => [~"a", ~"b"]}, S),
    {ok, _} = ?WS:handle_frame(#{opcode => binary, payload => ~"bin"}, S),
    {ok, _} = ?WS:handle_control(#{opcode => ping, payload => ~"p"}, S),
    {ok, _} = ?WS:handle_control(#{opcode => pong, payload => <<>>}, S),
    ?assertEqual(
        [
            {handle, {text, ~"ab"}},
            {handle, {binary, ~"bin"}},
            {handle, {ping, ~"p"}},
            {handle, {pong, <<>>}}
        ],
        [
            receive
                M -> M
            after 0 -> none
            end
         || _ <- lists:seq(1, 4)
        ]
    ).

info_reaches_websocket_info_test() ->
    S = session(fun({info, hello}) -> {ok, got} end),
    ?assertMatch({ok, #{state := got}}, ?WS:handle_info(hello, S)).

drain_closes_as_going_away_test() ->
    S = returning(unused),
    ?assertEqual({close, 1001, <<>>, S}, ?WS:handle_drain(0, S)).

results_test_() ->
    Frame = #{opcode => text, payload => ~"x"},
    Cases = [
        {{stop, s1}, {close, 1000, <<>>, s1}},
        {{ok, s1}, {ok, s1}},
        {{ok, s1, hibernate}, {ok, s1, [hibernate]}},
        {{reply, {text, ~"a"}, s1}, {reply, [{text, ~"a"}], s1}},
        {
            {reply, [{text, ~"a"}, ping], s1, hibernate},
            {reply, [{text, ~"a"}, {ping, <<>>}], s1, [hibernate]}
        },
        {
            {[{binary, ~"b"}, pong, {active, false}], s1},
            {reply, [{binary, ~"b"}, {pong, <<>>}], s1}
        },
        {{[{text, ~"a"}], s1, hibernate}, {reply, [{text, ~"a"}], s1, [hibernate]}},
        {{[close], s1}, {close, 1000, <<>>, s1}},
        {
            {[{text, ~"bye"}, {close, 4000, ~"done"}, {text, ~"dropped"}], s1},
            {close, 4000, ~"done", [{text, ~"bye"}], s1}
        },
        {{[{close, <<1001:16, "away">>}], s1}, {close, 1001, ~"away", s1}},
        {{[{close, <<>>}], s1}, {close, 1000, <<>>, s1}}
    ],
    [
        ?_assertEqual(
            Expected, strip(?WS:handle_frame(Frame, returning(Result)))
        )
     || {Result, Expected} <- Cases
    ].

%% The result with the session in it replaced by the handler's state.
strip(Result) ->
    list_to_tuple([
        case Element of
            #{state := State} -> State;
            _ -> Element
        end
     || Element <- tuple_to_list(Result)
    ]).

terminate_reports_cowboy_reasons_test() ->
    Self = self(),
    S = session(fun(Call) -> Self ! Call end),
    Cases = [
        {normal, stop},
        {shutdown, stop},
        {remote, remote},
        {{remote, 1000, ~"bye"}, {remote, 1000, ~"bye"}},
        {timeout, timeout},
        {{error, closed}, {error, closed}}
    ],
    [
        begin
            ok = ?WS:terminate(Reason, S),
            ?assertEqual(
                {terminate, Cowboy, #{path => ~"/ws"}},
                receive
                    M -> M
                after 0 -> none
                end
            )
        end
     || {Reason, Cowboy} <- Cases
    ].

terminate_without_the_callback_test() ->
    ?assertEqual(
        ok,
        ?WS:terminate(normal, #{handler => roadrunner_cowmachine_ws_bare, state => s, req => #{}})
    ).
