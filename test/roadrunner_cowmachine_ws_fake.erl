-module(roadrunner_cowmachine_ws_fake).
-moduledoc false.

%% A Cowboy WebSocket handler for `roadrunner_cowmachine_ws_tests`: its state is a
%% fun, and each callback returns what the fun gives for the call.

-export([websocket_init/1, websocket_handle/2, websocket_info/2, terminate/3]).

websocket_init(Fun) -> Fun(init).

websocket_handle(Frame, Fun) -> Fun({handle, Frame}).

websocket_info(Info, Fun) -> Fun({info, Info}).

terminate(Reason, Req, Fun) -> Fun({terminate, Reason, Req}).
