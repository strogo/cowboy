%% Copyright (c) 2011, Loïc Hoguin <essen@dev-extend.eu>
%%
%% Permission to use, copy, modify, and/or distribute this software for any
%% purpose with or without fee is hereby granted, provided that the above
%% copyright notice and this permission notice appear in all copies.
%%
%% THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
%% WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
%% MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
%% ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
%% WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
%% ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
%% OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

-module(cowboy_http_websocket).
-export([upgrade/3]).

-include("include/http.hrl").

-record(state, {
	handler :: module(),
	opts :: term(),
	origin = undefined :: undefined | binary(),
	challenge = undefined :: undefined | binary(),
	timeout = infinity :: timeout(),
	messages = undefined :: undefined | {atom(), atom(), atom()}
}).

-spec upgrade(Handler::module(), Opts::term(), Req::#http_req{}) -> ok.
upgrade(Handler, Opts, Req) ->
	case catch websocket_upgrade(#state{handler=Handler, opts=Opts}, Req) of
		{ok, State, Req2} -> handler_init(State, Req2);
		{'EXIT', _Reason} -> upgrade_error(Req)
	end.

-spec websocket_upgrade(State::#state{}, Req::#http_req{})
	-> {ok, State::#state{}, Req::#http_req{}}.
websocket_upgrade(State, Req) ->
	{<<"Upgrade">>, Req2} = cowboy_http_req:header('Connection', Req),
	{<<"WebSocket">>, Req3} = cowboy_http_req:header('Upgrade', Req2),
	{Origin, Req4} = cowboy_http_req:header(<<"Origin">>, Req3),
	{Key1, Req5} = cowboy_http_req:header(<<"Sec-Websocket-Key1">>, Req4),
	{Key2, Req6} = cowboy_http_req:header(<<"Sec-Websocket-Key2">>, Req5),
	false = lists:member(undefined, [Origin, Key1, Key2]),
	{ok, Key3, Req7} = cowboy_http_req:body(8, Req6),
	Challenge = challenge(Key1, Key2, Key3),
	{ok, State#state{origin=Origin, challenge=Challenge}, Req7}.

-spec challenge(Key1::binary(), Key2::binary(), Key3::binary()) -> binary().
challenge(Key1, Key2, Key3) ->
	IntKey1 = key_to_integer(Key1),
	IntKey2 = key_to_integer(Key2),
	erlang:md5(<< IntKey1:32, IntKey2:32, Key3/binary >>).

-spec key_to_integer(Key::binary()) -> integer().
key_to_integer(Key) ->
	Number = list_to_integer([C || << C >> <= Key, C >= $0, C =< $9]),
	Spaces = length([C || << C >> <= Key, C =:= 32]),
	Number div Spaces.

-spec handler_init(State::#state{}, Req::#http_req{}) -> ok.
handler_init(State=#state{handler=Handler, opts=Opts},
		Req=#http_req{transport=Transport}) ->
	case catch Handler:websocket_init(Transport:name(), Req, Opts) of
		{ok, Req2, HandlerState} ->
			websocket_handshake(State, Req2, HandlerState);
		{ok, Req2, HandlerState, Timeout} ->
			websocket_handshake(State#state{timeout=Timeout},
				Req2, HandlerState);
		{'EXIT', _Reason} ->
			upgrade_error(Req)
	end.

-spec upgrade_error(Req::#http_req{}) -> ok.
upgrade_error(Req=#http_req{socket=Socket, transport=Transport}) ->
	{ok, _Req} = cowboy_http_req:reply(400, [], [],
		Req#http_req{resp_state=waiting}),
	Transport:close(Socket).

-spec websocket_handshake(State::#state{}, Req::#http_req{},
	HandlerState::term()) -> ok.
websocket_handshake(State=#state{origin=Origin, challenge=Challenge},
		Req=#http_req{transport=Transport, raw_host=Host, port=Port,
		raw_path=Path}, HandlerState) ->
	Location = websocket_location(Transport:name(), Host, Port, Path),
	{ok, Req2} = cowboy_http_req:reply(
		<<"101 WebSocket Protocol Handshake">>,
		[{<<"Connection">>, <<"Upgrade">>},
		 {<<"Upgrade">>, <<"WebSocket">>},
		 {<<"Sec-WebSocket-Location">>, Location},
		 {<<"Sec-WebSocket-Origin">>, Origin}],
		Challenge, Req#http_req{resp_state=waiting}),
	handler_loop(State#state{messages=Transport:messages()},
		Req2, HandlerState, <<>>).

-spec websocket_location(TransportName::atom(), Host::binary(),
	Port::ip_port(), Path::binary()) -> binary().
websocket_location(ssl, Host, Port, Path) ->
	<< "wss://", Host/binary, ":",
		(list_to_binary(integer_to_list(Port)))/binary, Path/binary >>;
websocket_location(_Any, Host, Port, Path) ->
	<< "ws://", Host/binary, ":",
		(list_to_binary(integer_to_list(Port)))/binary, Path/binary >>.

-spec handler_loop(State::#state{}, Req::#http_req{},
	HandlerState::term(), SoFar::binary()) -> ok.
handler_loop(State=#state{messages={OK, Closed, Error}, timeout=Timeout},
		Req=#http_req{socket=Socket, transport=Transport},
		HandlerState, SoFar) ->
	Transport:setopts(Socket, [{active, once}]),
	receive
		{OK, Socket, Data} ->
			websocket_data(State, Req, HandlerState,
				<< SoFar/binary, Data/binary >>);
		{Closed, Socket} ->
			handler_terminate(State, Req, HandlerState, {error, closed});
		{Error, Socket, Reason} ->
			handler_terminate(State, Req, HandlerState, {error, Reason});
		Message ->
			handler_call(State, Req, HandlerState,
				SoFar, Message, fun handler_loop/4)
	after Timeout ->
		websocket_close(State, Req, HandlerState, {normal, timeout})
	end.

-spec websocket_data(State::#state{}, Req::#http_req{},
	HandlerState::term(), Data::binary()) -> ok.
websocket_data(State, Req, HandlerState, << 255, 0, _Rest/bits >>) ->
	websocket_close(State, Req, HandlerState, {normal, closed});
websocket_data(State, Req, HandlerState, Data) when byte_size(Data) < 3 ->
	handler_loop(State, Req, HandlerState, Data);
websocket_data(State, Req, HandlerState, Data) ->
	websocket_frame(State, Req, HandlerState, Data, binary:first(Data)).

%% We do not support any frame type other than 0 yet. Just like the specs.
-spec websocket_frame(State::#state{}, Req::#http_req{},
	HandlerState::term(), Data::binary(), FrameType::byte()) -> ok.
websocket_frame(State, Req, HandlerState, Data, 0) ->
	case binary:match(Data, << 255 >>) of
		{Pos, 1} ->
			Pos2 = Pos - 1,
			<< 0, Frame:Pos2/binary, 255, Rest/bits >> = Data,
			handler_call(State, Req, HandlerState,
				Rest, {websocket, Frame}, fun websocket_data/4);
		nomatch ->
			%% @todo We probably should allow limiting frame length.
			handler_loop(State, Req, HandlerState, Data)
	end;
websocket_frame(State, Req, HandlerState, _Data, _FrameType) ->
	websocket_close(State, Req, HandlerState, {error, badframe}).

-spec handler_call(State::#state{}, Req::#http_req{}, HandlerState::term(),
	RemainingData::binary(), Message::term(), NextState::fun()) -> ok.
handler_call(State=#state{handler=Handler}, Req, HandlerState,
		RemainingData, Message, NextState) ->
	case catch Handler:websocket_handle(Message, Req, HandlerState) of
		{ok, Req2, HandlerState2} ->
			NextState(State, Req2, HandlerState2, RemainingData);
		{reply, Data, Req2, HandlerState2} ->
			websocket_send(Data, Req2),
			NextState(State, Req2, HandlerState2, RemainingData);
		{shutdown, Req2, HandlerState2} ->
			websocket_close(State, Req2, HandlerState2, {normal, shutdown});
		{'EXIT', _Reason} ->
			websocket_close(State, Req, HandlerState, {error, handler})
	end.

-spec websocket_send(Data::binary(), Req::#http_req{}) -> ok.
websocket_send(Data, #http_req{socket=Socket, transport=Transport}) ->
	Transport:send(Socket, << 0, Data/binary, 255 >>).

-spec websocket_close(State::#state{}, Req::#http_req{},
	HandlerState::term(), Reason::{atom(), atom()}) -> ok.
websocket_close(State, Req=#http_req{socket=Socket, transport=Transport},
		HandlerState, Reason) ->
	Transport:send(Socket, << 255, 0 >>),
	Transport:close(Socket),
	handler_terminate(State, Req, HandlerState, Reason).

-spec handler_terminate(State::#state{}, Req::#http_req{},
	HandlerState::term(), Reason::atom() | {atom(), atom()}) -> ok.
handler_terminate(#state{handler=Handler}, Req, HandlerState, Reason) ->
	Handler:websocket_terminate(Reason, Req, HandlerState).
