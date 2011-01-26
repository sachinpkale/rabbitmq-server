%%   Version 1.1 (the "License"); you may not use this file except in
%%   compliance with the License. You may obtain a copy of the License at
%%   http://www.mozilla.org/MPL/
%%
%%   Software distributed under the License is distributed on an "AS IS"
%%   basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%%   License for the specific language governing rights and limitations
%%   under the License.
%%
%%   The Original Code is RabbitMQ.
%%
%%   The Initial Developers of the Original Code are LShift Ltd,
%%   Cohesive Financial Technologies LLC, and Rabbit Technologies Ltd.
%%
%%   Portions created before 22-Nov-2008 00:00:00 GMT by LShift Ltd,
%%   Cohesive Financial Technologies LLC, or Rabbit Technologies Ltd
%%   are Copyright (C) 2007-2008 LShift Ltd, Cohesive Financial
%%   Technologies LLC, and Rabbit Technologies Ltd.
%%
%%   Portions created by LShift Ltd are Copyright (C) 2007-2011 LShift
%%   Ltd. Portions created by Cohesive Financial Technologies LLC are
%%   Copyright (C) 2007-2011 Cohesive Financial Technologies
%%   LLC. Portions created by Rabbit Technologies Ltd are Copyright
%%   (C) 2007-2011 Rabbit Technologies Ltd.
%%
%%   All Rights Reserved.
%%
%%   Contributor(s): ______________________________________.
%%

-module(rabbit_mnesia_queue).

-export(
   [start/1, stop/0, init/3, terminate/1, delete_and_terminate/1, purge/1,
    publish/3, publish_delivered/4, fetch/2, ack/2, tx_publish/4, tx_ack/3,
    tx_rollback/2, tx_commit/4, requeue/3, len/1, is_empty/1, dropwhile/2,
    set_ram_duration_target/2, ram_duration/1, needs_idle_timeout/1,
    idle_timeout/1, handle_pre_hibernate/1, status/1]).

%%----------------------------------------------------------------------------
%% This is a simple implementation of the rabbit_backing_queue
%% behavior, with all msgs in Mnesia.
%%
%% This will eventually be structured as a plug-in instead of an extra
%% module in the middle of the server tree....
%% ----------------------------------------------------------------------------

%%----------------------------------------------------------------------------
%% This module wraps msgs into M records for internal use, including
%% additional information. Pending acks are also recorded as Ms. Msgs
%% and pending acks are both stored in Mnesia.
%%
%% All queues are durable in this version, and all msgs are treated as
%% persistent. (This will break some clients and some tests for
%% non-durable queues.)
%% ----------------------------------------------------------------------------

%% BUG: The rabbit_backing_queue_spec behaviour needs improvement. For
%% example, rabbit_amqqueue_process knows too much about the state of
%% a backing queue, even though this state may now change without its
%% knowledge. Additionally, there are points in the protocol where
%% failures can lose messages.

%% BUG: Need to provide better back-pressure when queue is filling up.

%% BUG: Need to store each message in a separate row.

%% BUG: Need to think about recovering pending acks.

%% BUG: Should not use mnesia:all_keys to count entries.

%% BUG: P records do not need a separate seq_id.

-behaviour(rabbit_backing_queue).

-record(s,                  % The in-RAM queue state
        { mnesia_q_table,   % The Mnesia Q table name
          mnesia_p_table,   % The Mnesia P table name
          mnesia_n_table,   % The Mnesia N table name
          q,                % The M queue
          next_seq_id,      % The next M's seq_id
          next_out_id,      % The next M's out id
          txn_dict          % In-progress txn->tx map
        }).

-record(m,                  % A wrapper aroung a msg
        { seq_id,           % The seq_id for the msg
          msg,              % The msg itself
          props,            % The msg properties
          is_delivered      % Has the msg been delivered? (for reporting)
        }).

-record(tx,
        { to_pub,           % List of (msg, props) pairs to publish
          to_ack            % List of seq_ids to ack
        }).

-record(q_record,           % Temporary whole-queue record in Mnesia
        { key,              % The key: the atom 'q'
          q                 % The M queue
          }).

-record(p_record,           % P record in Mnesia
        { seq_id,           % The key: The seq_id
          m                 % The value: The M
          }).

