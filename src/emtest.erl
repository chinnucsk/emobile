%% Author: Administrator
%% Created: 2010-12-30
%% Description: TODO: Add description to emtest
-module(emtest).

%%
%% Include files
%%

-include("loglevel.hrl").
-include("message_define.hrl").

%%
%% Exported Functions
%%
-export([test/0, load_test/2, login/1, login_push/0, get_conn_addr/2, send_message/3, push_message/2, ping/1, check_mobile_login/1, broadcast_msg/1, broadcast_all/1]).

%%
%% API Functions
%%


-define(SERVER, "push.hiapk.com").
%% -define(SERVER, "192.168.9.149").


test() ->
	loglevel:set(5),
	login_push(),
	
%% 	login(10001),
	login(10002),
	
	timer:sleep(10),
	
%% 	check_mobile_login(10001),	
%% 	check_mobile_login(10002),
	
%% 	timer:sleep(999),
	
%% 	push_message(10001, "test push 10001"),
%% 	push_message(10003, "test push 10003"),
	
%% 	send_message(10001, 10002,   "test1"),
	ok.

load_test(Low, High) ->
	loglevel:set(2),
	?CRITICAL_MSG("starting load test....", []),
	F = fun(MobileId) ->
			Port = 9021 + (MobileId rem 6),
			login_load("192.168.9.149", Port, MobileId),
			timer:sleep(5)
		end,
	spawn(fun() -> lists:foreach(F, lists:seq(Low, High)) end),
	ok.

get_conn_addr(Ip, Port) ->
	case gen_tcp:connect(Ip, Port, [binary, {packet, 0}, {active, once}]) of
		{ok, Sock} -> 
			case gen_tcp:send(Sock, <<4: 2/?NET_ENDIAN-unit:8, ?MSG_LOOKUP_SERVER: 2/?NET_ENDIAN-unit:8>>) of
				ok ->
					wait_full_conn_addr_response(Sock, <<>>);
				{error, Reason} ->
					{error, Reason}
			end;
		{error, Reason} ->
				{error, Reason}
	end.

wait_full_conn_addr_response(Sock, LastBin) ->
	receive 
		{tcp, Sock, Bin} ->
%% 			io:format("receive binary data: ~p ~n", [Bin]),
			Data = <<LastBin/binary, Bin/binary>>,
			case byte_size(Data) >= 10 of
				true ->
					<<_: 2/?NET_ENDIAN-unit:8,
                      ?MSG_SERVER_ADDR: 2/?NET_ENDIAN-unit:8,
                      AA: 1/unit:8,
                      BB: 1/unit:8,
                      CC: 1/unit:8,
                      DD: 1/unit:8,
                      Port: 2/?NET_ENDIAN-unit:8,
                      _/binary>> = Data,
                    gen_tcp:close(Sock),
                    {ok, {{AA, BB, CC, DD}, Port}};
                 false ->
                    wait_full_conn_addr_response(Sock, Data)
           end;
       Other ->
           io:format("receive ~p ~n", [Other])
     end.

							
login_load(Ip, Port, MobileId) ->
	spawn(fun() -> test_client(Ip, Port, MobileId) end),
	ok.

login(MobileId) ->
	{ok, {Ip, Port}} = get_conn_addr(?SERVER, 9527),
	io:format("conn to ~p for ~p ~n", [{Ip, Port}, MobileId]),
	Pid = spawn(fun() -> test_client(Ip, Port, MobileId) end),
	put(MobileId, Pid),
	ok.

login_push() ->
	Pid = spawn(fun() -> test_push(?SERVER, 9510) end),
	put(push, Pid),
	ok.

send_message(From, To,  Message) ->
	MsgBin = list_to_binary(Message),
	MsgLeng = byte_size(MsgBin) + 8 + 4 + 4 + 4 + 4,
	
	SendBin = <<MsgLeng: 2/?NET_ENDIAN-unit:8,
				?MSG_DELIVER: 2/?NET_ENDIAN-unit:8,
				From: 4/ ?NET_ENDIAN-unit:8,
				0: 8/?NET_ENDIAN-unit:8,				
				1 : 4/?NET_ENDIAN-unit:8,
				To: 4/?NET_ENDIAN-unit:8,
				MsgBin/binary>>,
	
	case get(From) of
		undefined ->
			{error, "not login"};
		Pid ->
			Pid ! {tcp_send, SendBin},
			ok
	end.

