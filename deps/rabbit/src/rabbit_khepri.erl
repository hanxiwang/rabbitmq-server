%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2021 VMware, Inc. or its affiliates.  All rights reserved.
%%

-module(rabbit_khepri).

-include_lib("kernel/include/logger.hrl").

-include_lib("khepri/include/khepri.hrl").
-include_lib("rabbit_common/include/logging.hrl").

-export([setup/0,
         setup/1,
         add_member/1,
         members/0,
         locally_known_members/0,
         nodes/0,
         locally_known_nodes/0,
         get_store_id/0,

         create/2,
         insert/2,
         update/2,
         cas/3,

         get/1,
         get_data/1,
         match/1,
         match_and_get_data/1,
         exists/1,
         find/1,
         list/1,
         list_child_nodes/1,
         list_child_data/1,

         put/2, put/3,
         clear_data/1,
         delete/1,

         dir/0,
         info/0,
         is_enabled/0,
         is_enabled/1,
         try_mnesia_or_khepri/2]).
-export([priv_reset/0]).

-compile({no_auto_import, [get/1, get/2]}).

-define(RA_SYSTEM, coordination).
-define(RA_CLUSTER_NAME, metadata_store).
-define(RA_FRIENDLY_NAME, "RabbitMQ metadata store").
-define(STORE_ID, ?RA_CLUSTER_NAME).
-define(MDSTORE_SARTUP_LOCK, {?MODULE, self()}).
-define(PT_KEY, ?MODULE).

%% -------------------------------------------------------------------
%% API wrapping Khepri.
%% -------------------------------------------------------------------

-spec setup() -> ok | no_return().

setup() ->
    setup(rabbit_prelaunch:get_context()).

-spec setup(map()) -> ok | no_return().

