-module(roadrunner_cowmachine_ws_bare).
-moduledoc false.

%% A Cowboy WebSocket handler without the optional callbacks
%% (`websocket_init/1`, `terminate/3`), for `roadrunner_cowmachine_ws_tests`.

-export([websocket_handle/2, websocket_info/2]).

websocket_handle(_Frame, State) -> {ok, State}.

websocket_info(_Info, State) -> {ok, State}.
