% Copyright 2008, Engine Yard, Inc.
%
% This file is part of Natter.
%
% Natter is free software: you can redistribute it and/or modify it under the
% terms of the GNU Lesser General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option) any
% later version.
%
% Natter is distributed in the hope that it will be useful, but WITHOUT ANY
% WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
% A PARTICULAR PURPOSE.  See the GNU Lesser General Public License for more
% details.
%
% You should have received a copy of the GNU Lesser General Public License
% along with Natter.  If not, see <http://www.gnu.org/licenses/>.

-module(natter_connection).

-author("ksmith@engineyard.com").

-behaviour(supervisor).

-include("typespecs.hrl").

%% API
-export([start_link/1, start_link/3, close/1, register_default_exchange/2, unregister_default_exchange/1]).
-export([register_exchange/4, unregister_exchange/3, raw_send/2, send_iq/5, send_wait_iq/5, send_wait_iq/6]).
-export([register_error_handler/2, register_error_handler/3, unregister_error_handler/1, unregister_error_handler/2]).

%% Supervisor callbacks
-export([init/1]).

-spec(start_link/1 :: (Config :: config()) -> {ok, pid()} | {exit, string()}).
start_link(Config) ->
  start_link(Config, undefined, undefined).

-spec(start_link/3 :: (Config :: config(), InspectorMod :: atom(), InspectorPid :: pid()) -> {ok, pid()} | {exit, string()}).
start_link(Config, InspectorMod, InspectorPid) ->
  supervisor:start_link(?MODULE, [Config, InspectorMod, InspectorPid]).

-spec(close/1 :: (ConnectionPid :: pid()) -> ok).
close(ConnectionPid) ->
  exit(ConnectionPid, shutdown),
  ok.

-spec(register_default_exchange/2 :: (ConnectionPid :: pid(), SinkPid :: pid()) -> ok | natter_error()).
register_default_exchange(ConnectionPid, SinkPid) ->
  DispatcherPid = find_child(ConnectionPid, natter_dispatcher),
  natter_dispatcher:register_exchange(DispatcherPid, "all", default, SinkPid).

-spec(unregister_default_exchange/1 :: (ConnectionPid :: pid()) -> ok).
unregister_default_exchange(ConnectionPid) ->
  DispatcherPid = find_child(ConnectionPid, natter_dispatcher),
  natter_dispatcher:unregister_exchange(DispatcherPid, "all", default).

-spec(register_error_handler/2 :: (ConnectionPid :: pid(), ErrorHandlerPid :: pid()) -> ok | natter_error()).
register_error_handler(ConnectionPid, ErrorHandlerPid) ->
  register_error_handler(ConnectionPid, "all", ErrorHandlerPid).

-spec(register_error_handler/3 :: (ConnectionPid :: pid(), PacketType :: string(), ErrorHandlerPid :: pid()) -> ok | natter_error()).
register_error_handler(ConnectionPid, PacketType, ErrorHandlerPid) ->
  DispatcherPid = find_child(ConnectionPid, natter_dispatcher),
  natter_dispatcher:register_exchange(DispatcherPid, PacketType, "error", ErrorHandlerPid).

-spec(unregister_error_handler/1 :: (ConnectionPid :: pid()) -> ok).
unregister_error_handler(ConnectionPid) ->
  unregister_error_handler(ConnectionPid, "all").

-spec(unregister_error_handler/2 :: (ConnectionPid :: pid(), PacketType :: string()) -> ok).
unregister_error_handler(ConnectionPid, PacketType) ->
  DispatcherPid = find_child(ConnectionPid, natter_dispatcher),
  natter_dispatcher:unregister_exchange(DispatcherPid, PacketType, "error").

-spec(register_exchange/4 :: (ConnectionPid :: pid(), PacketType :: string(), TargetJid :: string(), SinkPid :: pid()) -> ok | natter_error()).
register_exchange(ConnectionPid, PacketType, TargetJid, SinkPid) when is_list(TargetJid) ->
  DispatcherPid = find_child(ConnectionPid, natter_dispatcher),
  natter_dispatcher:register_exchange(DispatcherPid, PacketType, TargetJid, SinkPid).

