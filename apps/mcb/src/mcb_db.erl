%%%------------------------------------------------------------------------
%%% @doc Database tools for Macaba board, provides code for encoding, decoding
%%% and versioning (upgrading) data pieces
%%% @version 2013-02-19
%%% @author Dmytro Lytovchenko <kvakvs@yandex.ru>
%%%------------------------------------------------------------------------
-module(mcb_db).

-export([ upgrade/3
        , decode/2
        , encode/2
        , current_version_for/1
        , get_key_for_object/1
        , key_for/2
        , reset_all_data/0
        , updated_in_mnesia/2
        , start_resync/0
        , mnesia_resync/0
        ]).

-include_lib("mcb/include/macaba_types.hrl").

%% Represents an value in updated Mnesia memory table. Current cluster
%% leader fetches records from ETS and sends them to RIAK periodically.
%% TODO: Stop syncing if leader changes, transfer update lists to new leader?
-record(mcb_riak_sync, {
            id     :: {atom(), binary()}
         }).
-define(RESYNC_SLEEP_MSEC, 1000).

%%%-----------------------------------------------------------------------------
%% @doc You would not want to call this in production, no really
reset_all_data() ->
  mnesia:clear_table(mcb_board_dynamic),
  mnesia:clear_table(mcb_thread_dynamic),
  OTypes = [ mcb_site_config, mcb_board_dynamic, mcb_thread_dynamic
           , mcb_thread, mcb_post, mcb_attachment, mcb_attachment_body],
  lists:foreach(fun(T) -> reset_all_data_riak(T) end, OTypes),
  %% create board dynamic for default board
  lists:foreach(fun(Board) ->
                  BD = #mcb_board_dynamic{board_id = Board#mcb_board.board_id},
                  mcb_db_mnesia:write(mcb_board_dynamic, BD)
                end, mcb_board:get_boards()).

%% @private
%% @doc Deletes all RIAK records for given object type
reset_all_data_riak(ObjType) ->
  Bucket = mcb_db_riak:bucket_for(ObjType),
  {ok, Keys} = riak_pool_auto:list_keys(Bucket),
  lists:foreach(fun(K) ->
                    ok = riak_pool_auto:delete(Bucket, K)
                end, Keys).

%%%-----------------------------------------------------------------------------
%% @doc Stub for data upgrade function, to support multiple versions
%% of the same data. On successful upgrade data is written back too!
-spec upgrade(Type :: mcb_riak_object(), Ver :: integer(), any()) -> any().

upgrade(mcb_site_config,     ?MCB_SITE_CONFIG_VER,     X) -> X;
upgrade(mcb_board_dynamic,   ?MCB_BOARD_DYNAMIC_VER,   X) -> X;
upgrade(mcb_thread,          ?MCB_THREAD_VER,          X) -> X;
upgrade(mcb_thread_dynamic,  ?MCB_THREAD_DYNAMIC_VER,  X) -> X;
upgrade(mcb_post,            ?MCB_POST_VER,            X) -> X;
upgrade(mcb_attachment,      ?MCB_ATTACHMENT_VER,      X) -> X;
upgrade(mcb_attachment_body, ?MCB_ATTACHMENT_BODY_VER, X) -> X.

%%%-----------------------------------------------------------------------------
%% @doc Decodes database object, as a tuple of {version, binaryencoded}
%% if version is too low, the object is filtered through upgrade/3
-spec decode(T :: mcb_riak_object(), Bin :: binary()) -> tuple().

decode(T, Bin) ->
  {Version, Value} = binary_to_term(Bin, [safe]),
  upgrade(T, Version, Value).

%%%-----------------------------------------------------------------------------
%% @doc Encodes database object with current version. ON READ if version is too
%% low, its gets filtered through upgrade/3
-spec encode(T :: mcb_riak_object(), P :: any()) -> binary().

encode(T, P) -> term_to_binary( {current_version_for(T), P} ).

%%%-----------------------------------------------------------------------------
%% @doc Version for newly created riak object
-spec current_version_for(mcb_riak_object()) -> integer().

