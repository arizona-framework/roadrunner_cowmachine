-module(roadrunner_cowmachine_handler_tests).

-include_lib("eunit/include/eunit.hrl").

%% `roadrunner_cowmachine_handler:request/1` builds cowmachine's Cowboy-shaped
%% request map from a Roadrunner request; it reads the request only, so it runs on
%% hand-built Roadrunner requests.

rr(Overrides) ->
    maps:merge(
        #{
            method => ~"GET",
            target => ~"/a?x=1",
            path => ~"/a",
            version => {1, 1},
            scheme => http,
            peer => {{127, 0, 0, 1}, 5555},
            listener_name => my_listener,
            headers => [{~"host", ~"Example.com:8080"}]
        },
        Overrides
    ).

request(Overrides) ->
    roadrunner_cowmachine_handler:request(rr(Overrides)).

fields_test() ->
    Req = request(#{}),
    ?assertMatch(
        #{
            cowmachine_server := roadrunner_cowmachine,
            ref := my_listener,
            method := ~"GET",
            version := 'HTTP/1.1',
            scheme := ~"http",
            host := ~"example.com",
            port := 8080,
            path := ~"/a",
            qs := ~"x=1",
            headers := #{~"host" := ~"Example.com:8080"},
            peer := {{127, 0, 0, 1}, 5555},
            sock := {{0, 0, 0, 0}, 0},
            cert := undefined,
            has_body := false,
            body_length := 0
        },
        Req
    ).

versions_test() ->
    ?assertEqual(
        ['HTTP/1.0', 'HTTP/1.1', 'HTTP/2', 'HTTP/3'],
        [maps:get(version, request(#{version => V})) || V <- [{1, 0}, {1, 1}, {2, 0}, {3, 0}]]
    ).

no_peer_test() ->
    ?assertMatch(#{peer := {{0, 0, 0, 0}, 0}}, request(#{peer => undefined})).

no_host_test() ->
    ?assertEqual(<<>>, maps:get(host, request(#{version => {1, 0}, headers => []}))).

repeated_headers_are_joined_test() ->
    Headers = [
        {~"host", ~"x"},
        {~"accept", ~"a"},
        {~"accept", ~"b"},
        {~"cookie", ~"c=1"},
        {~"cookie", ~"d=2"}
    ],
    ?assertMatch(
        #{~"accept" := ~"a, b", ~"cookie" := ~"c=1; d=2"},
        maps:get(headers, request(#{headers => Headers}))
    ).

connection_queries_test() ->
    Der = ~"der",
    ConnInfo = fun
        (sockname) -> {ok, {{10, 0, 0, 1}, 443}};
        (peercert) -> {ok, Der}
    end,
    Req = request(#{scheme => https, conn_info => ConnInfo}),
    ?assertMatch(#{sock := {{10, 0, 0, 1}, 443}, cert := Der, scheme := ~"https"}, Req).

no_peercert_test() ->
    ConnInfo = fun
        (sockname) -> {ok, {{10, 0, 0, 1}, 443}};
        (peercert) -> {error, no_peercert}
    end,
    ?assertMatch(#{cert := undefined}, request(#{scheme => https, conn_info => ConnInfo})).

body_length_test() ->
    Declared = request(#{
        headers => [{~"host", ~"x"}, {~"content-length", ~"5"}],
        body_reader => #{framing => {content_length, 5}}
    }),
    ?assertMatch(#{has_body := true, body_length := 5}, Declared),
    Chunked = request(#{
        headers => [{~"host", ~"x"}, {~"transfer-encoding", ~"chunked"}],
        body_reader => #{framing => chunked}
    }),
    ?assertMatch(#{has_body := true, body_length := undefined}, Chunked).