setup(_) ->
    ?LOG_DEBUG("Starting Khepri-based metadata store"),
    ok = ensure_ra_system_started(),
    case khepri:start(?RA_SYSTEM, ?RA_CLUSTER_NAME, ?RA_FRIENDLY_NAME) of
        {ok, ?STORE_ID} ->
            ?LOG_DEBUG(
               "Khepri-based metadata store ready",
               [],
               #{domain => ?RMQLOG_DOMAIN_GLOBAL}),
            ok;
        {error, _} = Error ->
            exit(Error)
    end.

add_member(NewNode) when NewNode =/= node() ->
    ?LOG_DEBUG(
       "Trying to add node ~s to Khepri cluster \"~s\" from node ~s",
       [NewNode, ?RA_CLUSTER_NAME, node()],
       #{domain => ?RMQLOG_DOMAIN_GLOBAL}),

    %% Check if the node is already part of the cluster. We query the local Ra
    %% server only, in case the cluster can't elect a leader right now.
    CurrentNodes = locally_known_nodes(),
    case lists:member(NewNode, CurrentNodes) of
        false ->
            %% Ensure the remote node is reachable before we add it.
            pong = net_adm:ping(NewNode),

            ?LOG_DEBUG(
               "Resetting Khepri on remote node ~s",
               [NewNode],
               #{domain => ?RMQLOG_DOMAIN_GLOBAL}),
            Ret1 = rpc:call(NewNode, rabbit_khepri, priv_reset, []),
            case Ret1 of
                ok ->
                    ?LOG_DEBUG(
                       "Adding remote node ~s to Khepri cluster \"~s\"",
                       [NewNode, ?RA_CLUSTER_NAME],
                       #{domain => ?RMQLOG_DOMAIN_GLOBAL}),
                    ok = ensure_ra_system_started(),
                    Ret2 = khepri:add_member(
                             ?RA_SYSTEM, ?RA_CLUSTER_NAME, ?RA_FRIENDLY_NAME,
                             NewNode),
                    case Ret2 of
                        ok ->
                            ?LOG_DEBUG(
                               "Node ~s added to Khepri cluster \"~s\"",
                               [NewNode, ?RA_CLUSTER_NAME],
                               #{domain => ?RMQLOG_DOMAIN_GLOBAL}),
                            ok = rpc:call(NewNode, rabbit, start, []);
                        {error, _} = Error ->
                            ?LOG_ERROR(
                               "Failed to add remote node ~s to Khepri "
                               "cluster \"~s\": ~p",
                               [NewNode, ?RA_CLUSTER_NAME, Error],
                               #{domain => ?RMQLOG_DOMAIN_GLOBAL}),
                            Error
                    end;
                Error ->
                    ?LOG_ERROR(
                       "Failed to reset Khepri on remote node ~s: ~p",
                       [NewNode, Error],
                       #{domain => ?RMQLOG_DOMAIN_GLOBAL}),
                    Error
            end;
        true ->
            ?LOG_INFO(
               "Asked to add node ~s to Khepri cluster \"~s\" but already a "
               "member of it: ~p",
               [NewNode, ?RA_CLUSTER_NAME, lists:sort(CurrentNodes)],
               #{domain => ?RMQLOG_DOMAIN_GLOBAL}),
            ok
    end.

priv_reset() ->
    ok = rabbit:stop(),
    {ok, _} = application:ensure_all_started(khepri),
    ok = ensure_ra_system_started(),
    ok = khepri:reset(?RA_SYSTEM, ?RA_CLUSTER_NAME).

ensure_ra_system_started() ->
    ok = rabbit_ra_systems:ensure_ra_system_started(?RA_SYSTEM).

members() ->
    khepri:members(?RA_CLUSTER_NAME).

locally_known_members() ->
    khepri:locally_known_members(?RA_CLUSTER_NAME).

nodes() ->
    khepri:nodes(?RA_CLUSTER_NAME).

locally_known_nodes() ->
    khepri:locally_known_nodes(?RA_CLUSTER_NAME).

get_store_id() ->
    ?STORE_ID.

dir() ->
    filename:join(rabbit_mnesia:dir(), atom_to_list(?STORE_ID)).

%% -------------------------------------------------------------------
%% "Proxy" functions to Khepri API.
%% -------------------------------------------------------------------

%% They just add the store ID to every calls.
%%
%% The only exceptions are get() and match() which both call khepri:get()
%% behind the scene with different options.
%%
%% They are some additional functions too, because they are useful in RabbitMQ.
%% They might be moved to Khepri in the future.

create(Path, Data) -> khepri:create(?STORE_ID, Path, Data).
insert(Path, Data) -> khepri:insert(?STORE_ID, Path, Data).
update(Path, Data) -> khepri:update(?STORE_ID, Path, Data).
cas(Path, Pattern, Data) ->
    khepri:compare_and_swap(?STORE_ID, Path, Pattern, Data).

get(Path) ->
    case khepri:get(?STORE_ID, Path, #{expect_specific_node => true}) of
        {ok, Result} ->
            [PropsAndData] = maps:values(Result),
            {ok, PropsAndData};
        Error ->
            Error
    end.

get_data(Path) ->
    case get(Path) of
        {ok, #{data := Data}} -> {ok, Data};
        {ok, Result}          -> {error, {no_data, Result}};
        Error                 -> Error
    end.

match(Path) -> khepri:get(?STORE_ID, Path).

match_and_get_data(Path) ->
    Ret = match(Path),
    keep_data_only(Ret).

exists(Path) -> khepri:exists(?STORE_ID, Path).
find(Path) -> khepri:find(?STORE_ID, Path).
list(Path) -> khepri:list(?STORE_ID, Path).

list_child_nodes(Path) ->
    Options = #{expect_specific_node => true,
                include_child_names => true},
    case khepri:get(?STORE_ID, Path, Options) of
        {ok, Result} ->
            [#{child_names := ChildNames}] = maps:values(Result),
            {ok, ChildNames};
        Error ->
            Error
    end.

list_child_data(Path) ->
    Ret = list(Path),
    keep_data_only(Ret).

keep_data_only({ok, Result}) ->
    Result1 = maps:fold(
                fun
                    (Path, #{data := Data}, Acc) -> Acc#{Path => Data};
                    (_, _, Acc)                  -> Acc
                end, #{}, Result),
    {ok, Result1};
keep_data_only(Error) ->
    Error.

clear_data(Path) -> khepri:clear_data(?STORE_ID, Path).
delete(Path) -> khepri:delete(?STORE_ID, Path).

put(PathPattern, Data) ->
    khepri_machine:put(?STORE_ID, PathPattern, ?DATA_PAYLOAD(Data)).

put(PathPattern, Data, Extra) ->
    khepri_machine:put(?STORE_ID, PathPattern, ?DATA_PAYLOAD(Data), Extra).

info() ->
    ok = setup(),
    khepri:info(?STORE_ID).

%% -------------------------------------------------------------------
%% Raft-based metadata store (phase 1).
%% -------------------------------------------------------------------

is_enabled() ->
    rabbit_feature_flags:is_enabled(raft_based_metadata_store_phase1).

is_enabled(Blocking) ->
    rabbit_feature_flags:is_enabled(
      raft_based_metadata_store_phase1, Blocking) =:= true.

try_mnesia_or_khepri(MnesiaFun, KhepriFun) ->
    case rabbit_khepri:is_enabled(non_blocking) of
        true ->
            KhepriFun();
        false ->
            try
                MnesiaFun()
            catch
                Class:{Type, {no_exists, Table}} = Reason:Stacktrace
                  when Type =:= aborted orelse Type =:= error ->
                    case is_mnesia_table_covered_by_feature_flag(Table) of
                        true ->
                            %% We wait for the feature flag(s) to be enabled
                            %% or disabled (this is a blocking call) and
                            %% retry.
                            ?LOG_DEBUG(
                               "Mnesia function failed because table ~s "
                               "is gone or read-only; checking if the new "
                               "metadata store was enabled in parallel and "
                               "retry",
                               [Table]),
                            _ = rabbit_khepri:is_enabled(),
                            try_mnesia_or_khepri(MnesiaFun, KhepriFun);
                        false ->
                            erlang:raise(Class, Reason, Stacktrace)
                    end
            end
    end.

is_mnesia_table_covered_by_feature_flag(rabbit_vhost)            -> true;
is_mnesia_table_covered_by_feature_flag(rabbit_user)             -> true;
is_mnesia_table_covered_by_feature_flag(rabbit_user_permission)  -> true;
is_mnesia_table_covered_by_feature_flag(rabbit_topic_permission) -> true;
is_mnesia_table_covered_by_feature_flag(_)                       -> false.
