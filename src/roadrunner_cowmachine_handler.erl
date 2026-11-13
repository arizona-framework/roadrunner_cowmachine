-module(roadrunner_cowmachine_handler).
-moduledoc false.

%% The Roadrunner handler of a cowmachine listener. It answers each request
%% with a `{send, ...}` response whose fun runs the listener's middlewares
%% on a request map shaped like Cowboy's, which cowmachine reads and
%% answers with `cowmachine_cowreq`, through `roadrunner_cowmachine`. With a
%% `metrics_callback`, it starts the request's metrics before the
%% middlewares and reports them after.

-behaviour(roadrunner_handler).

-export([handle/1]).
-export([run/1, request/1]).

-define(METRICS, roadrunner_cowmachine_metrics).

-spec handle(roadrunner_req:request()) -> roadrunner_handler:result().
handle(Req) ->
    {{send, [], fun ?MODULE:run/1}, Req}.

-spec run(roadrunner_req:request()) -> roadrunner_req:request().
run(RR0) ->
    #{middlewares := Middlewares, env := Env, metrics := Metrics} = roadrunner_req:state(RR0),
    Req0 = request(RR0),
    ok = start_metrics(Metrics, Req0),
    #{roadrunner_req := RR} =
        try cowmachine_server:execute(Req0, Env, Middlewares) of
            {ok, Req, _Env} -> Req;
            {stop, Req} -> Req
        catch
            Class:Reason:Stacktrace ->
                ok = report_metrics(
                    Metrics, {internal_error, {Class, Reason}, 'Stream process crashed.'}
                ),
                erlang:raise(Class, Reason, Stacktrace)
        end,
    case roadrunner_send:status(RR) of
        none ->
            ok = roadrunner_send:reply(204, [], <<>>, RR),
            ok = no_content(Metrics);
        _Sent ->
            ok
    end,
    ok = report_metrics(Metrics, normal),
    RR.

-spec request(roadrunner_req:request()) -> cowboy_req:req().
request(RR) ->
    Headers = headers(roadrunner_req:headers(RR)),
    Scheme = roadrunner_req:scheme(RR),
    HasBody = roadrunner_req:has_body(RR),
    #{
        cowmachine_server => roadrunner_cowmachine,
        roadrunner_req => RR,
        ref => roadrunner_req:listener_name(RR),
        pid => self(),
        streamid => roadrunner_req:request_id(RR),
        method => roadrunner_req:method(RR),
        version => version(roadrunner_req:version(RR)),
        scheme => atom_to_binary(Scheme),
        host => host(roadrunner_req:host(RR)),
        port => roadrunner_req:port(RR),
        path => roadrunner_req:path(RR),
        qs => roadrunner_req:qs(RR),
        headers => Headers,
        peer => address(roadrunner_req:peer(RR)),
        sock => sock(RR),
        cert => cert(Scheme, RR),
        has_body => HasBody,
        body_length => body_length(Headers, HasBody)
    }.

%% =============================================================================
%% Metrics
%% =============================================================================

-spec start_metrics(undefined | map(), cowboy_req:req()) -> ok.
start_metrics(undefined, _Req) ->
    ok;
start_metrics(_Metrics, #{ref := Ref, pid := Pid, streamid := StreamId} = Req) ->
    _ = put(?METRICS, #{
        ref => Ref,
        pid => Pid,
        streamid => StreamId,
        req => Req,
        resp_status => undefined,
        resp_headers => undefined,
        req_start => erlang:monotonic_time(),
        req_body_start => undefined,
        req_body_end => undefined,
        req_body_length => 0,
        resp_start => undefined,
        resp_end => undefined,
        resp_body_length => 0,
        user_data => #{}
    }),
    ok.

%% The `204` sent for a request the middlewares left unanswered.
-spec no_content(undefined | map()) -> ok.
no_content(undefined) ->
    ok;
no_content(_Metrics) ->
    Now = erlang:monotonic_time(),
    _ = put(?METRICS, (get(?METRICS))#{
        resp_status := 204, resp_headers := [], resp_start := Now, resp_end := Now
    }),
    ok.

%% Call the listener's `metrics_callback` with the request's metrics, the
%% request and response headers through its filters, as `cowboy_metrics_h`
%% does. The metrics leave the process dictionary, which serves the next
%% request on the connection.
-spec report_metrics(undefined | map(), term()) -> ok.
report_metrics(undefined, _Reason) ->
    ok;
report_metrics(
    #{callback := Callback, req_filter := ReqFilter, resp_headers_filter := RespHeadersFilter},
    Reason
) ->
    #{req := Req, resp_headers := RespHeaders} = Metrics = erase(?METRICS),
    _ = Callback(Metrics#{
        reason => Reason,
        req := ReqFilter(maps:remove(roadrunner_req, Req)),
        resp_headers := resp_headers(RespHeadersFilter, RespHeaders),
        req_end => erlang:monotonic_time()
    }),
    ok.

-spec resp_headers(fun((cowboy:http_headers()) -> cowboy:http_headers()), term()) ->
    undefined | cowboy:http_headers().
resp_headers(_Filter, undefined) ->
    undefined;
resp_headers(Filter, Headers) ->
    Filter(maps:from_list(Headers)).

%% =============================================================================
%% The request map
%% =============================================================================

-spec headers(roadrunner_http:headers()) -> cowboy:http_headers().
headers(Headers) ->
    lists:foldl(
        fun({Name, Value}, Acc) ->
            case Acc of
                #{Name := Prev} ->
                    Acc#{Name := <<Prev/binary, (separator(Name))/binary, Value/binary>>};
                #{} ->
                    Acc#{Name => Value}
            end
        end,
        #{},
        Headers
    ).

-spec separator(binary()) -> binary().
separator(~"cookie") -> ~"; ";
separator(_Name) -> ~", ".

-spec version(roadrunner_http:version()) -> cowboy:http_version().
version({1, 0}) -> 'HTTP/1.0';
version({1, 1}) -> 'HTTP/1.1';
version({2, 0}) -> 'HTTP/2';
version({3, 0}) -> 'HTTP/3'.

-spec host(binary() | undefined) -> binary().
host(undefined) -> <<>>;
host(Host) -> Host.

-spec sock(roadrunner_req:request()) -> {inet:ip_address(), inet:port_number()}.
sock(RR) ->
    case roadrunner_req:sockname(RR) of
        {ok, Sock} -> Sock;
        {error, _} -> address(undefined)
    end.

-spec address({inet:ip_address(), inet:port_number()} | undefined) ->
    {inet:ip_address(), inet:port_number()}.
address(undefined) -> {{0, 0, 0, 0}, 0};
address(Address) -> Address.

-spec cert(http | https, roadrunner_req:request()) -> binary() | undefined.
cert(https, RR) ->
    case roadrunner_req:peercert(RR) of
        {ok, Der} -> Der;
        {error, _} -> undefined
    end;
cert(http, _RR) ->
    undefined.

-spec body_length(cowboy:http_headers(), boolean()) -> non_neg_integer() | undefined.
body_length(#{~"content-length" := Length}, _HasBody) -> binary_to_integer(Length);
body_length(_Headers, false) -> 0;
body_length(_Headers, true) -> undefined.
