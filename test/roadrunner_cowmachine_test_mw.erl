-module(roadrunner_cowmachine_test_mw).
-moduledoc false.

%% A `cowboy_middleware` for `roadrunner_cowmachine_SUITE`: it does what the
%% request's path names through `cowmachine_cowreq`, as cowmachine does, and
%% stops the chain. `/next` passes the request on to the next middleware.

-behaviour(cowboy_middleware).

-export([execute/2]).
-export([websocket_init/1, websocket_handle/2, websocket_info/2]).

execute(#{path := ~"/next"} = Req, Env) ->
    {ok, Req#{path := ~"/reply"}, Env};
execute(#{path := Path} = Req, Env) ->
    act(Path, Req, Env).

act(~"/nothing", Req, _Env) ->
    {stop, Req};
act(~"/reply", Req0, _Env) ->
    ok = cowmachine_cowreq:set_options(#{metrics_user_data => #{site => test}}, Req0),
    ok = cowmachine_cowreq:set_options(#{metrics_user_data => #{more => data}}, Req0),
    ok = cowmachine_cowreq:set_options(#{idle_timeout => infinity}, Req0),
    Req1 = cowmachine_cowreq:set_resp_header(~"x-set", ~"v", Req0),
    Req2 = cowmachine_cowreq:set_resp_cookie(~"a", ~"1", Req1),
    Req = cowmachine_cowreq:set_resp_body(~"replied", Req2),
    {stop, cowmachine_cowreq:reply(200, Req)};
act(~"/binary_status", Req, _Env) ->
    {stop, cowmachine_cowreq:reply(~"201 Created", #{}, ~"made", Req)};
act(~"/stream", Req0, _Env) ->
    Req = cowmachine_cowreq:stream_reply(200, #{~"content-type" => ~"text/plain"}, Req0),
    ok = cowmachine_cowreq:stream_body(~"one-", nofin, Req),
    ok = cowmachine_cowreq:stream_body([~"two"], fin, Req),
    {stop, Req};
act(~"/sendfile", Req, #{file := File}) ->
    {stop, cowmachine_cowreq:reply(200, #{}, {sendfile, 1, 3, File}, Req)};
act(~"/sendfile_sized", Req, #{file := File}) ->
    Headers = #{~"content-length" => ~"3"},
    {stop, cowmachine_cowreq:reply(200, Headers, {sendfile, 1, 3, File}, Req)};
act(~"/read_body", Req0, _Env) ->
    try read_body(Req0, []) of
        {Body, Req} -> {stop, cowmachine_cowreq:reply(200, #{}, Body, Req)}
    catch
        exit:{request_error, Reason, _Message} ->
            Body = iolist_to_binary(io_lib:format("~0p", [Reason])),
            {stop, cowmachine_cowreq:reply(400, #{}, Body, Req0)}
    end;
act(~"/inform", Req, _Env) ->
    ok = cowmachine_cowreq:inform(103, #{~"link" => ~"</a.css>; rel=preload"}, Req),
    {stop, cowmachine_cowreq:reply(200, #{}, ~"after hints", Req)};
act(~"/trailers", Req0, _Env) ->
    Req = cowmachine_cowreq:stream_reply(200, #{~"trailer" => ~"x-sum"}, Req0),
    ok = cowmachine_cowreq:stream_body(~"body", nofin, Req),
    ok = cowmachine_cowreq:stream_trailers(#{~"x-sum" => ~"1"}, Req),
    {stop, Req};
act(~"/read_parts", Req0, _Env) ->
    try read_parts(Req0, []) of
        {Body, Req} -> {stop, cowmachine_cowreq:reply(200, #{}, Body, Req)}
    catch
        exit:{request_error, Reason, _Message} ->
            Body = iolist_to_binary(io_lib:format("~0p", [Reason])),
            {stop, cowmachine_cowreq:reply(400, #{}, Body, Req0)}
    end;
act(~"/crash", _Req, _Env) ->
    error(crashed);
act(~"/ws", Req0, Env) ->
    Req = cowmachine_cowreq:set_resp_header(~"sec-websocket-protocol", ~"echo", Req0),
    Opts = #{idle_timeout => 60000, max_frame_size => 1000, compress => false, other => ignored},
    %% The upgrade is the response, so the chain stops here, as it does when
    %% cowmachine, the last middleware, upgrades.
    {ok, Upgraded, _Env} = cowmachine_server:websocket_upgrade(Req, Env, ?MODULE, #{}, Opts),
    {stop, Upgraded}.

read_body(Req0, Acc) ->
    case cowmachine_cowreq:read_body(Req0, #{length => 4}) of
        {more, Data, Req} -> read_body(Req, [Data | Acc]);
        {ok, Data, Req} -> {lists:reverse(Acc, [Data]), Req}
    end.

read_parts(Req0, Acc) ->
    case cowmachine_cowreq:read_part(Req0, #{}) of
        {ok, #{~"x-name" := Name}, Req1} ->
            {Body, Req} = read_part_body(Req1, []),
            read_parts(Req, [[Name, $=, Body, $;] | Acc]);
        {done, Req} ->
            {lists:reverse(Acc), Req}
    end.

read_part_body(Req0, Acc) ->
    case cowmachine_cowreq:read_part_body(Req0, #{length => 3}) of
        {more, Data, Req} -> read_part_body(Req, [Data | Acc]);
        {ok, Data, Req} -> {lists:reverse(Acc, [Data]), Req}
    end.

%% The WebSocket handler `/ws` upgrades to: it echoes text frames.

websocket_init(State) ->
    {ok, State}.

websocket_handle({text, Data}, State) ->
    {reply, {text, Data}, State};
websocket_handle(_Frame, State) ->
    {ok, State}.

websocket_info(_Info, State) ->
    {ok, State}.