push_message(To,  Message) ->
	MsgBin = list_to_binary(Message),
	MsgLeng = byte_size(MsgBin) + 8 + 4 + 4 + 4 + 4,
	
	SendBin = <<MsgLeng: 2/?NET_ENDIAN-unit:8,
				?MSG_DELIVER: 2/?NET_ENDIAN-unit:8,
				0: 4/ ?NET_ENDIAN-unit:8,
				0: 8/?NET_ENDIAN-unit:8,				
				1 : 4/?NET_ENDIAN-unit:8,
				To: 4/?NET_ENDIAN-unit:8,
				MsgBin/binary>>,
	
	case get(push) of
		undefined ->
			{error, "not login"};
		Pid ->
			Pid ! {tcp_send, SendBin},
			ok
	end.

check_mobile_login(MobileId) ->
	SendBin = <<8: 2/?NET_ENDIAN-unit:8,
                ?MSG_LOOKUP_CLIENT: 2/?NET_ENDIAN-unit:8,
                MobileId: 4/?NET_ENDIAN-unit:8>>,
	case get(push) of
		undefined -> 
			{error, "not connect push"};
		Pid ->
			Pid ! {tcp_send, SendBin},
			ok
	end.

broadcast_msg(Message) ->
	MsgBin = list_to_binary(Message),
	MsgLeng = 18 + byte_size(MsgBin),
	
	SendBin = <<MsgLeng: 2/?NET_ENDIAN-unit:8,
				?MSG_BROADCAST: 2/?NET_ENDIAN-unit:8,
				?BROADCAST_ONLINE: 2/?NET_ENDIAN-unit:8,
				0: 4/ ?NET_ENDIAN-unit:8,
				0: 8/?NET_ENDIAN-unit:8,				
				MsgBin/binary>>,
	
	case get(push) of
		undefined ->
			{error, "not login"};
		Pid ->
			Pid ! {tcp_send, SendBin},
			ok
	end.

broadcast_all(Message) ->
	MsgBin = list_to_binary(Message),
	MsgLeng = 18 + byte_size(MsgBin),
	
	SendBin = <<MsgLeng: 2/?NET_ENDIAN-unit:8,
				?MSG_BROADCAST: 2/?NET_ENDIAN-unit:8,
				?BROADCAST_ALL: 2/?NET_ENDIAN-unit:8,
				0: 4/ ?NET_ENDIAN-unit:8,
				0: 8/?NET_ENDIAN-unit:8,				
				MsgBin/binary>>,
	
	case get(push) of
		undefined ->
			{error, "not login"};
		Pid ->
			Pid ! {tcp_send, SendBin},
			ok
	end.

ping(MobileId) ->
	SendBin = << 4: 2/?NET_ENDIAN-unit:8,
				 ?MSG_PING: 2/?NET_ENDIAN-unit:8,
				 MobileId: 4/?NET_ENDIAN-unit:8>>,
	
	case get(MobileId) of
		undefined -> {error, "Not login"};
		Pid -> Pid ! {tcp_send, SendBin}, ok
	end.


%%
%% Local Functions
%%

test_push(Ip, Port) ->
	case gen_tcp:connect(Ip, Port, [binary, {packet, 0}, {active, once}]) of
		{ok, Sock} -> 
			?INFO_MSG("push connection established.", []),
			push_loop(Ip, Port, Sock, <<>>);

		{error, Reason} -> 
			?ERROR_MSG("Push connect server NG: ~p!", [Reason]),
			timer:sleep(4999),
			test_push(Ip, Port)
	end.	

push_loop(Ip, Port, Sock, LastMsg) ->
	receive
		{tcp_closed, Sock} ->
			?ERROR_MSG("Push lost connection to push node! ~n", []),
			timer:sleep(2999),
 			test_push(Ip, Port);
		
		{tcp_send, Buf} ->
			case gen_tcp:send(Sock, Buf) of
				{error, Reason} ->
					gen_tcp:close(Sock),
					?ERROR_MSG("Send message FAILED: ~p, stop processing push. ~n", [Reason]);
				ok -> 
 					push_loop(Ip, Port, Sock, LastMsg)
			end;
		
		{tcp, Sock, Bin} ->
			%%?INFO_MSG("Receive binary: ~p ~n", [Bin]),
			{ok, LastMsg1} = process_push_msg(<<LastMsg/binary, Bin/binary>>),
			inet:setopts(Sock, [{active, once}]),
			push_loop(Ip, Port, Sock, LastMsg1)

	end.	

