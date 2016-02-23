The Roby log file format uses Ruby's Marshal and Roby's own DRoby mechanisms to
save data to disk.

A log file starts with 

  ROBYLOG#{FORMAT_VERSION}#{OPTIONS}

FORMAT_VERSION is an integer encoded in little-endian 32-bit. This version is
incremented each time the format is changed in a backward-incompatible way.
When the log file format changes, newer ruby versions will require one to run
the roby-log upgrade command on older log files before they can be interpreted.

OPTIONS is a Hash marshalled using Ruby's Marshal facility and prefixed by the
size of the marshalled hash, in bytes, encoded as a little-endian 32-bit. This
hash contains the following keys:

  plugins: [String] the list of plugins loaded in the Roby instance

The rest of the file is a list of blocks. Each block is prefixed by its size
represented with a 32-bit unsigned integer. The rest of the block is a Ruby
array marshalled using Marshal.dump. The array contains a flat list of log
messages for one execution cycle. All cycles end with the same cycle_end message.

Each message is represented by 4 elements in the array

   mesage_name, time_seconds, time_microseconds, args

where message_name is an event name (listed below), Time is the time where the
message was queued for logging and 'args' are a list of message-specific
parameters

= Messages in Roby log format version 5

Only executable plans log operations that are performed on them. Transactions
and template plans are currently not logged.

A new ExecutablePlan registers itself on the logger with

    register_executable_plan plan_id

Where plan_id is ExecutablePlan#remote_id

Every plan object must be registered in an executable plan before it can be
referred to into other messages or objects. A plan object is registered through
the merged_plan hook, where the 'plan' parameter is a full dump of the task and
events that it contains.

After a merge_plan message, all further messages will refer to a plan object
through its #remote_id attribute.

    merged_plan(plan, merged_plan)

Plan modification hooks

    added_edge(parent, child, relations, info)
    updated_edge_info(parent, child, relation, info)
    removed_edge(parent, child, relations)
    notify_plan_status_change(task, status)
    garbage(object)
    finalized_task(plan, task)
    finalized_event(plan, event)
    task_arguments_updated(task, key, value)

Event propagation hooks:

    task_failed_to_start(task, reason)
    generator_fired(event)
    generator_emit_failed(generator, error)
    generator_propagate_event(is_forwarding, events, generator)
    generator_unreachable(generator, reason)
    exception_notification(plan_id, mode, error, involved_objects)
      mode == EXCEPTION_FATAL -> involved_objects Roby::Task
      mode == EXCEPTION_NONFATAL -> involved_objects Roby::Task
      mode == EXCEPTION_HANDLED -> involved_objects Roby::Task or Roby::Plan

Scheduler state:

    scheduler_report_pending_non_executable_task(msg, task, *args)
    scheduler_report_trigger(generator)
    scheduler_report_holdoff(msg, task, *args)

Cycle information. This message always ends one cycle of data, e.g. each entry
in a log file will end with this message

    cycle_end(info)

The info parameter is a Hash containing a list of statistics and general
information from the Roby ExecutionEngine. In addition, it contains the
following two logger-specific informations:

    pos: the position of this cycle in the file
    event_count: the number of log messages received during this cycle

The log file generated along a log file is simply a list of such cycle_end
messages.

