#! /usr/bin/env ruby
require 'roby'
require 'benchmark'
include Roby

TASK_COUNT  = 100
EVENT_COUNT = 50
RELATION_COUNT = 200

tasks  = (1..TASK_COUNT).map { Task.new }
events = (1..EVENT_COUNT).map { EventGenerator.new }

plan = Plan.new
tasks.each { |t| plan.permanent(t) }
plan.discover(events)

objects = tasks + events
RELATION_COUNT.times do
    parent = objects.random_element
    child  = objects.random_element
    next if parent == child

    if parent.kind_of?(EventGenerator)
	if !child.kind_of?(EventGenerator)
	    child = child.bound_events.random_element.last
	end
    elsif child.kind_of?(EventGenerator)
	parent = parent.bound_events.random_element.last
    end

    relation = if parent.kind_of?(EventGenerator)
		   EventStructure.relations.random_element
	       else
		   TaskStructure.relations.random_element
	       end

    begin
	parent.add_child_object(child, relation, success: [], failure: [])
    rescue CycleFoundError
    end
end

Benchmark.bm(15) do |bm|
    bm.report("unneeded_events") { plan.unneeded_events }
    bm.report("unneeded_tasks")  { plan.unneeded_tasks }
    bm.report("garbage_collect") { plan.garbage_collect }
end