process_push_msg(Bin) ->
	%%io:format("process received msg: ~p ~n", [Bin]),
	case Bin of
		<<MsgSize:2/?NET_ENDIAN-unit:8, MsgType:2/?NET_ENDIAN-unit:8, Extra/binary>> ->
			case MsgSize =< ?MAX_MSG_SIZE of
				true ->
					MsgBodySize = MsgSize - 4,
					case Extra of
						<<MsgBody:MsgBodySize/binary, Rest/binary>> ->
							on_push_msg(MsgSize, MsgType, MsgBody), %% call funcion that handles client messages
							process_push_msg(Rest);
						<<_/binary>> ->
							%% not enough binary case
							{ok, Bin}
					end;
				false ->
					{error, Bin}
			end;
		
		<<_SomeBin/binary>> ->
			{ok, Bin}
	end.

on_push_msg(_MsgSize, MsgType, MsgBody) ->
	case MsgType of
		?MSG_RESULT ->
			on_msg_result(MsgBody);
		_ ->
			ok
	end.

on_msg_result(MsgBody) ->
	<<MsgType: 2/?NET_ENDIAN-unit:8,
      Result: 2/?NET_ENDIAN-unit:8,
	  MobileId: 4/?NET_ENDIAN-unit:8, 
	  _OtherBin/binary>> = MsgBody,

    case MsgType of
        ?MSG_LOOKUP_CLIENT ->    
			case MobileId of
				0 -> ?INFO_MSG("Bug found: MobileId is not set when receive result of lookup client login.", []);
				_ -> 
					case Result of
						0 -> ?INFO_MSG("Mobile: ~p has logined!", [MobileId]);
						_ -> ?INFO_MSG("Mobile: ~p NOT login: ~p", [MobileId, Result])
					end
			end;
       ?MSG_DELIVER ->
			?INFO_MSG("push message to mobile[~p] result: ~p ~n", [MobileId, Result])
    end.

test_client(Ip, Port, MobileId) ->
	case gen_tcp:connect(Ip, Port, [binary, {packet, 0}, {active, once}]) of
		{ok, Sock} -> 
			LoginBin = <<8: 2/?NET_ENDIAN-unit:8,
			             ?MSG_LOGIN:2/ ?NET_ENDIAN-unit:8,
			             MobileId: 4/ ?NET_ENDIAN-unit:8>>,
			case gen_tcp:send(Sock, LoginBin) of
				{error, Reason} ->
					gen_tcp:close(Sock),
					?ERROR_MSG("Login ~p failed: ~p ~n", [MobileId, Reason]),
					timer:sleep(2999),
					test_client(Ip, Port, MobileId);
				ok -> 
                    %%?INFO_MSG("login mobile: ~p ok", [MobileId]),
					erlang:start_timer(29999, self(), ping_server),
					client_loop(Ip, Port, MobileId, Sock, <<>>)
			end;

		{error, Reason} -> 
			?ERROR_MSG("Clent[~p] connect server NG: ~p!", [MobileId, Reason]),
			timer:sleep(4999),
			test_client(Ip, Port, MobileId)
	end.

client_loop(Ip, Port, MobileId, Sock, LastMsg) ->
	receive
		{tcp_closed, Sock} ->
			?ERROR_MSG("Client[~p] lost connection to conn node! ~n", [MobileId]),
			timer:sleep(2999),
%% 			erlang:hibernate(?MODULE, test_client, [Ip, Port, MobileId]);
 			test_client(Ip, Port, MobileId);
	
		
		{tcp_send, Buf} ->
			case gen_tcp:send(Sock, Buf) of
				{error, Reason} ->
					gen_tcp:close(Sock),
					?ERROR_MSG("Send message FAILED: ~p, stop processing mobile: ~p ~n", [Reason, MobileId]);
				ok -> 