-spec(unregister_exchange/3 :: (ConnectionPid :: pid(), PacketType :: string(), TargetJid :: string()) -> 'ok').
unregister_exchange(ConnectionPid, PacketType, TargetJid) when is_list(TargetJid) ->
  DispatcherPid = find_child(ConnectionPid, natter_dispatcher),
  natter_dispatcher:unregister_exchange(DispatcherPid, PacketType, TargetJid).

-spec(raw_send/2 :: (ConnectionPid :: pid(), Packet :: string()) -> 'ok').
raw_send(ConnectionPid, Packet) ->
  Packetizer = find_child(ConnectionPid, natter_packetizer),
  natter_packetizer:send(Packetizer, Packet).

-spec(send_iq/5 :: (ConnectionPid :: pid(), Type :: string(), PacketId :: string(), To :: string(), Packet :: string()) -> 'ok').
send_iq(ConnectionPid, Type, PacketId, To, Packet) ->
  Packetizer = find_child(ConnectionPid, natter_packetizer),
  Iq = natter_util:build_iq_stanza(Type, PacketId, To, Packet),
  natter_packetizer:send(Packetizer, Iq).

-spec(send_wait_iq/5 :: (ConnectionPid :: pid(), Type :: string(), PacketId :: string(),
                         To :: string(), Packet :: string()) -> {'ok', parsed_xml()} | natter_error()).

send_wait_iq(ConnectionPid, Type, PacketId, To, Packet) when Type =:= "set";
                                                             Type =:= "get" ->
  send_wait_iq(ConnectionPid, Type, PacketId, To, Packet, 0).

-spec(send_wait_iq/6 :: (ConnectionPid :: pid(), Type :: string(), PacketId :: string(),
                         To :: string(), Packet :: string(), Timeout :: integer()) -> {'ok', parsed_xml()} | natter_error()).

send_wait_iq(ConnectionPid, Type, PacketId, To, Packet, Timeout) when Type =:= "set";
                                                                      Type =:= "get" ->
  Dispatcher = find_child(ConnectionPid, natter_dispatcher),
  Iq = natter_util:build_iq_stanza(Type, PacketId, To, Packet),
  natter_dispatcher:send_and_wait(Dispatcher, Iq, Timeout).

init([Config, InspectorMod, InspectorPid]) ->
  {ok, {{one_for_all, 5, 60}, build_child_specs(Config, InspectorMod, InspectorPid)}}.

%% Internal functions
-spec(find_child/2 :: (ConnectionPid :: pid(), 'natter_dispatcher' | 'natter_packetizer') -> pid() | atom()).
find_child(ConnectionPid, natter_dispatcher) ->
  lists:foldl(fun({Id, ChildPid, _, _}, Acc) ->
                  if
                    Id =:= natter_dispatcher ->
                      ChildPid;
                    true ->
                      Acc
                  end end, not_found, supervisor:which_children(ConnectionPid));
find_child(ConnectionPid, natter_packetizer) ->
  DispatcherPid = find_child(ConnectionPid, natter_dispatcher),
  natter_dispatcher:get_packetizer(DispatcherPid).

build_child_specs(Config, InspectorMod, InspectorPid) ->
  CS1 = [{natter_dispatcher,
          {natter_dispatcher, start_link, [Config, InspectorMod, InspectorPid]},
          transient,
          5,
          worker,
    [natter_dispatcher]}],
  case proplists:get_value(log_file, Config) of
    undefined ->
      CS1;
    LogFile ->
      case erlang:whereis(natter_logger) of
        undefined ->
          lists:reverse([{natter_logger,
                          {natter_logger, start_link, [LogFile]},
                          transient,
                          5,
                          worker,
                          [natter_logger]}|CS1]);
        _ ->
          CS1
      end
  end.
