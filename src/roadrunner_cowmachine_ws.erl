-module(roadrunner_cowmachine_ws).
-moduledoc false.

%% Runs a Cowboy WebSocket handler (a cowmachine controller's, such as
%% Zotonic's MQTT transport) as a Roadrunner WebSocket handler. Frames
%% reach the handler as Cowboy's
%% `websocket_handle/2` gets them (`{text, Data}`, `{ping, Data}`), and the
%% commands it returns become Roadrunner's results. The state is
%% `#{handler, state, req}`: the Cowboy handler, its state, and the request
%% its `terminate/3` gets.

-behaviour(roadrunner_ws_handler).

-export([init/1, handle_frame/2, handle_control/2, handle_info/2, handle_drain/2, terminate/2]).

-type session() :: #{handler := module(), state := term(), req := cowboy_req:req()}.

-spec init(session()) -> roadrunner_ws_handler:result().
init(#{handler := Handler, state := State} = Session) ->
    %% `function_exported/3` is false for a module not loaded yet.
    {module, Handler} = code:ensure_loaded(Handler),
    case erlang:function_exported(Handler, websocket_init, 1) of
        true -> result(Handler:websocket_init(State), Session);
        false -> {ok, Session}
    end.

-spec handle_frame(roadrunner_ws:frame(), session()) -> roadrunner_ws_handler:result().
handle_frame(#{opcode := Opcode, payload := Payload}, Session) ->
    handle({Opcode, iolist_to_binary(Payload)}, Session).

%% Roadrunner already answered a ping; Cowboy hands the handler both.
-spec handle_control(roadrunner_ws:frame(), session()) -> roadrunner_ws_handler:result().
handle_control(#{opcode := Opcode, payload := Payload}, Session) ->
    handle({Opcode, iolist_to_binary(Payload)}, Session).

-spec handle_info(term(), session()) -> roadrunner_ws_handler:result().
handle_info(Info, #{handler := Handler, state := State} = Session) ->
    result(Handler:websocket_info(Info, State), Session).

%% The listener is draining: close as a server going away (RFC 6455 §7.4.1).
-spec handle_drain(integer(), session()) -> roadrunner_ws_handler:result().
handle_drain(_Deadline, Session) ->
    {close, 1001, <<>>, Session}.

-spec terminate(roadrunner_ws_handler:terminate_reason(), session()) -> ok.
terminate(Reason, #{handler := Handler, state := State, req := Req}) ->
    case erlang:function_exported(Handler, terminate, 3) of
        true ->
            _ = Handler:terminate(reason(Reason), Req, State),
            ok;
        false ->
            ok
    end.

-spec handle({text | binary | ping | pong, binary()}, session()) -> roadrunner_ws_handler:result().
handle(Frame, #{handler := Handler, state := State} = Session) ->
    result(Handler:websocket_handle(Frame, State), Session).

%% A Cowboy callback's result as Roadrunner's.
-spec result(term(), session()) -> roadrunner_ws_handler:result().
result({stop, State}, Session) ->
    {close, 1000, <<>>, Session#{state := State}};
result({ok, State}, Session) ->
    {ok, Session#{state := State}};
result({ok, State, hibernate}, Session) ->
    {ok, Session#{state := State}, [hibernate]};
result({reply, Frames, State}, Session) ->
    commands(frames(Frames), [], Session#{state := State});
result({reply, Frames, State, hibernate}, Session) ->
    commands(frames(Frames), [hibernate], Session#{state := State});
result({Commands, State}, Session) when is_list(Commands) ->
    commands(Commands, [], Session#{state := State});
result({Commands, State, hibernate}, Session) when is_list(Commands) ->
    commands(Commands, [hibernate], Session#{state := State}).

-spec frames(term()) -> [term()].
frames(Frames) when is_list(Frames) -> Frames;
frames(Frame) -> [Frame].

%% Cowboy's commands: frames to send, up to a close; the commands that tune
%% Cowboy's own connection (`active`, `deflate`, `set_options`,
%% `shutdown_reason`) have no Roadrunner counterpart and are skipped.
-spec commands([term()], [hibernate], session()) -> roadrunner_ws_handler:result().
commands(Commands, Opts, Session) ->
    case outbound(Commands) of
        {Frames, none} when Opts =:= [] -> {reply, Frames, Session};
        {Frames, none} -> {reply, Frames, Session, Opts};
        {[], {Code, Reason}} -> {close, Code, Reason, Session};
        {Frames, {Code, Reason}} -> {close, Code, Reason, Frames, Session}
    end.

-spec outbound([term()]) ->
    {[{roadrunner_ws:opcode(), iodata()}], none | {pos_integer(), iodata()}}.
outbound([]) ->
    {[], none};
outbound([close | _]) ->
    {[], {1000, <<>>}};
outbound([{close, <<Code:16, Reason/binary>>} | _]) ->
    {[], {Code, Reason}};
outbound([{close, _Payload} | _]) ->
    {[], {1000, <<>>}};
outbound([{close, Code, Reason} | _]) ->
    {[], {Code, Reason}};
outbound([Command | Rest]) ->
    {Frames, Close} = outbound(Rest),
    case frame(Command) of
        {ok, Frame} -> {[Frame | Frames], Close};
        skip -> {Frames, Close}
    end.

-spec frame(term()) -> {ok, {roadrunner_ws:opcode(), iodata()}} | skip.
frame({Opcode, Data}) when Opcode =:= text; Opcode =:= binary; Opcode =:= ping; Opcode =:= pong ->
    {ok, {Opcode, Data}};
frame(Opcode) when Opcode =:= ping; Opcode =:= pong ->
    {ok, {Opcode, <<>>}};
frame(_Command) ->
    skip.

%% Roadrunner's terminate reason as Cowboy reports it.
-spec reason(roadrunner_ws_handler:terminate_reason()) -> term().
reason(normal) -> stop;
reason(shutdown) -> stop;
reason(Reason) -> Reason.
