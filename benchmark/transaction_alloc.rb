TOP_SRC_DIR = File.expand_path( File.join(File.dirname(__FILE__), '..') )
$LOAD_PATH.unshift TOP_SRC_DIR
$LOAD_PATH.unshift File.join(TOP_SRC_DIR, 'test')

require 'roby'
require 'roby/transactions'
require 'utilrb/objectstats'

include Roby

TASK_COUNT = 10
RELATION_COUNT = 10
def display_object_count
    count = ObjectStats.count_by_class.
	find_all { |k, o| k.name =~ /Roby/ }.
	sort_by { |k, o| k.name }.
	map { |k, o| "#{k} #{o}" }

    puts "  #{count.join("\n  ")}"
end

def build_and_commit
    plan = Plan.new
    trsc = Transaction.new(plan)

    # allocate TASK_COUNT proxies and tasks
    plan_tasks = (1..TASK_COUNT).map { plan.discover(t = Task.new); trsc[t] }
    trsc_tasks = (1..TASK_COUNT).map { trsc.discover(t = Task.new); t }

    arrays = [plan_tasks, trsc_tasks]
    relation_count = [0, 0]

    # Add random relations
    RELATION_COUNT.times do
	from_origin, to_origin = (1..2).map { rand(2) }
	from = arrays[from_origin][rand(TASK_COUNT)]
	to   = arrays[to_origin][rand(TASK_COUNT)]
	relation_count[from_origin] += 1
	relation_count[to_origin] += 1
	from.realized_by to
    end

    puts "#{TASK_COUNT} tasks, #{relation_count[0]} proxies and #{relation_count[1]} plain objects involved in relations"
    puts " Before commit"
    display_object_count
    trsc.commit_transaction
    puts " After commit"
    display_object_count
    plan.clear
end

100.times do
    GC.disable
    build_and_commit
    GC.enable
    GC.start
end

