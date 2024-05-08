# frozen_string_literal: true

require "roby"
require "roby/tasks/simple"
require "roby/droby/event_logger"
require "roby/droby/logfile/writer"

def pick_parent_child(set, group_size: 5)
    from_group, to_group = 0, 0
    while from_group == to_group
        from_group = rand(set.size / group_size)
        to_group   = rand(set.size / group_size)
    end
    if from_group > to_group
        from_group, to_group = to_group, from_group
    end
    from_i = (from_group * group_size) + rand(group_size)
    to_i   = (to_group * group_size) + rand(group_size)

    [set[from_i], set[to_i]]
end

def randomly_modify_plan(plan, num_tasks, num_task_relation_changes, num_event_relation_changes, num_mission_changes, commit: true)
    plan.in_transaction do |trsc|
        num_tasks = num_tasks / 10 * 10
        if plan.num_tasks < num_tasks
            (num_tasks - plan.num_tasks).times do
                trsc.add(Roby::Tasks::Simple.new)
            end
        end
        tasks = (plan.tasks.to_a + trsc.tasks.to_a)

        num_task_relation_changes.times do
            from, to = pick_parent_child(tasks)
            if from.plan == to.plan && from.depends_on?(to)
                trsc[from].remove_child trsc[to]
            else
                trsc[from].depends_on trsc[to]
            end
        end

        plan.task_events.to_a
        trsc.task_events.to_a
        num_event_relation_changes.times do
            from_task, to_task = pick_parent_child(tasks)
            from = from_task.bound_events.values[rand(from_task.bound_events.size)]
            to   = to_task.bound_events.values[rand(to_task.bound_events.size)]
            if from.plan == to.plan && from.child_object?(to, Roby::EventStructure::Forwarding)
                trsc[from].remove_forwarding trsc[to]
            else
                trsc[from].forward_to trsc[to]
            end
        end

        # Unmark all missions
        all_missions = plan.missions.to_a + trsc.missions.to_a
        all_missions.each do |t|
            trsc.unmark_mission_task(trsc[t])
        end

        # And randomly mark mission_count tasks
        num_mission_changes.times do
            task = tasks[rand(tasks.size)]
            trsc.add_mission_task(trsc[task])
        end

        if commit
            trsc.commit_transaction
        end
    end
end

plan = Roby::ExecutablePlan.new
execution_engine = Roby::ExecutionEngine.new(plan)
logfile_path = ARGV.first
event_io = File.open(logfile_path, "w")
logfile = Roby::DRoby::Logfile::Writer.new(event_io)
plan.event_logger = Roby::DRoby::EventLogger.new(logfile)

duration = 60
period = 1
num_tasks = 100
num_task_relation_changes = 10
num_event_relation_changes = 10
num_mission_changes = 5
event_emissions = 10

start_time = Time.now
execution_engine.every(period) do
    lifetime = Time.now - start_time
    if lifetime > duration
        execution_engine.quit
    else
        STDERR.puts lifetime
    end

    randomly_modify_plan(plan, num_tasks, num_task_relation_changes, num_event_relation_changes, num_mission_changes)

    event_emissions.times do
        task = plan.tasks.to_a[rand(plan.num_tasks)]
        next if task.finished?

        ev = task.bound_events.values[rand(task.bound_events.values.size)]
        if !task.running? && ev.symbol != :start
            task.start!
        elsif task.running? && ev.symbol == :start
            next
        end

        if ev.controlable?
            ev.call
        else
            ev.emit
        end
    end
end
execution_engine.event_loop
