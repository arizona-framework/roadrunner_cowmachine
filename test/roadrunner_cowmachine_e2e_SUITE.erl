-module(roadrunner_cowmachine_e2e_SUITE).
-moduledoc """
cowmachine's own end-to-end tests (`cowmachine_e2e_tests`, as cowmachine's
repository has them), run on Roadrunner: they walk cowmachine's HTTP
decision flow over real requests, on the server the `cowmachine`
application's `server` key names.
""".

-behaviour(ct_suite).

-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, init_per_suite/1, end_per_suite/1]).
-export([cowmachine_e2e_tests/1]).

suite() ->
    [{timetrap, {seconds, 120}}].

all() ->
    [cowmachine_e2e_tests].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(roadrunner_cowmachine),
    ok = application:set_env(cowmachine, server, roadrunner_cowmachine),
    Config.

end_per_suite(_Config) ->
    ok = application:unset_env(cowmachine, server).

cowmachine_e2e_tests(_Config) ->
    ?assertEqual(roadrunner_cowmachine, cowmachine_server:module()),
    ?assertEqual(ok, eunit:test(cowmachine_e2e_tests, [])).
