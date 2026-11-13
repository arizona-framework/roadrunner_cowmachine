-module(roadrunner_cowmachine).
-moduledoc """
Run [cowmachine](https://github.com/zotonic/cowmachine) on Roadrunner.

This module is a cowmachine server (`cowmachine_server`). Set it as
cowmachine's `server`, and the listeners `cowmachine_server:start_listener/2`
starts run on Roadrunner instead of Cowboy:

```erlang
{cowmachine, [
    {server, roadrunner_cowmachine}
]}
```

Middlewares and controllers get a request map shaped like Cowboy's, and run
unchanged as long as they use `cowmachine_cowreq` rather than `cowboy_req`
for what touches the connection (sending a response, reading the body).

The listener options mean what `cowmachine_server` says:

- `port`, `ip`, `ipv6_v6only`, and `tls` for HTTPS (the `ssl` server
  options). Over TLS a listener serves HTTP/2 and HTTP/1.1, as Cowboy
  does, and plain HTTP/1.1 otherwise: Roadrunner can't serve HTTP/1.1 and
  cleartext HTTP/2 on one port, and browsers only use HTTP/2 over TLS.
- `backlog`, `max_connections` and `num_acceptors`, Roadrunner's
  `socket_backlog`, `max_clients` and `num_acceptors`
- `request_timeout`, in milliseconds
- `middlewares` and `env`: each request runs through the middlewares,
  starting from `env`
- `metrics_callback`, `metrics_req_filter` and
  `metrics_resp_headers_filter`, described below
- `options`: the server's own options, here any
  `t:roadrunner_listener:opts/0`, such as `max_concurrent_requests`, which
  win over those the shared keys set

```erlang
{ok, _} = cowmachine_server:start_listener(my_listener, #{
    port => 8000,
    middlewares => [my_dispatcher, cowmachine],
    options => #{max_concurrent_requests => 10_000}
}).
```

## Metrics

With a `metrics_callback`, each request ends with a call to it carrying the
map Cowboy's `cowboy_metrics_h` builds: `ref`, `pid`, `streamid`, `reason`
(`normal`, or `{internal_error, {Class, Reason}, Message}` when a middleware
raised), `req` (through `metrics_req_filter`), `resp_status`,
`resp_headers` (through `metrics_resp_headers_filter`), `req_start`,
`req_end`, `req_body_start`, `req_body_end`, `req_body_length`,
`resp_start`, `resp_end`, `resp_body_length` and `user_data`, the
`metrics_user_data` set with `cowmachine_cowreq:set_options/2`. Times are
`erlang:monotonic_time/0` values; `req_start` is when the middlewares
start, after Roadrunner has read the request's headers.

## WebSockets

A controller's WebSocket upgrade runs its `cowboy_websocket` callbacks on a
Roadrunner WebSocket session. Cowboy's `idle_timeout`, `max_frame_size`
and `compress` options carry over. A WebSocket needs HTTP/1.1.
""".

-behaviour(cowmachine_server).

-export([
    start_listener/2,
    stop_listener/1,
    port/1,
    info/1,
    reply/4,
    inform/3,
    stream_reply/3,
    stream_body/3,
    stream_trailers/2,
    read_body/2,
    read_part/2,
    read_part_body/2,
    set_options/2,
    websocket_upgrade/5
]).

-export([ws_opts/2]).

%% Cowboy's defaults for the body-reading `length` option.
-define(READ_BODY_LENGTH, 8000000).
-define(READ_PART_LENGTH, 64000).

%% The process dictionary key of the request's metrics.
-define(METRICS, roadrunner_cowmachine_metrics).

%% =============================================================================
%% Listeners
%% =============================================================================

-doc false.
-spec start_listener(cowmachine_server:listener_ref(), cowmachine_server:listener_opts()) ->
    {ok, pid()} | {error, term()}.
