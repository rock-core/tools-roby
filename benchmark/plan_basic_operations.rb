require 'roby'
require 'benchmark'

require 'ruby-prof'

COUNT = 1000
Benchmark.bm(30) do |x|
    x.report("allocates #{COUNT} tasks") do
        COUNT.times { Roby::Task.new }
    end

    plan = Roby::Plan.new
    tasks = (1..COUNT).map { Roby::Task.new }
    x.report("adds #{COUNT} tasks") do
        tasks.each { |t| plan.add(t) }
    end

    plan = Roby::Plan.new
    tasks = (1..COUNT).map { Roby::Task.new }
    x.report("add 1 time #{COUNT} tasks") do
        plan.add(tasks)
    end

    x.report("remove 1 tasks #{tasks.size} times") do
        tasks.each { |t| plan.remove_object(t) }
    end
end

