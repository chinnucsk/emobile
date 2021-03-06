%% Author: Administrator
%% Created: 2011-1-17
%% Description: TODO: Add description to mobile_network
-module(mobile_network).

%%
%% Include files
%%

-include("message_define.hrl").
-include("loglevel.hrl").

%%
%% Exported Functions
%%
-export([tcp_send/4, process_received_msg/2, deliver_message/3]).

%% -record(unique_ids, {type, id}).
-record(undelivered_msgs, {id = 0, mobile_id = 0, timestamp, msg_bin = <<>>, control_node}).

%%
%% API Functions
%%

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
tcp_send(CtlNode, Socket, TimeStamp, SendBin) ->
	case get(mobile_id) of 
		undefined -> {error, "Mobile not login"};
		MobileId -> 
			case gen_tcp:send(Socket, SendBin) of
				ok -> ok;
				{error, Reason} ->
					save_undelivered_message(MobileId, TimeStamp, SendBin, CtlNode),
					{error, Reason}
			end
	end.		
	
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Bin: received binary data
%% Fun: Fun(MsgSize(ushort), MsgType(ushort), MsgBody(binary))
process_received_msg(Socket, Bin) when is_binary(Bin) ->
	case Bin of
		<<MsgSize:2/?NET_ENDIAN-unit:8, MsgType:2/?NET_ENDIAN-unit:8, Extra/binary>> ->
			case MsgSize =< ?MAX_MSG_SIZE of
				true ->
					MsgBodySize = MsgSize - 4,
					case Extra of
						<<MsgBody:MsgBodySize/binary, Rest/binary>> ->
							on_receive_msg(MsgSize, MsgType, MsgBody), %% call funcion that handles client messages
							process_received_msg(Socket, Rest);
						<<_/binary>> ->
							{ok, Bin}
					end;
				false ->
					self() ! {kick_out, "receive invalid message length"},
					{error, <<>>}
			end;
		
		<<_SomeBin/binary>> ->
			{ok, Bin}
	end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
deliver_message(TargetList, TimeStamp, MsgBin) ->
	F = fun(MobileId) ->
				case ets:lookup(ets_mobile_id2pid, MobileId) of
					[{MobileId, Pid, CtlNode}] -> 
						case service_mobile_conn:send_message(CtlNode, Pid, TimeStamp, MsgBin) of
							ok -> ok;
							{error, _} -> save_undelivered_message(MobileId, TimeStamp, MsgBin, CtlNode)
						end;
					[] ->
						case ctlnode_selector:get_ctl_node(MobileId) of
							undefined ->
								send_by_backup(undefined, MobileId, TimeStamp, MsgBin);
							CtlNode ->
								case rpc:call(CtlNode, service_lookup_mobile_node, lookup_conn_node, [MobileId]) of
									undefined ->
										save_undelivered_message(MobileId, TimeStamp, MsgBin, CtlNode);
									{badrpc, Reason} ->
										?ERROR_MSG("RPC control node failed:~p for mobile: ~p, trying route by backup node.~n", [Reason, MobileId]),
										send_by_backup(CtlNode, MobileId, TimeStamp, MsgBin);
									{ConnNode, Pid} ->
										rpc_send_message(ConnNode, CtlNode, MobileId, Pid, TimeStamp, MsgBin)
								end
						end
				end
		end,
	lists:foreach(F, TargetList),
	ok.



%%
%% Local Functions
%%

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
on_receive_msg(MsgSize, MsgType, MsgBody) ->
	case MsgType of
		?MSG_LOGIN -> on_msg_login(MsgBody);
		?MSG_PING  -> on_msg_ping(MsgSize);
		?MSG_DELIVER -> on_msg_deliver(MsgSize, MsgBody);
		_ -> self() ! {kick_out, "Receive unkown message."}
	end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% mobile client login
