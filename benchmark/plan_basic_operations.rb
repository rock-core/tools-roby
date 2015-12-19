require 'roby'
require 'benchmark'

basic_operations_count = 1000
Benchmark.bm(70) do |x|
    x.report("allocates #{basic_operations_count} tasks") do
        basic_operations_count.times { Roby::Task.new }
    end

    plan = Roby::Plan.new
    tasks = (1..basic_operations_count).map { Roby::Task.new }
    x.report("adds #{basic_operations_count} tasks") do
        tasks.each { |t| plan.add(t) }
    end

    plan = Roby::Plan.new
    tasks = (1..basic_operations_count).map { Roby::Task.new }
    x.report("add 1 time #{basic_operations_count} tasks") do
        plan.add(tasks)
    end

    x.report("remove 1 tasks #{tasks.size} times") do
        tasks.each { |t| plan.remove_object(t) }
    end
end