current_version_for(mcb_site_config)     -> ?MCB_SITE_CONFIG_VER;
current_version_for(mcb_board_dynamic)   -> ?MCB_BOARD_DYNAMIC_VER;
current_version_for(mcb_thread)          -> ?MCB_THREAD_VER;
current_version_for(mcb_thread_dynamic)  -> ?MCB_THREAD_DYNAMIC_VER;
current_version_for(mcb_post)            -> ?MCB_POST_VER;
current_version_for(mcb_attachment)      -> ?MCB_ATTACHMENT_VER;
current_version_for(mcb_attachment_body) -> ?MCB_ATTACHMENT_BODY_VER.

%%--------------------------------------------------------------------
%% @doc Extracts key from object
get_key_for_object(#mcb_thread{ thread_id=TId, board_id=BId }) ->
  key_for(mcb_thread, {BId, TId});
get_key_for_object(#mcb_post{ post_id=PId, board_id=BId }) ->
  key_for(mcb_post, {BId, PId});
get_key_for_object(#mcb_thread_dynamic{ board_id=BId, thread_id=TId }) ->
  key_for(mcb_thread_dynamic, {BId, TId});
get_key_for_object(#mcb_board_dynamic{ board_id = Id }) -> Id;
get_key_for_object(#mcb_attachment{ hash = Id }) -> Id;
get_key_for_object(#mcb_attachment_body{ key = Id }) -> Id;
get_key_for_object(#mcb_site_config{ site_id = Id }) -> Id.

%%%-----------------------------------------------------------------------------
%% @doc Creates complex key
key_for(mcb_thread, {BId, TId}) ->
  << "B=", BId/binary, ":T=", TId/binary >>;
key_for(mcb_post,   {BId, PId}) ->
  << "B=", BId/binary, ":P=", PId/binary >>;
key_for(mcb_thread_dynamic, {BId, TId}) ->
  << "B=", BId/binary, ":T=", TId/binary >>;
key_for(T, K) ->
  lager:error("key_for T=~p K=~p unknown type, ~p",
              [T, K, erlang:get_stacktrace()]),
  erlang:error({error, badarg}).

%%%-----------------------------------------------------------------------------
updated_in_mnesia(Type, Key) ->
  SyncValue = #mcb_riak_sync{id={Type, Key}},
  ets:insert(mcb_riak_sync, SyncValue).

start_resync() ->
  ets:new(mcb_riak_sync, [ public
                         , set
                         , named_table
                         , {write_concurrency, true}
                         , {keypos, #mcb_riak_sync.id}
                         ]),
  lager:info("mcb_db: resync to RIAK enabled"),
  timer:apply_after(?RESYNC_SLEEP_MSEC, ?MODULE, mnesia_resync, []).

%% @private
%% @doc Iterates over ETS mcb_riak_sync tab, each key represents record type
%% and key to read from Mnesia and save to RIAK.
mnesia_resync() ->
  timer:apply_after(?RESYNC_SLEEP_MSEC, ?MODULE, mnesia_resync, []),
  Tab = mcb_riak_sync,
  mnesia_resync_2(ets:first(Tab)),
  %% this is called synchronously from masternode process, so we guarantee
  %% that there will be no writes to ETS while sync is in progress
  ets:delete_all_objects(Tab).

%% @private
mnesia_resync_2('$end_of_table') -> ok;
mnesia_resync_2(K) ->
  Tab = mcb_riak_sync,
  [#mcb_riak_sync{id={Type, Key}}] = ets:lookup(Tab, K),
  case mcb_db_mnesia:read(Type, Key) of
    {error, not_found} ->
      lager:debug("sync: delete ~p key=~p", [Type, Key]),
      mcb_db_riak:delete(Type, Key);
    {ok, Value} ->
      lager:debug("sync: write ~p key=~p", [Type, Key]),
      mcb_db_riak:write(Type, Value)
  end,
  mnesia_resync_2(ets:next(Tab, K)).

%%% Local Variables:
%%% erlang-indent-level: 2
%%% End:
