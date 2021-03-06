%% Author: xuxb
%% Created: 2010-12-28
%% Description: ERLANG mobile push application

-module(emconn_app).
-author(xuxb).

-behavior(application).

%%
%% Include files
%%

-include("loglevel.hrl").

%%
%% Exported Functions
%%
-export([start/2, stop/1]).

%%
%% API Functions
%%
start(normal, _Args) ->
	case node() of
		'nonode@nohost' ->
			{error, "emconn must run in distributed eviroment."};
		Node ->
			NodeName = atom_to_list(Node),
			[NodePrefix, _] = string:tokens(NodeName, "@"),
			LogfileName = string:concat("error_log//", string:concat(NodePrefix, ".log")),
			error_logger:add_report_handler(ejabberd_logger_h, LogfileName),
			init_mnesia(),
			emobile_config:start(),
			ctlnode_selector:init(),
			emconn_sup:start_link(),
			{ok, self()}
	end;
start(_, _) ->
	{error, badarg}.

stop(_Args) ->
	ok.


%%
%% Local Functions
%%

init_mnesia()->
	%% initialize database
	case mnesia:system_info(extra_db_nodes) of
		[] ->
			mnesia:create_schema([node()]);
		_ ->
			ok
	end,
	application:start(mnesia, permanent),
	mnesia:wait_for_tables(mnesia:system_info(local_tables), infinity).



%%
%% Test suite
%%