-record(n_record,           % next_seq_id & next_out_id record in Mnesia
        { key,              % The key: the atom 'n'
          next_seq_id,      % The Mnesia next_seq_id
          next_out_id       % The Mnesia next_out_id
          }).

-include("rabbit.hrl").

%%----------------------------------------------------------------------------

%% BUG: Restore -ifdef, -endif.

%% -ifdef(use_specs).

-type(seq_id() :: non_neg_integer()).
-type(ack() :: seq_id() | 'blank_ack').

-type(s() :: #s { mnesia_q_table :: atom(),
                  mnesia_p_table :: atom(),
                  mnesia_n_table :: atom(),
                  q :: queue(),
                  next_seq_id :: seq_id(),
                  next_out_id :: non_neg_integer(),
                  txn_dict :: dict() }).
-type(state() :: s()).

-type(m() :: #m { msg :: rabbit_types:basic_message(),
                  seq_id :: seq_id(),
                  props :: rabbit_types:message_properties(),
                  is_delivered :: boolean() }).

-type(tx() :: #tx { to_pub :: [{rabbit_types:basic_message(),
                                rabbit_types:message_properties()}],
                    to_ack :: [seq_id()] }).

-type(q_record() :: #q_record { key :: 'q',
                                q :: queue() }).

-type(p_record() :: #p_record { seq_id :: seq_id(),
                                m :: m() }).

-type(n_record() :: #n_record { key :: 'n',
                                next_seq_id :: seq_id(),
                                next_out_id :: non_neg_integer() }).

-include("rabbit_backing_queue_spec.hrl").

%% -endif.

%%----------------------------------------------------------------------------
%% Public API
%%
%% Specs are in rabbit_backing_queue_spec.hrl but are repeated here.

%%----------------------------------------------------------------------------
%% start/1 promises that a list of (durable) queue names will be
%% started in the near future. This lets us perform early checking
%% necessary for the consistency of those queues or initialise other
%% shared resources. This function creates an Mnesia transaction to
%% run in, and therefore may not be called from inside another Mnesia
%% transaction.
%%
%% -spec(start/1 :: ([rabbit_amqqueue:name()]) -> 'ok').

%%----------------------------------------------------------------------------
%% Public API
%%----------------------------------------------------------------------------

start(_DurableQueues) -> ok.

%%----------------------------------------------------------------------------
%% stop/0 tears down all state/resources upon shutdown. It might not
%% be called. This function creates an Mnesia transaction to run in,
%% and therefore may not be called from inside another Mnesia
%% transaction.
%%
%% -spec(stop/0 :: () -> 'ok').

stop() -> ok.

%%----------------------------------------------------------------------------
%% init/3 creates one backing queue, returning its state. Names are
%% local to the vhost, and must be unique. This function creates
%% Mnesia transactions to run in, and therefore may not be called from
%% inside another Mnesia transaction.
%%
%% -spec(init/3 ::
%%         (rabbit_amqqueue:name(), is_durable(), attempt_recovery())
%%         -> state()).

%% BUG: Should fsck state, and should drop non-persistent msgs.

%% BUG: It's unfortunate that this can't all be done in a single
%% Mnesia transaction!

init(QueueName, _IsDurable, _Recover) ->
    rabbit_log:info("init(~n ~p,~n _, _) ->", [QueueName]),
    {MnesiaQTable, MnesiaPTable, MnesiaNTable} = mnesia_tables(QueueName),
    QAttributes = record_info(fields, q_record),
    case mnesia:create_table(
           MnesiaQTable,
           [{record_name, 'q_record'}, {attributes, QAttributes}])
    of
        {atomic, ok} -> ok;
        {aborted, {already_exists, MnesiaQTable}} ->
            'q_record' = mnesia:table_info(MnesiaQTable, record_name),
            QAttributes = mnesia:table_info(MnesiaQTable, attributes),
            ok
    end,
    PAttributes = record_info(fields, p_record),
    case mnesia:create_table(
           MnesiaPTable,
           [{record_name, 'p_record'}, {attributes, PAttributes}])
    of
        {atomic, ok} -> ok;
        {aborted, {already_exists, MnesiaPTable}} ->
            'p_record' = mnesia:table_info(MnesiaPTable, record_name),
            PAttributes = mnesia:table_info(MnesiaPTable, attributes),
            ok
    end,
    NAttributes = record_info(fields, n_record),
    {NextSeqId, NextOutId} =
        case mnesia:create_table(
               MnesiaNTable,
               [{record_name, 'n_record'}, {attributes, NAttributes}])
        of
            {atomic, ok} -> {0, 0};
            {aborted, {already_exists, MnesiaNTable}} ->
                'n_record' = mnesia:table_info(MnesiaNTable, record_name),
                NAttributes = mnesia:table_info(MnesiaNTable, attributes),
                [#n_record { key = 'n',
                             next_seq_id = NextSeqId0,
                             next_out_id = NextOutId0 }] =
                    mnesia:dirty_read(MnesiaNTable, 'n'),
                {NextSeqId0, NextOutId0}
        end,
    {atomic, Result} =
        mnesia:transaction(
          fun () ->
                  RS = #s { mnesia_q_table = MnesiaQTable,
                            mnesia_p_table = MnesiaPTable,
                            mnesia_n_table = MnesiaNTable,
                            q = queue:new(),
                            next_seq_id = NextSeqId,
                            next_out_id = NextOutId,
                            txn_dict = dict:new() },
                  transactional_write_state(RS)
          end),
    rabbit_log:info(" -> ~p", [Result]),
    Result.

%%----------------------------------------------------------------------------
%% terminate/1 is called when the queue is terminating, to delete all
%% of its enqueued msgs. This function creates an Mnesia transaction
%% to run in, and therefore may not be called from inside another
%% Mnesia transaction.
%%
%% -spec(terminate/1 :: (state()) -> state()).

terminate(S = #s { mnesia_p_table = MnesiaPTable }) ->
    rabbit_log:info("terminate(~n ~p) ->", [S]),
    {atomic, Result} =
        mnesia:transaction(
          fun () ->
                  S1 = transactional_read_state(S),
                  internal_clear_table(MnesiaPTable),
                  RS = S1,
                  transactional_write_state(RS)
          end),
    rabbit_log:info(" -> ~p", [Result]),
    Result.

%%----------------------------------------------------------------------------
%% delete_and_terminate/1 is called when the queue is terminating, to
%% delete all of its enqueued msgs and pending acks. This function
%% creates an Mnesia transaction to run in, and therefore may not be
%% called from inside another Mnesia transaction.
%%
%% -spec(delete_and_terminate/1 :: (state()) -> state()).

delete_and_terminate(S = #s { mnesia_p_table = MnesiaPTable }) ->
    rabbit_log:info("delete_and_terminate(~n ~p) ->", [S]),
    {atomic, Result} =
        mnesia:transaction(
          fun () ->
                  S1 = transactional_read_state(S),
                  internal_clear_table(MnesiaPTable),
                  RS = S1 #s { q = queue:new() },
                  transactional_write_state(RS)
          end),
    rabbit_log:info(" -> ~p", [Result]),
    Result.

%%----------------------------------------------------------------------------
%% purge/1 does the same as terminate/1, but also returns the count of
%% msgs purged. This function creates an Mnesia transaction to run in,
%% and therefore may not be called from inside another Mnesia
%% transaction.
%%
%% -spec(purge/1 :: (state()) -> {purged_msg_count(), state()}).

purge(S) ->
    rabbit_log:info("purge(~n ~p) ->", [S]),
    {atomic, Result} =
        mnesia:transaction(
          fun () ->
                  S1 = #s { q = Q } = transactional_read_state(S),
                  RS = S1 #s { q = queue:new() },
                  {queue:len(Q), transactional_write_state(RS)}
          end),
    rabbit_log:info(" -> ~p", [Result]),
    Result.

%%----------------------------------------------------------------------------
%% publish/3 publishes a msg. This function creates an Mnesia
%% transaction to run in, and therefore may not be called from inside
%% another Mnesia transaction.
%%
%% -spec(publish/3 ::
%%         (rabbit_types:basic_message(),
%%          rabbit_types:message_properties(),
%%          state())
%%         -> state()).

publish(Msg, Props, S) ->
    rabbit_log:info("publish(~n ~p,~n ~p,~n ~p) ->", [Msg, Props, S]),
    {atomic, Result} =
        mnesia:transaction(
          fun () ->
                  S1 = transactional_read_state(S),
                  RS = publish_state(Msg, Props, false, S1),
                  transactional_write_state(RS)
          end),
    rabbit_log:info(" -> ~p", [Result]),
    Result.

%%----------------------------------------------------------------------------
%% publish_delivered/4 is called for any msg that has already been
%% passed straight out to a client because the queue is empty. We
%% update all state (e.g., next_seq_id) as if we had in fact handled
%% the msg. This function creates an Mnesia transaction to run in, and
%% therefore may not be called from inside another Mnesia transaction.
%%
%% -spec(publish_delivered/4 ::
%%         (ack_required(),
%%          rabbit_types:basic_message(),
%%          rabbit_types:message_properties(),
%%          state())
%%         -> {ack(), state()}).

publish_delivered(false, _, _, S) ->
    rabbit_log:info("publish_delivered(false, _, _,~n ~p) ->", [S]),
    Result = {blank_ack, S},
    rabbit_log:info(" -> ~p", [Result]),
    Result;
publish_delivered(true, Msg, Props, S) ->
    rabbit_log:info(
      "publish_delivered(true,~n ~p,~n ~p,~n ~p) ->", [Msg, Props, S]),
    {atomic, Result} =
        mnesia:transaction(
          fun () ->
                  S1 = #s { next_seq_id = SeqId, next_out_id = OutId } =
                      transactional_read_state(S),
                  RS = (record_pending_ack_state(
                       (m(Msg, SeqId, Props)) #m { is_delivered = true }, S1))
                      #s { next_seq_id = SeqId + 1, next_out_id = OutId + 1 },
                  {SeqId, transactional_write_state(RS)}
          end),
    rabbit_log:info(" -> ~p", [Result]),
    Result.

%%----------------------------------------------------------------------------
%% dropwhile/2 drops msgs from the head of the queue while the
%% supplied predicate returns true. This function creates an Mnesia
%% transaction to run in, and therefore may not be called from inside
%% another Mnesia transaction, and the supplied Pred may not call
%% another function that creates an Mnesia transaction.
%%
%% -spec(dropwhile/2 ::
%%         (fun ((rabbit_types:message_properties()) -> boolean()), state())
%%         -> state()).

dropwhile(Pred, S) ->
    rabbit_log:info("dropwhile(~n ~p,~n ~p) ->", [Pred, S]),
    {atomic, {_, Result}} =
        mnesia:transaction(
          fun () ->
                  S1 = transactional_read_state(S),
                  {Atom, RS} =
                      internal_dropwhile(Pred, S1),
                  {Atom, transactional_write_state(RS)}
          end),
    rabbit_log:info(" -> ~p", [Result]),
    Result.

%%----------------------------------------------------------------------------
%% fetch/2 produces the next msg. This function creates an Mnesia
%% transaction to run in, and therefore may not be called from inside
%% another Mnesia transaction.
%%
%% -spec(fetch/2 :: (ack_required(), state()) ->
%%                       {ok | fetch_result(), state()}).

fetch(AckRequired, S) ->
    rabbit_log:info("fetch(~n ~p,~n ~p) ->", [AckRequired, S]),
    {atomic, Result} =
        mnesia:transaction(
          fun () ->
                  S1 = transactional_read_state(S),
                  {DR, RS} =
                      internal_queue_out(
                        fun (M, Si) -> internal_fetch(AckRequired, M, Si) end,
                        S1),
                  {DR, transactional_write_state(RS)}
          end),
    rabbit_log:info(" -> ~p", [Result]),
    Result.

%%----------------------------------------------------------------------------
%% ack/2 acknowledges msgs names by SeqIds. Maps SeqIds to guids upon
%% return. This function creates an Mnesia transaction to run in, and
%% therefore may not be called from inside another Mnesia transaction.
%%
%% The following spec is wrong, as a blank_ack cannot be passed back in.
%%
%% -spec(ack/2 :: ([ack()], state()) -> {[rabbit_guid:guid()], state()}).

ack(SeqIds, S) ->
    rabbit_log:info("ack(~n ~p,~n ~p) ->", [SeqIds, S]),
    {atomic, Result} =
        mnesia:transaction(
          fun () ->
                  S1 = transactional_read_state(S),
                  {Guids, RS} = internal_ack(SeqIds, S1),
                  {Guids, transactional_write_state(RS)}
          end),
    rabbit_log:info(" -> ~p", [Result]),
    Result.

%%----------------------------------------------------------------------------
%% tx_publish/4 is a publish, but in the context of an AMQP
%% transaction. It stores the msg and its properties in the to_pub
%% field of the txn, waiting to be committed. This function creates an
%% Mnesia transaction to run in, and therefore may not be called from
%% inside another Mnesia transaction.
%%
%% -spec(tx_publish/4 ::
%%         (rabbit_types:txn(),
%%          rabbit_types:basic_message(),
%%          rabbit_types:message_properties(),
%%          state())
%%         -> state()).

tx_publish(Txn, Msg, Props, S) ->
    rabbit_log:info(
      "tx_publish(~n ~p,~n ~p,~n ~p,~n ~p) ->", [Txn, Msg, Props, S]),
    {atomic, Result} =
        mnesia:transaction(
          fun () ->
                  S1 = transactional_read_state(S),
                  Tx = #tx { to_pub = Pubs } = lookup_tx(Txn, S1),
                  RS = store_tx(Txn,
                                Tx #tx { to_pub = [{Msg, Props} | Pubs] },
                                S1),
                  transactional_write_state(RS)
          end),
    rabbit_log:info(" -> ~p", [Result]),
    Result.

%%----------------------------------------------------------------------------
%% tx_ack/3 acks, but in the context of an AMQP transaction. It stores
%% the seq_id in the acks field of the txn, waiting to be
%% committed. This function creates an Mnesia transaction to run in,
%% and therefore may not be called from inside another Mnesia
%% transaction.
%%
%% The following spec is wrong, as a blank_ack cannot be passed back in.
%%
%% -spec(tx_ack/3 :: (rabbit_types:txn(), [ack()], state()) -> state()).

tx_ack(Txn, SeqIds, S) ->
    rabbit_log:info("tx_ack(~n ~p,~n ~p,~n ~p) ->", [Txn, SeqIds, S]),
    {atomic, Result} =
        mnesia:transaction(
          fun () ->
                  S1 = transactional_read_state(S),
                  Tx = #tx { to_ack = SeqIds0 } = lookup_tx(Txn, S1),
                  RS = store_tx(Txn,
                                Tx #tx {
                                  to_ack = lists:append(SeqIds, SeqIds0) },
                                S1),
                  transactional_write_state(RS)
          end),
    rabbit_log:info(" -> ~p", [Result]),
    Result.

%%----------------------------------------------------------------------------
%% tx_rollback/2 undoes anything that has been done in the context of
%% the specified AMQP transaction. It returns the state with to_pub
%% and to_ack erased. This function creates an Mnesia transaction to
%% run in, and therefore may not be called from inside another Mnesia
%% transaction.
%%
%% The following spec is wrong, as a blank_ack cannot be passed back in.
%%
%% -spec(tx_rollback/2 :: (rabbit_types:txn(), state()) -> {[ack()], state()}).

tx_rollback(Txn, S) ->
    rabbit_log:info("tx_rollback(~n ~p,~n ~p) ->", [Txn, S]),
    {atomic, Result} =
        mnesia:transaction(
          fun () ->
                  S1 = transactional_read_state(S),
                  #tx { to_ack = SeqIds } = lookup_tx(Txn, S1),
                  RS = erase_tx(Txn, S),
                  {SeqIds, transactional_write_state(RS)}
          end),
    rabbit_log:info(" -> ~p", [Result]),
    Result.

%%----------------------------------------------------------------------------
%% tx_commit/4 commits an AMQP transaction. The F passed in must be
%% called once the msgs have really been commited. This CPS permits
%% the possibility of commit coalescing. This function creates an
%% Mnesia transaction to run in, and therefore may not be called from
%% inside another Mnesia transaction. However, the supplied F is
%% called outside the transaction.
%%
%% The following spec is wrong, as blank_acks cannot be returned.
%%
%% -spec(tx_commit/4 ::
%%         (rabbit_types:txn(),
%%          fun (() -> any()),
%%          message_properties_transformer(),
%%          state())
%%         -> {[ack()], state()}).

tx_commit(Txn, F, PropsF, S) ->
    rabbit_log:info(
      "tx_commit(~n ~p,~n ~p,~n ~p,~n ~p) ->", [Txn, F, PropsF, S]),
    {atomic, Result} =
        mnesia:transaction(
          fun () ->
                  S1 = transactional_read_state(S),
                  #tx { to_ack = SeqIds, to_pub = Pubs } = lookup_tx(Txn, S1),
                  RS =
                      tx_commit_state(Pubs, SeqIds, PropsF, erase_tx(Txn, S1)),
                  {SeqIds, transactional_write_state(RS)}
          end),
    F(),
    rabbit_log:info(" -> ~p", [Result]),
    Result.

%%----------------------------------------------------------------------------
%% requeue/3 reinserts msgs into the queue that have already been
%% delivered and were pending acknowledgement. This function creates
%% an Mnesia transaction to run in, and therefore may not be called
%% from inside another Mnesia transaction.
%%
%% The following spec is wrong, as blank_acks cannot be passed back in.
%%
%% -spec(requeue/3 ::
%%         ([ack()], message_properties_transformer(), state()) -> state()).

requeue(SeqIds, PropsF, S) ->
    rabbit_log:info("requeue(~n ~p,~n ~p,~n ~p) ->", [SeqIds, PropsF, S]),
    {atomic, Result} =
        mnesia:transaction(
          fun () ->
                  S1 = transactional_read_state(S),
                  {_, RS} =
                      internal_ack3(
                        fun (#m { msg = Msg, props = Props }, Si) ->
                                publish_state(Msg, PropsF(Props), true, Si)
                        end,
                        SeqIds,
                        S1),
                  transactional_write_state(RS)
          end),
    rabbit_log:info(" -> ~p", [Result]),
    Result.

%%----------------------------------------------------------------------------
%% len/1 returns the queue length. This function creates an Mnesia
%% transaction to run in, and therefore may not be called from inside
%% another Mnesia transaction.
%%
%% -spec(len/1 :: (state()) -> non_neg_integer()).

len(S) ->
    rabbit_log:info("len(~n ~p) ->", [S]),
    {atomic, Result} =
        mnesia:transaction(
          fun () ->
                  #s { q = Q } = transactional_read_state(S),
                  queue:len(Q)
          end),
    rabbit_log:info(" -> ~p", [Result]),
    Result.

%%----------------------------------------------------------------------------
%% is_empty/1 returns true if the queue is empty, and false
%% otherwise. This function creates an Mnesia transaction to run in,
%% and therefore may not be called from inside another Mnesia
%% transaction.
%%
%% -spec(is_empty/1 :: (state()) -> boolean()).

is_empty(S) ->
    rabbit_log:info("is_empty(~n ~p)", [S]),
    {atomic, Result} =
        mnesia:transaction(
          fun () ->
                  #s { q = Q } = transactional_read_state(S),
                  queue:is_empty(Q)
          end),
    rabbit_log:info(" -> ~p", [Result]),
    Result.

%%----------------------------------------------------------------------------
%% set_ram_duration_target states that the target is to have no more
%% msgs in RAM than indicated by the duration and the current queue
%% rates. It is ignored in this implementation.
%%
%% -spec(set_ram_duration_target/2 ::
%%         (('undefined' | 'infinity' | number()), state())
%%         -> state()).

set_ram_duration_target(_, S) -> S.

%%----------------------------------------------------------------------------
%% ram_duration/1 optionally recalculates the duration internally
%% (likely to be just update your internal rates), and report how many
%% seconds the msgs in RAM represent given the current rates of the
%% queue. It is a dummy in this implementation.
%%
%% -spec(ram_duration/1 :: (state()) -> {number(), state()}).

ram_duration(S) -> {0, S}.

%%----------------------------------------------------------------------------
%% needs_idle_timeout/1 returns true if idle_timeout should be called
%% as soon as the queue process can manage (either on an empty
%% mailbox, or when a timer fires), and false otherwise. It always
%% returns false in this implementation.
%%
%% -spec(needs_idle_timeout/1 :: (state()) -> boolean()).

needs_idle_timeout(_) -> false.

%%----------------------------------------------------------------------------
%% idle_timeout/1 is called (eventually) after needs_idle_timeout
%% returns true. It is a dummy in this implementation.
%%
%% -spec(idle_timeout/1 :: (state()) -> state()).

idle_timeout(S) -> S.

%%----------------------------------------------------------------------------
%% handle_pre_hibernate/1 is called immediately before the queue
%% hibernates. It is a dummy in this implementation.
%%
%% -spec(handle_pre_hibernate/1 :: (state()) -> state()).

handle_pre_hibernate(S) -> S.

%%----------------------------------------------------------------------------
%% status/1 exists for debugging and operational purposes, to be able
%% to expose state via rabbitmqctl. This function creates an Mnesia
%% transaction to run in, and therefore may not be called from inside
%% another Mnesia transaction.
%%
%% -spec(status/1 :: (state()) -> [{atom(), any()}]).

status(S = #s { mnesia_p_table = MnesiaPTable }) ->
    rabbit_log:info("status(~n ~p)", [S]),
    {atomic, Result} =
        mnesia:transaction(
          fun () ->
                  #s { q = Q, next_seq_id = NextSeqId } =
                      transactional_read_state(S),
                  LP = length(mnesia:all_keys(MnesiaPTable)),
                  [{len, queue:len(Q)}, {next_seq_id, NextSeqId}, {acks, LP}]
          end),
    rabbit_log:info(" -> ~p", [Result]),
    Result.

%%----------------------------------------------------------------------------
%% Monadic helper functions for inside transactions.
%% ----------------------------------------------------------------------------

-spec transactional_read_state(s()) -> s().

transactional_read_state(S) -> S.

-spec transactional_write_state(s()) -> s().

transactional_write_state(S = #s {
                            mnesia_q_table = MnesiaQTable,
                            mnesia_n_table = MnesiaNTable,
                            q = Q,
                            next_seq_id = NextSeqId,
                            next_out_id = NextOutId }) ->
    ok = mnesia:write(MnesiaQTable, #q_record { key = 'q', q = Q }, 'write'),
    ok = mnesia:write(MnesiaNTable,
                      #n_record { key = 'n',
                                  next_seq_id = NextSeqId,
                                  next_out_id = NextOutId },
                      'write'),
    S.

-spec record_pending_ack_state(m(), s()) -> s().

record_pending_ack_state(M = #m { seq_id = SeqId },
                         S = #s { mnesia_p_table = MnesiaPTable }) ->
    mnesia:write(MnesiaPTable, #p_record { seq_id = SeqId, m = M }, 'write'),
    S.

-spec internal_ack3(fun (([rabbit_guid:guid()], s()) -> s()),
                    [rabbit_guid:guid()],
                    s()) ->
                           {[rabbit_guid:guid()], s()}.

internal_ack3(F, SeqIds, S = #s { mnesia_p_table = MnesiaPTable }) ->
    {AllGuids, S1} =
        lists:foldl(
          fun (SeqId, {Acc, Si}) ->
                  [#p_record { m = M }] =
                      mnesia:read(MnesiaPTable, SeqId, 'read'),
                  mnesia:delete(MnesiaPTable, SeqId, 'write'),
                  {[m_guid(M) | Acc], F(M, Si)}
          end,
          {[], S},
          SeqIds),
    {lists:reverse(AllGuids), S1}.

-spec internal_fetch/3 :: (ack_required(), m(), s()) -> {fetch_result(), s()}.

internal_fetch(AckRequired,
               M = #m {
                 seq_id = SeqId,
                 msg = Msg,
                 is_delivered = IsDelivered },
               S = #s { q = Q }) ->
    {Ack, S1} =
        case AckRequired of
            true ->
                {SeqId,
                 record_pending_ack_state(
                   M #m { is_delivered = true }, S)};
            false -> {blank_ack, S}
        end,
    {{Msg, IsDelivered, Ack, queue:len(Q)}, S1}.

-spec(internal_ack/2 :: ([seq_id()], s()) -> {[rabbit_guid:guid()], s()}).

internal_ack(SeqIds, S) ->
    internal_ack3(fun (_, Si) -> Si end, SeqIds, S).

-spec(internal_dropwhile/2 ::
        (fun ((rabbit_types:message_properties()) -> boolean()), s())
        -> {empty | ok, s()}).

internal_dropwhile(Pred, S) ->
    internal_queue_out(
      fun (M = #m { props = Props }, Si = #s { q = Q }) ->
              case Pred(Props) of
                  true ->
                      {_, Si1} = internal_fetch(false, M, Si),
                      internal_dropwhile(Pred, Si1);
                  false -> {ok, Si #s {q = queue:in_r(M, Q) }}
              end
      end,
      S).

-spec tx_commit_state([rabbit_types:basic_message()],
                      [seq_id()],
                      message_properties_transformer(),
                      s()) ->
                             s().

tx_commit_state(Pubs, SeqIds, PropsF, S) ->
    {_, S1} = internal_ack(SeqIds, S),
    lists:foldl(
      fun ({Msg, Props}, Si) -> publish_state(Msg, Props, false, Si) end,
      S1,
      [{Msg, PropsF(Props)} || {Msg, Props} <- lists:reverse(Pubs)]).

%% Like mnesia:clear_table, but within a transaction.

%% BUG: The write-set of the transaction may be huge if the table is
%% huge.

-spec internal_clear_table(atom()) -> ok.

internal_clear_table(Table) ->
    case mnesia:first(Table) of
        '$end_of_table' -> ok;
        Key -> mnesia:delete(Table, Key, 'write'),
               internal_clear_table(Table)
        end.

-spec internal_queue_out(fun ((m(), s()) -> T), s()) -> {empty, s()} | T.

internal_queue_out(F, S = #s { q = Q }) ->
    case queue:out(Q) of
        {empty, _} -> {empty, S};
        {{value, M}, Qa} -> F(M, S #s { q = Qa })
    end.

%%----------------------------------------------------------------------------
%% Pure helper functions.
%% ----------------------------------------------------------------------------

-spec m(rabbit_types:basic_message(),
        seq_id(),
        rabbit_types:message_properties()) ->
               m().

m(Msg, SeqId, Props) ->
    #m { seq_id = SeqId, msg = Msg, props = Props, is_delivered = false }.

-spec lookup_tx(rabbit_types:txn(), s()) -> tx().

lookup_tx(Txn, #s { txn_dict = TxnDict }) ->
    case dict:find(Txn, TxnDict) of
        error -> #tx { to_pub = [], to_ack = [] };
        {ok, Tx} -> Tx
    end.

-spec store_tx(rabbit_types:txn(), tx(), s()) -> s().

store_tx(Txn, Tx, S = #s { txn_dict = TxnDict }) ->
    S #s { txn_dict = dict:store(Txn, Tx, TxnDict) }.

-spec erase_tx(rabbit_types:txn(), s()) -> s().

erase_tx(Txn, S = #s { txn_dict = TxnDict }) ->
    S #s { txn_dict = dict:erase(Txn, TxnDict) }.

-spec publish_state(rabbit_types:basic_message(),
                    rabbit_types:message_properties(),
                    boolean(),
                    s()) ->
                           s().

publish_state(Msg,
              Props,
              IsDelivered,
              S = #s { q = Q, next_seq_id = SeqId, next_out_id = OutId }) ->
    S #s {
      q = queue:in(
               (m(Msg, SeqId, Props)) #m { is_delivered = IsDelivered }, Q),
      next_seq_id = SeqId + 1,
      next_out_id = OutId + 1 }.

-spec m_guid(m()) -> rabbit_guid:guid().

m_guid(#m { msg = #basic_message { guid = Guid }}) -> Guid.

%% Convert a queue name (a record) into an Mnesia table name (an atom).

%% TODO: Import correct argument type.

-spec mnesia_tables(_) -> {atom(), atom(), atom()}.

mnesia_tables(QueueName) ->
    Str = lists:flatten(io_lib:format("~p", [QueueName])),
    {list_to_atom(lists:append("q: ", Str)),
     list_to_atom(lists:append("p: ", Str)),
     list_to_atom(lists:append("n: ", Str))}.
