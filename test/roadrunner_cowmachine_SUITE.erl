-module(roadrunner_cowmachine_SUITE).
-moduledoc """
`roadrunner_cowmachine` over real connections: what cowmachine does through
`cowmachine_server` (responses, streams, files, body reads and their errors,
WebSocket upgrades), the metrics a listener reports, and the listener
options (TLS, IPv4 and IPv6 on one port, Roadrunner's own options).

Most cases drive `roadrunner_cowmachine_test_mw`, a middleware that does
what the request's path names.
""".

-behaviour(ct_suite).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([
    nothing_sent_is_204/1,
    reply_with_cookie_and_headers/1,
    next_middleware/1,
    binary_status/1,
    inform_goes_before_the_response/1,
    streams_the_body/1,
    streams_trailers/1,
    sendfile_sends_the_range/1,
    sendfile_keeps_its_content_length/1,
    reads_the_body_in_pieces/1,
    body_read_timeout/1,
    body_over_the_cap/1,
    malformed_chunked_body/1,
    reads_multipart_parts/1,
    malformed_multipart/1,
    multipart_part_cut_short/1,
    multipart_read_timeout/1,
    metrics_of_a_reply/1,
    metrics_of_a_body_and_a_stream/1,
    metrics_of_nothing_sent/1,
    metrics_of_a_crash/1,
    metrics_of_a_websocket/1,
    websocket_echoes/1,
    tls_listener/1,
    ipv4_and_ipv6_share_a_port/1,
    listener_options/1,
    listener_info/1
]).

-define(MW, roadrunner_cowmachine_test_mw).

suite() ->
    [{timetrap, {seconds, 60}}].

all() ->
    [
        nothing_sent_is_204,
        reply_with_cookie_and_headers,
        next_middleware,
        binary_status,
        inform_goes_before_the_response,
        streams_the_body,
        streams_trailers,
        sendfile_sends_the_range,
        sendfile_keeps_its_content_length,
        reads_the_body_in_pieces,
        body_read_timeout,
        body_over_the_cap,
        malformed_chunked_body,
        reads_multipart_parts,
        malformed_multipart,
        multipart_part_cut_short,
        multipart_read_timeout,
        metrics_of_a_reply,
        metrics_of_a_body_and_a_stream,
        metrics_of_nothing_sent,
        metrics_of_a_crash,
        metrics_of_a_websocket,
        websocket_echoes,
        tls_listener,
        ipv4_and_ipv6_share_a_port,
        listener_options,
        listener_info
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(roadrunner_cowmachine),
    {ok, _} = application:ensure_all_started(ssl),
    File = filename:join(?config(priv_dir, Config), "file.txt"),
    ok = file:write_file(File, ~"0123456789"),
    [{file, File} | Config].

end_per_suite(_Config) ->
    ok.

%% Each case gets its own listener, reporting its metrics to the case.
init_per_testcase(_Case, Config) ->
    Self = self(),
    {ok, _} = roadrunner_cowmachine:start_listener(rr_cm_test, #{
        port => 0,
        middlewares => [?MW, ?MW],
        env => #{file => ?config(file, Config)},
        request_timeout => 1000,
        metrics_callback => fun(Metrics) -> Self ! {metrics, Metrics} end,
        metrics_req_filter => fun(Req) -> maps:with([method, path], Req) end,
        options => #{max_content_length => 1000000}
    }),
    [{port, roadrunner_cowmachine:port(rr_cm_test)} | Config].

end_per_testcase(_Case, _Config) ->
    ok = roadrunner_cowmachine:stop_listener(rr_cm_test).

%% =============================================================================
%% Responses
%% =============================================================================

nothing_sent_is_204(Config) ->
    ?assertMatch({204, _, <<>>}, request(Config, ~"GET /nothing HTTP/1.1\r\n", <<>>)).

reply_with_cookie_and_headers(Config) ->
    {200, Headers, Body} = request(Config, ~"GET /reply HTTP/1.1\r\n", <<>>),
    ?assertEqual(~"replied", Body),
    {match, _} = re:run(Headers, "(?i)\r\nset-cookie: a=1"),
    {match, _} = re:run(Headers, "(?i)\r\nx-set: v\r\n").

next_middleware(Config) ->
    ?assertMatch({200, _, ~"replied"}, request(Config, ~"GET /next HTTP/1.1\r\n", <<>>)).

binary_status(Config) ->
    ?assertMatch({201, _, ~"made"}, request(Config, ~"GET /binary_status HTTP/1.1\r\n", <<>>)).

inform_goes_before_the_response(Config) ->
    Raw = raw("localhost", ?config(port, Config), [~"GET /inform HTTP/1.1\r\n", headers(), ~"\r\n"]),
    ?assertMatch(<<"HTTP/1.1 103 ", _/binary>>, Raw),
    {match, _} = re:run(Raw, "(?i)\r\nlink: </a.css>; rel=preload\r\n"),
    {match, _} = re:run(Raw, "HTTP/1.1 200 [^\r]*\r\n(.|\r\n)*after hints$").

streams_the_body(Config) ->
    ?assertMatch({200, _, ~"one-two"}, request(Config, ~"GET /stream HTTP/1.1\r\n", <<>>)).

streams_trailers(Config) ->
    Raw = raw(
        "localhost", ?config(port, Config), [
            ~"GET /trailers HTTP/1.1\r\nte: trailers\r\n", headers(), ~"\r\n"
        ]
    ),
    {match, _} = re:run(Raw, "\r\nbody\r\n"),
    {match, _} = re:run(Raw, "(?i)\r\nx-sum: 1\r\n").

sendfile_sends_the_range(Config) ->
    {200, Headers, Body} = request(Config, ~"GET /sendfile HTTP/1.1\r\n", <<>>),
    ?assertEqual(~"123", Body),
    {match, _} = re:run(Headers, "(?i)\r\ncontent-length: 3\r\n").

sendfile_keeps_its_content_length(Config) ->
    {200, Headers, ~"123"} = request(Config, ~"GET /sendfile_sized HTTP/1.1\r\n", <<>>),
    ?assertMatch({match, [_]}, re:run(Headers, "(?i)\r\ncontent-length:", [global])).

%% =============================================================================
%% Reading the body
%% =============================================================================

reads_the_body_in_pieces(Config) ->
    ?assertMatch(
        {200, _, ~"0123456789"},
        request(Config, ~"POST /read_body HTTP/1.1\r\ncontent-length: 10\r\n", ~"0123456789")
    ).

body_read_timeout(Config) ->
    ?assertMatch(
        {400, _, ~"timeout"},
        request(Config, ~"POST /read_body HTTP/1.1\r\ncontent-length: 100\r\n", ~"part")
    ).

body_over_the_cap(Config) ->
    ?assertMatch(
        {400, _, ~"payload_too_large"},
        request(Config, ~"POST /read_body HTTP/1.1\r\ncontent-length: 2000000\r\n", <<>>)
    ).

malformed_chunked_body(Config) ->
    {400, _, Reason} = request(
        Config, ~"POST /read_body HTTP/1.1\r\ntransfer-encoding: chunked\r\n", ~"zz\r\n"
    ),
    ?assertNotEqual(~"timeout", Reason).