start_listener(Ref, #{port := Port, middlewares := Middlewares} = Opts) ->
    State = #{
        middlewares => Middlewares,
        env => maps:get(env, Opts, #{}),
        metrics => metrics_opts(Opts)
    },
    Shared = maps:fold(fun listener_opt/3, #{port => Port}, Opts),
    Listener = (maps:merge(Shared, maps:get(options, Opts, #{})))#{
        body_buffering => manual,
        routes => {roadrunner_cowmachine_handler, State}
    },
    %% cowmachine's listeners can start before Roadrunner's application has.
    {ok, _} = application:ensure_all_started(roadrunner),
    roadrunner:start_listener(name(Ref), Listener).

-doc false.
-spec stop_listener(cowmachine_server:listener_ref()) -> ok | {error, not_found}.
stop_listener(Ref) ->
    roadrunner:stop_listener(name(Ref)).

-doc false.
-spec port(cowmachine_server:listener_ref()) -> inet:port_number().
port(Ref) ->
    roadrunner_listener:port(name(Ref)).

-doc false.
-spec info(cowmachine_server:listener_ref()) ->
    {ok, cowmachine_server:listener_info()} | {error, not_found}.
info(Ref) ->
    Name = name(Ref),
    try
        #{active_clients := Active, max_clients := Max} = roadrunner_listener:info(Name),
        {ok, #{
            status => listener_status(roadrunner_listener:status(Name)),
            port => roadrunner_listener:port(Name),
            active_connections => Active,
            all_connections => Active,
            max_connections => Max
        }}
    catch
        exit:{noproc, _} -> {error, not_found}
    end.

%% A draining listener accepts no new connections, as a suspended Ranch
%% listener.
-spec listener_status(accepting | draining) -> running | suspended.
listener_status(accepting) -> running;
listener_status(draining) -> suspended.

%% The Roadrunner listener options a cowmachine listener option sets.
-spec listener_opt(atom(), term(), roadrunner_listener:opts()) -> roadrunner_listener:opts().
listener_opt(ip, Ip, Acc) -> Acc#{ip => Ip};
listener_opt(ipv6_v6only, V6Only, Acc) -> Acc#{ipv6_v6only => V6Only};
%% Over TLS, HTTP/2 is offered next to HTTP/1.1, as Cowboy does.
listener_opt(tls, TlsOpts, Acc) -> Acc#{tls => TlsOpts, protocols => [http1, http2]};
listener_opt(backlog, Backlog, Acc) -> Acc#{socket_backlog => Backlog};
listener_opt(max_connections, infinity, Acc) -> Acc;
listener_opt(max_connections, Max, Acc) -> Acc#{max_clients => Max};
listener_opt(num_acceptors, N, Acc) -> Acc#{num_acceptors => N};
listener_opt(request_timeout, infinity, Acc) -> Acc;
listener_opt(request_timeout, Timeout, Acc) -> Acc#{request_timeout => Timeout};
listener_opt(_Key, _Value, Acc) -> Acc.

-spec metrics_opts(cowmachine_server:listener_opts()) -> undefined | map().
metrics_opts(#{metrics_callback := Callback} = Opts) ->
    #{
        callback => Callback,
        req_filter => maps:get(metrics_req_filter, Opts, fun(Req) -> Req end),
        resp_headers_filter => maps:get(metrics_resp_headers_filter, Opts, fun(H) -> H end)
    };
metrics_opts(_Opts) ->
    undefined.

%% Roadrunner names listeners with atoms; a Ranch ref can be any term.
-spec name(cowmachine_server:listener_ref()) -> atom().
name(Ref) when is_atom(Ref) ->
    Ref;
name(Ref) ->
    binary_to_atom(iolist_to_binary(io_lib:format("~0p", [Ref]))).

%% =============================================================================
%% Requests
%% =============================================================================

-doc false.
-spec reply(cowboy:http_status(), cowboy:http_headers(), cowboy_req:resp_body(), Req) -> Req when
    Req :: cowboy_req:req().
reply(Status0, Headers0, {sendfile, Offset, Length, Path}, Req) ->
    Status = status(Status0),
    Headers = with_content_length(Length, response_headers(Headers0, Req)),
    ok = responded(Status, Headers),
    _ = roadrunner_send:file(Status, Headers, {Path, Offset, Length}, rr(Req)),
    ok = sent(Length, fin),
    replied(Req);
reply(Status0, Headers0, Body, Req) ->
    Status = status(Status0),
    Headers = response_headers(Headers0, Req),
    ok = responded(Status, Headers),
    _ = roadrunner_send:reply(Status, Headers, Body, rr(Req)),
    ok = sent(iolist_size(Body), fin),
    replied(Req).

-doc false.
-spec inform(cowboy:http_status(), cowboy:http_headers(), cowboy_req:req()) -> ok.
inform(Status, Headers, Req) ->
    _ = roadrunner_send:inform(status(Status), header_list(Headers), rr(Req)),
    ok.

-doc false.
-spec stream_reply(cowboy:http_status(), cowboy:http_headers(), Req) -> Req when
    Req :: cowboy_req:req().
stream_reply(Status0, Headers0, Req) ->
    Status = status(Status0),
    Headers = response_headers(Headers0, Req),
    ok = responded(Status, Headers),
    {ok, Send} = roadrunner_send:stream(Status, Headers, rr(Req)),
    (replied(Req))#{roadrunner_stream => Send}.

-doc false.
-spec stream_body(iodata(), fin | nofin, cowboy_req:req()) -> ok.
stream_body(Data, IsFin, #{roadrunner_stream := Send}) ->
    _ = Send(Data, IsFin),
    sent(iolist_size(Data), IsFin).

-doc false.
-spec stream_trailers(cowboy:http_headers(), cowboy_req:req()) -> ok.
stream_trailers(Trailers, #{roadrunner_stream := Send}) ->
    _ = Send(<<>>, {fin, header_list(Trailers)}),
    sent(0, fin).

-doc false.
-spec read_body(Req, cowboy_req:read_body_opts()) ->
    {ok, binary(), Req} | {more, binary(), Req}
when
    Req :: cowboy_req:req().
read_body(Req, Opts) ->
    Length = maps:get(length, Opts, ?READ_BODY_LENGTH),
    case roadrunner_req:read_body(rr(Req), #{length => Length}) of
        {ok, Data, RR} -> {ok, received(Data, fin), Req#{roadrunner_req := RR}};
        {more, Data, RR} -> {more, received(Data, nofin), Req#{roadrunner_req := RR}};
        {error, Reason} -> exit(request_error(Reason))
    end.

-doc false.
-spec read_part(Req, cowboy_req:read_body_opts()) ->
    {ok, cowboy:http_headers(), Req} | {done, Req}
when
    Req :: cowboy_req:req().
read_part(Req, Opts) ->
    Length = maps:get(length, Opts, ?READ_PART_LENGTH),
    case roadrunner_multipart:read_part(rr(Req), #{length => Length}) of
        {ok, Headers, RR} -> {ok, maps:from_list(Headers), Req#{roadrunner_req := RR}};
        {done, RR} -> {done, Req#{roadrunner_req := RR}};
        {error, Reason} -> exit(multipart_error(Reason))
    end.

-doc false.
-spec read_part_body(Req, cowboy_req:read_body_opts()) ->
    {ok, binary(), Req} | {more, binary(), Req}
when
    Req :: cowboy_req:req().
read_part_body(Req, Opts) ->
    Length = maps:get(length, Opts, ?READ_BODY_LENGTH),
    case roadrunner_multipart:read_part_body(rr(Req), #{length => Length}) of
        {ok, Data, RR} -> {ok, received(Data, fin), Req#{roadrunner_req := RR}};
        {more, Data, RR} -> {more, received(Data, nofin), Req#{roadrunner_req := RR}};
        {error, Reason} -> exit(multipart_error(Reason))
    end.

-doc false.
-spec set_options(cowmachine_cowreq:request_opts(), cowboy_req:req()) -> ok.
set_options(#{metrics_user_data := UserData}, _Req) ->
    update_metrics(fun(#{user_data := Old} = M) -> M#{user_data := maps:merge(Old, UserData)} end);
set_options(_Opts, _Req) ->
    %% Roadrunner has no idle timeout while a response streams.
    ok.

-doc false.
-spec websocket_upgrade(Req, Env, module(), term(), cowboy_websocket:opts()) -> {ok, Req, Env} when
    Req :: cowboy_req:req(), Env :: cowboy_middleware:env().
websocket_upgrade(Req, Env, Handler, State, Opts) ->
    Session = #{handler => Handler, state => State, req => Req},
    ok = responded(101, []),
    _ = roadrunner_send:websocket(roadrunner_cowmachine_ws, Session, ws_opts(Opts, Req), rr(Req)),
    {ok, replied(Req), Env}.

%% Cowboy's WebSocket options that have a Roadrunner counterpart, and the
%% response headers set on the request (a subprotocol, cookies).
-doc false.
-spec ws_opts(cowboy_websocket:opts(), cowboy_req:req()) -> roadrunner_ws_handler:upgrade_opts().
ws_opts(Opts, Req) ->
    maps:fold(
        fun
            (idle_timeout, Timeout, Acc) -> Acc#{idle_timeout => Timeout};
            (max_frame_size, infinity, Acc) -> Acc;
            (max_frame_size, Size, Acc) -> Acc#{max_frame_size => Size, max_message_size => Size};
            (compress, Compress, Acc) -> Acc#{compress => Compress};
            (_Key, _Value, Acc) -> Acc
        end,
        #{headers => response_headers(#{}, Req)},
        Opts
    ).

%% =============================================================================
%% Metrics
%% =============================================================================

%% Each request's metrics live in the process dictionary of the process
%% serving it, which the request callbacks run in: `set_options/2` returns
%% no request to carry them in. `roadrunner_cowmachine_handler` starts and
%% reports them; without a `metrics_callback` there are none to update.

-spec update_metrics(fun((map()) -> map())) -> ok.
update_metrics(Fun) ->
    case get(?METRICS) of
        undefined ->
            ok;
        Metrics ->
            _ = put(?METRICS, Fun(Metrics)),
            ok
    end.

-spec responded(non_neg_integer(), roadrunner_http:headers()) -> ok.
responded(Status, Headers) ->
    update_metrics(fun(M) ->
        M#{resp_status := Status, resp_headers := Headers, resp_start := erlang:monotonic_time()}
    end).

-spec sent(non_neg_integer(), fin | nofin) -> ok.
sent(Size, IsFin) ->
    update_metrics(fun(#{resp_body_length := Length} = M) ->
        ended(resp_end, IsFin, M#{resp_body_length := Length + Size})
    end).

-spec received(iodata(), fin | nofin) -> binary().
received(Data0, IsFin) ->
    Data = iolist_to_binary(Data0),
    ok = update_metrics(fun(#{req_body_length := Length} = M0) ->
        M = started(req_body_start, M0),
        ended(req_body_end, IsFin, M#{req_body_length := Length + byte_size(Data)})
    end),
    Data.

-spec started(atom(), map()) -> map().
started(Key, M) ->
    case M of
        #{Key := undefined} -> M#{Key := erlang:monotonic_time()};
        #{} -> M
    end.

-spec ended(atom(), fin | nofin, map()) -> map().
ended(Key, fin, M) -> M#{Key := erlang:monotonic_time()};
ended(_Key, nofin, M) -> M.

%% =============================================================================
%% Helpers
%% =============================================================================

-spec rr(cowboy_req:req()) -> roadrunner_req:request().
rr(#{roadrunner_req := RR}) -> RR.

%% A request after its response went out, as `cowboy_req` leaves it.
-spec replied(Req) -> Req when Req :: cowboy_req:req().
replied(Req) ->
    (maps:without([resp_headers, resp_cookies, resp_body], Req))#{has_sent_resp => true}.

%% The headers a response carries: those set on the request, the call's
%% (which win), and a `set-cookie` for each cookie set on the request.
-spec response_headers(cowboy:http_headers(), cowboy_req:req()) -> roadrunner_http:headers().
response_headers(Headers, Req) ->
    maps:fold(
        fun(Name, Value, Acc) -> [{Name, iolist_to_binary(Value)} | Acc] end,
        cookie_headers(Req),
        maps:merge(maps:get(resp_headers, Req, #{}), Headers)
    ).

-spec cookie_headers(cowboy_req:req()) -> roadrunner_http:headers().
cookie_headers(#{resp_cookies := Cookies}) ->
    [{~"set-cookie", iolist_to_binary(Value)} || _Name := Value <- Cookies];
cookie_headers(_Req) ->
    [].

-spec header_list(cowboy:http_headers()) -> roadrunner_http:headers().
header_list(Headers) ->
    [{Name, iolist_to_binary(Value)} || Name := Value <- Headers].

-spec with_content_length(non_neg_integer(), roadrunner_http:headers()) ->
    roadrunner_http:headers().
with_content_length(Length, Headers) ->
    case lists:keymember(~"content-length", 1, Headers) of
        true -> Headers;
        false -> [{~"content-length", integer_to_binary(Length)} | Headers]
    end.

%% Cowboy takes a status as an integer or a binary such as `<<"200 OK">>`.
-spec status(cowboy:http_status()) -> roadrunner_http:status().
status(Status) when is_integer(Status) -> Status;
status(<<Code:3/binary, _/binary>>) -> binary_to_integer(Code).

%% A body read that failed, as the exit Cowboy raises for it.
-spec request_error(term()) -> {request_error, term(), atom()}.
request_error(Reason) when
    Reason =:= request_timeout; Reason =:= slow_client; Reason =:= timeout
->
    {request_error, timeout, 'The request body was not received within the configured time.'};
request_error(content_length_too_large) ->
    {request_error, payload_too_large, 'The request body is larger than allowed by configuration.'};
request_error(Reason) ->
    {request_error, Reason, 'The request body could not be read.'}.

%% A multipart body that is not well formed, as Cowboy's `{multipart, _}`
%% request error, or a failed read of it.
-spec multipart_error(term()) -> {request_error, term(), atom()}.
multipart_error(Reason) when
    Reason =:= not_multipart;
    Reason =:= no_boundary;
    Reason =:= no_initial_boundary;
    Reason =:= no_header_terminator;
    Reason =:= no_part_terminator;
    Reason =:= headers_too_large;
    Reason =:= bad_header;
    Reason =:= malformed
->
    {request_error, {multipart, Reason}, 'Malformed body; multipart expected.'};
multipart_error(Reason) ->
    request_error(Reason).
