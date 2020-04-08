# frozen_string_literal: true

TOP_SRC_DIR = File.expand_path(File.join(File.dirname(__FILE__), ".."))
$LOAD_PATH.unshift TOP_SRC_DIR
$LOAD_PATH.unshift File.join(TOP_SRC_DIR, "test")

require "roby"
require "roby/transactions"
require "utilrb/objectstats"

include Roby

TASK_COUNT = 10
RELATION_COUNT = 10
def display_object_count
    count = ObjectStats.count_by_class
        .find_all { |k, o| k.name =~ /Roby/ }
        .sort_by { |k, o| k.name }
        .map { |k, o| "#{k} #{o}" }

    puts "  #{count.join("\n  ")}"
end

def build_and_commit
    plan = Plan.new

    BenchmarkAllocation.bmbm(7) do |x|
        trsc = Transaction.new(plan)
        plan_tasks, trsc_tasks = nil
        x.report("alloc") do
            trsc_tasks = (1..TASK_COUNT).map { trsc.discover(t = Task.new); t }
            plan_tasks = (1..TASK_COUNT).map { plan.discover(t = Task.new); trsc[t] }
        end

        # Add random relations
        arrays = [plan_tasks, trsc_tasks]
        relation_count = [0, 0]

        from_origin, to_origin = (1..2).map { rand(2) }
        x.report("relations") do
            RELATION_COUNT.times do
                from = arrays[from_origin][rand(TASK_COUNT)]
                to   = arrays[to_origin][rand(TASK_COUNT)]
                relation_count[from_origin] += 1
                relation_count[to_origin] += 1
                begin
                    from.realized_by to
                rescue CycleFoundError
                end
            end
        end

        x.report("commit") do
            trsc.commit_transaction
        end
        x.report("clear") do
            plan.clear
        end
    end
end
build_and_commit