reads_multipart_parts(Config) ->
    Body = <<
        "--B\r\nx-name: a\r\n\r\nhello\r\n",
        "--B\r\nx-name: b\r\n\r\nworld!\r\n--B--\r\n"
    >>,
    ?assertMatch(
        {200, _, ~"a=hello;b=world!;"},
        request(Config, multipart_head(byte_size(Body)), Body)
    ),
    ?assertMatch(#{req_body_length := 11}, metrics()).

malformed_multipart(Config) ->
    ?assertMatch(
        {400, _, ~"{multipart,no_initial_boundary}"},
        request(Config, multipart_head(7), ~"garbage")
    ).

multipart_part_cut_short(Config) ->
    %% The body ends inside a part: its body read fails.
    Body = <<"--B\r\nx-name: a\r\n\r\ncut short">>,
    ?assertMatch(
        {400, _, ~"{multipart,no_part_terminator}"},
        request(Config, multipart_head(byte_size(Body)), Body)
    ).

multipart_read_timeout(Config) ->
    Body = <<"--B\r\nx-name: a\r\n\r\nshort">>,
    ?assertMatch({400, _, ~"timeout"}, request(Config, multipart_head(500), Body)).

%% =============================================================================
%% Metrics
%% =============================================================================

metrics_of_a_reply(Config) ->
    {200, _, _} = request(Config, ~"GET /reply HTTP/1.1\r\n", <<>>),
    #{
        reason := normal,
        req := Req,
        resp_status := 200,
        resp_headers := RespHeaders,
        resp_body_length := 7,
        req_body_length := 0,
        req_body_start := undefined,
        user_data := UserData,
        req_start := ReqStart,
        resp_start := RespStart,
        resp_end := RespEnd,
        req_end := ReqEnd
    } = metrics(),
    ?assertEqual(#{method => ~"GET", path => ~"/reply"}, Req),
    ?assertEqual(#{site => test, more => data}, UserData),
    ?assertMatch(#{~"x-set" := ~"v"}, RespHeaders),
    ?assert(ReqStart =< RespStart andalso RespStart =< RespEnd andalso RespEnd =< ReqEnd).

metrics_of_a_body_and_a_stream(Config) ->
    {200, _, _} = request(
        Config, ~"POST /read_body HTTP/1.1\r\ncontent-length: 10\r\n", ~"0123456789"
    ),
    #{req_body_length := 10, req_body_start := Start, req_body_end := End} = metrics(),
    ?assert(is_integer(Start) andalso Start =< End),
    {200, _, _} = request(Config, ~"GET /stream HTTP/1.1\r\n", <<>>),
    ?assertMatch(
        #{resp_status := 200, resp_body_length := 7, resp_end := E} when is_integer(E), metrics()
    ).

metrics_of_nothing_sent(Config) ->
    {204, _, _} = request(Config, ~"GET /nothing HTTP/1.1\r\n", <<>>),
    ?assertMatch(#{resp_status := 204, resp_headers := #{}, user_data := #{}}, metrics()).

metrics_of_a_crash(Config) ->
    {500, _, _} = request(Config, ~"GET /crash HTTP/1.1\r\n", <<>>),
    ?assertMatch(
        #{reason := {internal_error, {error, crashed}, _}, resp_headers := undefined}, metrics()
    ).

metrics_of_a_websocket(Config) ->
    Socket = ws_connect(?config(port, Config)),
    ok = gen_tcp:close(Socket),
    ?assertMatch(#{reason := normal, resp_status := 101}, metrics()).

%% =============================================================================
%% WebSockets
%% =============================================================================

websocket_echoes(Config) ->
    Socket = ws_connect(?config(port, Config)),
    ok = gen_tcp:send(Socket, masked_text(~"hello")),
    {ok, <<1:1, 0:3, 1:4, 0:1, 5:7, "hello">>} = gen_tcp:recv(Socket, 7, 5000),
    ok = gen_tcp:close(Socket).

%% =============================================================================
%% Listeners
%% =============================================================================

tls_listener(_Config) ->
    #{server_config := ServerConfig, client_config := ClientConfig} = certs(),
    %% Ranch refs can be any term; Roadrunner names listeners with atoms.
    Ref = {rr_cm_test, tls},
    {ok, _} = roadrunner_cowmachine:start_listener(Ref, #{
        port => 0, tls => ServerConfig, middlewares => [?MW]
    }),
    try
        Port = roadrunner_cowmachine:port(Ref),
        {ok, {{_, 201, _}, _, Body}} = httpc:request(
            get,
            {"https://localhost:" ++ integer_to_list(Port) ++ "/binary_status", []},
            [{ssl, [{verify, verify_none} | proplists:delete(verify, ClientConfig)]}],
            [{body_format, binary}]
        ),
        ?assertEqual(~"made", Body)
    after
        ok = roadrunner_cowmachine:stop_listener(Ref)
    end.

ipv4_and_ipv6_share_a_port(_Config) ->
    {ok, _} = roadrunner_cowmachine:start_listener(rr_cm_v4, #{
        port => 0,
        ip => {0, 0, 0, 0},
        backlog => 64,
        max_connections => 100,
        num_acceptors => 2,
        middlewares => [?MW]
    }),
    Port = roadrunner_cowmachine:port(rr_cm_v4),
    try
        {ok, _} = roadrunner_cowmachine:start_listener(rr_cm_v6, #{
            port => Port,
            ip => {0, 0, 0, 0, 0, 0, 0, 0},
            ipv6_v6only => true,
            middlewares => [?MW]
        }),
        try
            ?assertMatch(
                {201, _, ~"made"}, request(Port, ~"GET /binary_status HTTP/1.1\r\n", <<>>)
            ),
            %% Nothing sent, without metrics to report it to.
            ?assertMatch({204, _, <<>>}, request(Port, ~"GET /nothing HTTP/1.1\r\n", <<>>)),
            ?assertMatch(
                {201, _, ~"made"},
                request({{0, 0, 0, 0, 0, 0, 0, 1}, Port}, ~"GET /binary_status HTTP/1.1\r\n", <<>>)
            )
        after
            ok = roadrunner_cowmachine:stop_listener(rr_cm_v6)
        end
    after
        ok = roadrunner_cowmachine:stop_listener(rr_cm_v4)
    end.

%% Options without a Roadrunner counterpart are left out, and the server's
%% own `options` win over the shared keys. Without filters, the metrics carry
%% the whole request and response headers.
listener_options(_Config) ->
    Self = self(),
    {ok, _} = roadrunner_cowmachine:start_listener(rr_cm_options, #{
        port => 0,
        max_connections => infinity,
        request_timeout => infinity,
        metrics_callback => fun(Metrics) -> Self ! {metrics, Metrics} end,
        middlewares => [?MW],
        options => #{num_acceptors => 1}
    }),
    try
        Port = roadrunner_cowmachine:port(rr_cm_options),
        ?assertMatch({201, _, ~"made"}, request(Port, ~"GET /binary_status HTTP/1.1\r\n", <<>>)),
        #{req := Req, resp_headers := RespHeaders} = metrics(),
        ?assertMatch(#{method := ~"GET", headers := #{~"host" := _}}, Req),
        ?assertNot(is_map_key(roadrunner_req, Req)),
        ?assert(is_map(RespHeaders))
    after
        ok = roadrunner_cowmachine:stop_listener(rr_cm_options)
    end,
    ?assertEqual({error, not_found}, roadrunner_cowmachine:stop_listener(rr_cm_gone)).

%% A listener reports its state, port and connections.
listener_info(Config) ->
    Port = ?config(port, Config),
    {ok, Info} = roadrunner_cowmachine:info(rr_cm_test),
    ?assertMatch(
        #{status := running, port := Port, active_connections := 0, all_connections := 0}, Info
    ),
    ?assert(is_integer(maps:get(max_connections, Info))),
    ?assertEqual({error, not_found}, roadrunner_cowmachine:info(rr_cm_gone)).

%% =============================================================================
%% Helpers
%% =============================================================================

metrics() ->
    receive
        {metrics, Metrics} -> Metrics
    after 5000 -> error(no_metrics)
    end.

%% A server and client chain, with RSA keys as Roadrunner's own TLS tests
%% use.
certs() ->
    Key = fun() -> public_key:generate_key({rsa, 2048, 65537}) end,
    Chain = fun() ->
        #{root => [{key, Key()}, {digest, sha256}], peer => [{key, Key()}, {digest, sha256}]}
    end,
    public_key:pkix_test_data(#{server_chain => Chain(), client_chain => Chain()}).

ws_connect(Port) ->
    {ok, Socket} = gen_tcp:connect("localhost", Port, [binary, {active, false}]),
    ok = gen_tcp:send(Socket, [
        ~"GET /ws HTTP/1.1\r\nhost: localhost\r\nupgrade: websocket\r\nconnection: upgrade\r\n",
        ~"sec-websocket-key: dGhlIHNhbXBsZSBub25jZQ==\r\nsec-websocket-version: 13\r\n",
        ~"sec-websocket-protocol: echo\r\n\r\n"
    ]),
    {ok, Head} = recv_head(Socket, <<>>),
    ?assertMatch(<<"HTTP/1.1 101 ", _/binary>>, Head),
    {match, _} = re:run(Head, "(?i)\r\nsec-websocket-protocol: echo\r\n"),
    Socket.

recv_head(Socket, Acc) ->
    case binary:match(Acc, ~"\r\n\r\n") of
        nomatch ->
            {ok, Data} = gen_tcp:recv(Socket, 0, 5000),
            recv_head(Socket, <<Acc/binary, Data/binary>>);
        _ ->
            {ok, Acc}
    end.

masked_text(Payload) ->
    Mask = <<1, 2, 3, 4>>,
    <<1:1, 0:3, 1:4, 1:1, (byte_size(Payload)):7, Mask/binary, (mask(Payload, Mask))/binary>>.

mask(Payload, <<M1, M2, M3, M4>>) ->
    Masks = [M1, M2, M3, M4],
    <<
        <<(B bxor lists:nth((I rem 4) + 1, Masks))>>
     || {I, B} <- lists:zip(lists:seq(0, byte_size(Payload) - 1), binary_to_list(Payload))
    >>.

headers() ->
    ~"host: localhost\r\nconnection: close\r\n".

multipart_head(Size) ->
    [
        ~"POST /read_parts HTTP/1.1\r\ncontent-type: multipart/form-data; boundary=B\r\n",
        ~"content-length: ",
        integer_to_binary(Size),
        ~"\r\n"
    ].

request(Config, Head, Body) when is_list(Config) ->
    request(?config(port, Config), Head, Body);
request(Port, Head, Body) when is_integer(Port) ->
    request({"localhost", Port}, Head, Body);
request({Host, Port}, Head, Body) ->
    Raw = raw(Host, Port, [Head, headers(), ~"\r\n", Body]),
    <<"HTTP/1.1 ", Code:3/binary, _/binary>> = Raw,
    [Headers, RespBody] = binary:split(Raw, ~"\r\n\r\n"),
    {binary_to_integer(Code), <<Headers/binary, "\r\n">>, body(Headers, RespBody)}.

body(Headers, Body) ->
    case re:run(Headers, "(?i)\r\ntransfer-encoding: chunked") of
        {match, _} -> dechunk(Body);
        nomatch -> Body
    end.

dechunk(Body) ->
    [SizeLine, Rest] = binary:split(Body, ~"\r\n"),
    case binary_to_integer(SizeLine, 16) of
        0 ->
            <<>>;
        Size ->
            <<Data:Size/binary, "\r\n", More/binary>> = Rest,
            <<Data/binary, (dechunk(More))/binary>>
    end.

raw(Host, Port, Data) ->
    {ok, Socket} = gen_tcp:connect(Host, Port, [binary, {active, false}]),
    ok = gen_tcp:send(Socket, Data),
    Response = recv_all(Socket, <<>>),
    ok = gen_tcp:close(Socket),
    Response.

recv_all(Socket, Acc) ->
    case gen_tcp:recv(Socket, 0, 10000) of
        {ok, Bytes} -> recv_all(Socket, <<Acc/binary, Bytes/binary>>);
        {error, closed} -> Acc
    end.