on_msg_login(MsgBody) ->
	case get(login_timer_ref) of
		undefined -> exit(login_timer_undefined); %% never touch this line if all-ok
		TimerRef -> erlang:cancel_timer(TimerRef)
	end,
	
	<<MobileId: 4/?NET_ENDIAN-unit:8, _/binary>> = MsgBody,
	
	case ctlnode_selector:get_ctl_node(MobileId) of
		undefined -> 
			?ERROR_MSG("configure control node for mobile[~p] not found, trying login to backup "
			           "control node. ~n", [MobileId]),
			login_backup_control_node(MobileId);
		CtlNode when is_atom(CtlNode) ->
			case rpc:call(CtlNode, service_lookup_mobile_node, on_mobile_login, [MobileId, erlang:node(), self()], infinity) of
				ok -> 
					on_login_ctlnode_success(CtlNode, MobileId);
				{badrpc, Reason} -> 
					?ERROR_MSG("Login mobile[~p] to control node[~p] failed: ~p, trying login to ""
                               backup control node! ~n", [MobileId, CtlNode, Reason]),
					gen_server:cast(service_mobile_conn, {control_node_failed, CtlNode}),
                    login_backup_control_node(MobileId);
				{error, Reason} ->
					?ERROR_MSG("Login mobile[~p] to control node[~p] failed: ~p, close connection", [MobileId, CtlNode, Reason]),		
					exit(login_error)
			end			
	end.	

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
login_backup_control_node(MobileId) ->
	BackCtlNode = ctlnode_selector:get_ctl_back_node(MobileId),
	case rpc:call(BackCtlNode, service_lookup_mobile_node, on_mobile_login, [MobileId, erlang:node(), self()]) of
		ok -> 
			on_login_ctlnode_success(undefined, MobileId);
		{badrpc, Reason} -> 
			?CRITICAL_MSG("Login mobile[~p] to backup control node[~p] failed:~p, no way to rescue, "
			              "kickout it! ~n", [MobileId, BackCtlNode, Reason]),
			self() ! {kick_out, "No control node available."},
			ok
	end.	

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
on_login_ctlnode_success(CtlNode, MobileId) ->
	?INFO_MSG("Mobile[~p] logined. ~n", [MobileId]),			
	put(mobile_id, MobileId),
	SendBin = <<12: 2/?NET_ENDIAN-unit:8,
                ?MSG_RESULT: 2/?NET_ENDIAN-unit:8,
                ?MSG_LOGIN:  2/?NET_ENDIAN-unit:8,
                0: 2/?NET_ENDIAN-unit:8,
                MobileId: 4/?NET_ENDIAN-unit:8>>,
   
	gen_server:cast(service_mobile_conn, {on_mobile_login, MobileId, self(), CtlNode}),
    %% send back login success message to client    
    self() ! {tcp_send_ping, SendBin},
    ok.	
	

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% keep connection heart-beat 
on_msg_ping(MsgSize) ->
	case MsgSize of
		8 -> 
			MobileId = case get(mobile_id) of
						   undefined -> 0;
						   Val -> Val
					   end,
%% 			?INFO_MSG("receive ping message from mobile:~p. ~n", [MobileId]),
			MsgPing = <<8: 2/?NET_ENDIAN-unit:8, ?MSG_PING: 2/?NET_ENDIAN-unit:8, MobileId:4/?NET_ENDIAN-unit:8>>,
			self() ! {tcp_send_ping, MsgPing},
			ok;
		_ ->
			self() ! {kick_out, "invalid msg PING"},
			{error, invalide_msg_ping}
	end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% client request deliver message to other client(s)
on_msg_deliver(MsgSize, MsgBody) -> 
	case get(mobile_id) of
		undefined ->
			self() ! {kick_out, "Deliver message without login."},
			ok;
		MobileId ->
			<<_SrcMobileId:4/?NET_ENDIAN-unit:8, _TimeStamp:8/?NET_ENDIAN-unit:8, TargetNum: 4/?NET_ENDIAN-unit:8>> = binary:part(MsgBody, 0, 16),
			case TargetNum of
				0 -> ok;
				_ ->
					TargetListBin = binary:part(MsgBody, 16, TargetNum * 4),
					TargetList = emobile_message:decode_target_list(TargetListBin, TargetNum, []),
					
					TimeStampBin = emobile_message:make_timestamp_binary(),
					TimeStamp = emobile_message:decode_timestamp(TimeStampBin),

					MsgContentBin = binary:part(MsgBody, 16 + TargetNum * 4, byte_size(MsgBody) - (16 + TargetNum * 4)),

					?INFO_MSG("receive message deliver ~p -> ~p: ~p ~n", [MobileId, TargetList, MsgContentBin]),
					
					deliver_message(TargetList, 
                                    TimeStamp,
                                    <<MsgSize:2/?NET_ENDIAN-unit:8,
									  ?MSG_DELIVER:2/?NET_ENDIAN-unit:8,
									  MobileId:4/?NET_ENDIAN-unit:8,
									  TimeStampBin/binary, 												  
									  TargetNum: 4/?NET_ENDIAN-unit:8,
									  TargetListBin/binary,
									  MsgContentBin/binary>>),
					ok
			end
	end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
send_by_backup(CtlNode, MobileId, TimeStamp, MsgBin) ->
	BackCtlNode = ctlnode_selector:get_ctl_back_node(MobileId), %% this call should never failed(result =/= undefined)
	case rpc:call(BackCtlNode, service_lookup_mobile_node, lookup_conn_node_backup, [MobileId]) of
		undefined -> 
			?ERROR_MSG("Lookup conn node failed and no control node config for mobile: ~p, message will be lost.~n", [MobileId]),
			save_undelivered_message(MobileId, TimeStamp, MsgBin, CtlNode);
		{badrpc, Reason} ->
			?ERROR_MSG("RPC backup control node failed:~p.~n", [Reason]),
			save_undelivered_message(MobileId, TimeStamp, MsgBin, CtlNode);										
		{ConnNode, Pid} -> 
			rpc_send_message(ConnNode, undefined, MobileId, Pid, TimeStamp, MsgBin)
	end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
rpc_send_message(ConnNode, CtlNode, MobileId, Pid, TimeStamp, MsgBin) ->
	case rpc:call(ConnNode, service_mobile_conn, send_message, [CtlNode, Pid, TimeStamp, MsgBin]) of
		ok -> ok;
		{badrpc, Reason} ->
			?ERROR_MSG("RPC send message failed:~p for mobile: ~p, save undelivered message.~n", [Reason, MobileId]),
			save_undelivered_message(MobileId, TimeStamp, MsgBin, CtlNode);
		{error, Reason} ->
			?ERROR_MSG("RPC send message failed:~p for mobile: ~p, save undelivered message.~n", [Reason, MobileId]),
			save_undelivered_message(MobileId, TimeStamp, MsgBin, CtlNode)
	end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
save_undelivered_message(MobileId, TimeStamp, MsgBin, CtlNode) ->
	case CtlNode of
		undefined -> {error, "message lost"}; %% abandon message when control node is not configured
		_ -> 
			case rpc:call(CtlNode, service_offline_msg, save_undelivered_msg, [MobileId, TimeStamp, MsgBin]) of
				ok -> ok;
				{error, Reason} ->
					?ERROR_MSG("Save undelivered message to control node[~p] failed:~p , save it to local. ~n", [CtlNode, Reason]),
					save_local_undelivered_msg(MobileId, TimeStamp, MsgBin, CtlNode);
				{badrpc, Reason} ->
					?ERROR_MSG("Save undelivered message to control node[~p] failed:~p, save it to local. ~n", [CtlNode, Reason]),
					save_local_undelivered_msg(MobileId, TimeStamp, MsgBin, CtlNode)
			end
	end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
save_local_undelivered_msg(MobileId, TimeStamp, MsgBin, CtlNode) ->
	case CtlNode of
		undefined -> {error, "message lost"};
		_ ->
			Id = mnesia:dirty_update_counter(unique_ids, undelivered_msg, 1),
			Record = #undelivered_msgs{id=Id, mobile_id=MobileId, timestamp=TimeStamp, msg_bin=MsgBin, control_node=CtlNode},
			case mnesia:transaction(fun() -> mnesia:write(Record) end) of
				{atomic, ok} ->
					ok;
				{aborted, Reason} ->
					?CRITICAL_MSG("Save undelivered message to local database failed: ~p ~n", [Reason]),
					{error, "Database failed"}
			end
	end.

