# frozen_string_literal: true

require "roby"
require "benchmark"

def pick_index_in_group(group)
    (group * 10) + rand(10)
end

def pick_from_to(tasks)
    from_group = 0
    to_group = 0
    while from_group == to_group
        from_group = rand(tasks.size / 10)
        to_group   = rand(tasks.size / 10)
    end
    from_group, to_group = to_group, from_group if from_group > to_group
    from_i = pick_index_in_group(from_group)
    to_i   = pick_index_in_group(to_group)

    [tasks[from_i], tasks[to_i]]
end

def make_relation_change(tasks, trsc)
    from, to = pick_from_to(tasks)

    if from.plan == to.plan && from.depends_on?(to)
        trsc[from].remove_child trsc[to]
    else
        trsc[from].depends_on trsc[to]
    end
end

def adjust_plan_sizes(plan, trsc, num_tasks)
    num_tasks = num_tasks / 10 * 10
    if plan.num_tasks < num_tasks
        (num_tasks - plan.num_tasks).times do
            trsc.add(Roby::Task.new)
        end
    end
    (plan.tasks.to_a + trsc.tasks.to_a)
end

def make_mission_changes(plan, trsc, tasks, num_mission_changes)
    # Unmark all missions
    all_missions = plan.mission_tasks.to_a + trsc.mission_tasks.to_a
    all_missions.each do |t|
        trsc.unmark_mission_task(trsc[t])
    end

    # And randomly mark mission_count tasks
    num_mission_changes.times do
        task = tasks[rand(tasks.size)]
        trsc.add_mission_task(trsc[task])
    end
end

def randomly_modify_plan(
    plan, trsc, num_tasks, num_relation_changes, num_mission_changes
)
    tasks = adjust_plan_sizes(plan, trsc, num_tasks)

    num_relation_changes.times do
        make_relation_change(tasks, trsc)
    end
    make_mission_changes(plan, trsc, tasks, num_mission_changes)
end

COUNT = 10
Benchmark.bm(30) do |x|
    num_tasks            = 100
    num_relation_changes = 500
    num_mission_changes  = 10

    x.report "modifies an executable plan using a transaction (#{COUNT} times)" do
        plan = Roby::ExecutablePlan.new
        Roby::ExecutionEngine.new(plan)

        COUNT.times do
            plan.in_transaction do |trsc|
                randomly_modify_plan(
                    plan, trsc, num_tasks, num_relation_changes, num_mission_changes
                )
            end
        end
    end

    x.report "modifies and commits an executable plan " \
             "using a transaction (#{COUNT} times)" do
        plan = Roby::ExecutablePlan.new
        Roby::ExecutionEngine.new(plan)

        COUNT.times do
            plan.in_transaction do |trsc|
                randomly_modify_plan(
                    plan, trsc, num_tasks, num_relation_changes, num_mission_changes
                )
                trsc.commit_transaction
            end
        end
    end
end
