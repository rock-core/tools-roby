require 'roby'
require 'benchmark'

def randomly_modify_plan(plan, num_tasks, num_relation_changes, num_mission_changes, commit: true)
    plan.in_transaction do |trsc|
        num_tasks = num_tasks / 10 * 10
        if plan.num_tasks < num_tasks
            (num_tasks - plan.num_tasks).times do
                trsc.add(Roby::Task.new)
            end
        end
        tasks = (plan.known_tasks.to_a + trsc.known_tasks.to_a)

        num_relation_changes.times do
            from_group, to_group = 0, 0
            while from_group == to_group
                from_group = rand(tasks.size / 10)
                to_group   = rand(tasks.size / 10)
            end
            if from_group > to_group
                from_group, to_group = to_group, from_group
            end
            from_i = from_group * 10 + rand(10)
            to_i   = to_group * 10 + rand(10)

            from = tasks[from_i]
            to   = tasks[to_i]

            if from.plan == to.plan && from.depends_on?(to)
                trsc[from].remove_child trsc[to]
            else
                trsc[from].depends_on trsc[to]
            end
        end

        # Unmark all missions
        all_missions = plan.missions.to_a + trsc.missions.to_a
        all_missions.each do |t|
            trsc.unmark_mission(trsc[t])
        end

        # And randomly mark mission_count tasks
        num_mission_changes.times do
            task = tasks[rand(tasks.size)]
            trsc.add_mission(trsc[task])
        end

        if commit
            trsc.commit_transaction
        end
    end
end

COUNT = 10
Benchmark.bm(30) do |x|
    num_tasks            = 100
    num_relation_changes = 500
    num_mission_changes  = 10

    x.report "modifies an executable plan using a transaction (#{COUNT} times)" do
        plan = Roby::ExecutablePlan.new
        Roby::ExecutionEngine.new(plan)

        COUNT.times do |i|
            randomly_modify_plan(plan, num_tasks, num_relation_changes, num_mission_changes, commit: false)
        end
    end

    x.report "modifies and commits an executable plan using a transaction (#{COUNT} times)" do
        plan = Roby::ExecutablePlan.new
        Roby::ExecutionEngine.new(plan)

        COUNT.times do |i|
            randomly_modify_plan(plan, num_tasks, num_relation_changes, num_mission_changes)
        end
    end
end


