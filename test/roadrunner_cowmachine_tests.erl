-module(roadrunner_cowmachine_tests).

-include_lib("eunit/include/eunit.hrl").

ws_opts_without_options_test() ->
    ?assertEqual(#{headers => []}, roadrunner_cowmachine:ws_opts(#{}, #{})).

ws_opts_maps_cowboy_options_test() ->
    Opts = #{idle_timeout => 1000, max_frame_size => 64, compress => true, active_n => 10},
    Req = #{
        resp_headers => #{~"sec-websocket-protocol" => ~"mqtt"},
        resp_cookies => #{~"z.sid" => ~"z.sid=1"}
    },
    ?assertEqual(
        #{
            headers => [{~"sec-websocket-protocol", ~"mqtt"}, {~"set-cookie", ~"z.sid=1"}],
            idle_timeout => 1000,
            max_frame_size => 64,
            max_message_size => 64,
            compress => true
        },
        roadrunner_cowmachine:ws_opts(Opts, Req)
    ).

ws_opts_unbounded_frames_test() ->
    ?assertEqual(
        #{headers => []}, roadrunner_cowmachine:ws_opts(#{max_frame_size => infinity}, #{})
    ).