%% 					erlang:hibernate(?MODULE, client_loop, [Ip, Port, MobileId, Sock, LastMsg])
 					client_loop(Ip, Port, MobileId, Sock, LastMsg)
			end;
		
		{tcp, Sock, Bin} ->
			%%?INFO_MSG("Receive binary: ~p ~n", [Bin]),
			{ok, LastMsg1} = process_received_msg(MobileId, <<LastMsg/binary, Bin/binary>>),
			inet:setopts(Sock, [{active, once}]),
			client_loop(Ip, Port, MobileId, Sock, LastMsg1);
		
		{timeout, _TimerRef, ping_server} ->
			erlang:start_timer(29999, self(), ping_server),
			SendBin = << 8: 2/?NET_ENDIAN-unit:8,
                         ?MSG_PING: 2/?NET_ENDIAN-unit:8,
                         MobileId: 4/?NET_ENDIAN-unit:8>>,	
            self() ! {tcp_send, SendBin},
			client_loop(Ip, Port, MobileId, Sock, LastMsg);

		_ ->
			gen_tcp:close(Sock),
			?INFO_MSG("Close connection of mobile[~p].", [MobileId]),
			timer:sleep(1000),
			test_client(Ip, Port, MobileId)

end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
process_received_msg(MobileId, Bin) when is_binary(Bin) ->
	%%io:format("process received msg: ~p ~n", [Bin]),
	case Bin of
		<<MsgSize:2/?NET_ENDIAN-unit:8, MsgType:2/?NET_ENDIAN-unit:8, Extra/binary>> ->
			case MsgSize =< ?MAX_MSG_SIZE of
				true ->
					MsgBodySize = MsgSize - 4,
					case Extra of
						<<MsgBody:MsgBodySize/binary, Rest/binary>> ->
							on_receive_msg(MobileId, MsgSize, MsgType, MsgBody), %% call funcion that handles client messages
							process_received_msg(MobileId, Rest);
						<<_/binary>> ->
							%% not enough binary case
							{ok, Bin}
					end;
				false ->
					{error, Bin}
			end;
		
		<<_SomeBin/binary>> ->
			{ok, Bin}
	end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
on_receive_msg(MobileId, _MsgSize, MsgType, MsgBody) ->
	case MsgType of
		?MSG_LOGIN -> ?ERROR_MSG("client[~p] receive illegal message: MSG_LOGIN. ~n", [MobileId]);
		?MSG_PING  -> void; %%?INFO_MSG("client[~p] receive ping. ~n", [MobileId]);
		?MSG_DELIVER -> on_client_msg_deliver(MobileId, MsgBody);
		?MSG_RESULT -> on_client_msg_result(MsgBody)
	end.	

on_client_msg_result(MsgBody) ->
	<<MsgType: 2/?NET_ENDIAN-unit:8,
      Result: 2/?NET_ENDIAN-unit:8,
	  MobileId: 4/?NET_ENDIAN-unit:8, 
	  _OtherBin/binary>> = MsgBody,

    case MsgType of
        ?MSG_LOGIN ->    
			?INFO_MSG("login client[~p]: result: ~p ~n", [MobileId, Result]),
			self() ! {disconnect, MobileId}
    end.	

on_client_msg_deliver(_Client, MsgBody) ->
	<<SrcMobileId: 4/?NET_ENDIAN-unit:8, TimeStamp:8/binary, TargetNum: 4/?NET_ENDIAN-unit:8>> = binary:part(MsgBody, 0, 16),
	TargetList = emobile_message:decode_target_list(binary:part(MsgBody, 16, TargetNum * 4), TargetNum, []),
	MsgContent = binary:part(MsgBody, 16 + TargetNum*4, byte_size(MsgBody) - (16 + TargetNum * 4)), %% ignore client timestamp
	<<Year: 2/?NET_ENDIAN-unit:8, 
	  Month: 1/?NET_ENDIAN-unit:8, 
	  Day: 1/?NET_ENDIAN-unit:8, 
	  0: 1/?NET_ENDIAN-unit:8,
	  Hour: 1/?NET_ENDIAN-unit:8, 
	  Min: 1/?NET_ENDIAN-unit:8, 
	  Sec: 1/?NET_ENDIAN-unit:8>> = TimeStamp,
	?INFO_MSG("~p -> ~p [~p-~p-~p ~p:~p:~p]: ~n""~p ~n", 
              [SrcMobileId, TargetList, Year, Month, Day, Hour, Min, Sec, MsgContent]),

	ok.

