$LOAD_PATH.unshift File.expand_path(File.join('..', 'lib'), File.dirname(__FILE__))
require 'roby/test/common'
require 'roby/test/tasks/simple_task'
require 'roby/state/information'
require 'flexmock'

class TC_Query < Test::Unit::TestCase
    include Roby::Test

    def check_matches_fullfill(task_model, plan, t0, t1, t2)
	result = TaskMatcher.new.enum_for(:each, plan).to_set
	assert_equal([t1, t2, t0].to_set, result)
	result = TaskMatcher.new.with_model(Roby::Task).enum_for(:each, plan).to_set
	assert_equal([t1, t2, t0].to_set, result, plan.task_index.by_model)

	result = TaskMatcher.which_fullfills(task_model).enum_for(:each, plan).to_set
	assert_equal([t1, t2].to_set, result)

	result = TaskMatcher.with_model(task_model).enum_for(:each, plan).to_set
	assert_equal([t1, t2].to_set, result)
	result = TaskMatcher.with_arguments(:value => 1).enum_for(:each, plan).to_set
	assert_equal([t0, t1].to_set, result)

	result = TaskMatcher.which_fullfills(task_model, :value => 1).enum_for(:each, plan).to_set
	assert_equal([t1].to_set, result)

	result = plan.find_tasks.which_fullfills(task_model, :value => 2).to_set
	assert_equal([t2].to_set, result)
	# Try the shortcut of find_tasks(model, args) for find_tasks.which_fullfills(model, args)
	result = plan.find_tasks(task_model, :value => 2).to_set
	assert_equal([t2].to_set, result)
	result = plan.find_tasks(task_model).to_set
	assert_equal([t1, t2].to_set, result)

	assert_marshallable(TaskMatcher.new.which_fullfills(task_model, :value => 2))
    end

    def test_match_task_fullfills
	task_model = Class.new(Task) do
	    argument :value
	end

	t0 = Roby::Task.new(:value => 1)
	t1 = task_model.new(:value => 1)
	t2 = task_model.new(:value => 2)

	plan.add_mission(t0)
	plan.add_mission(t1)
	plan.add_mission(t2)

	check_matches_fullfill(task_model, plan, t0, t1, t2)
    end

    def test_match_proxy_fullfills
	task_model = Class.new(Task) do
	    argument :value
	end

	t0 = Roby::Task.new(:value => 1)
	t1 = task_model.new(:value => 1)
	t2 = task_model.new(:value => 2)

	plan.add_mission(t0)
	plan.add_mission(t1)
	plan.add_mission(t2)

	trsc = Transaction.new(plan)
	check_matches_fullfill(task_model, trsc, trsc[t0], trsc[t1], trsc[t2])
    end

    def test_query_information
	t1 = Class.new(Task) do
	    needs :source_info
	    improves :other_info
	end.new
	t2 = Class.new(Task) do
	    needs :source_info
	    improves :yet_another_info
	end.new

	plan.discover [t1, t2]
	result = TaskMatcher.which_needs(:source_info).enum_for(:each, plan).to_set
	assert_equal([t1, t2].to_set, result)
	result = TaskMatcher.which_needs(:foo_bar).enum_for(:each, plan).to_set
	assert_equal(Set.new, result)
	result = TaskMatcher.which_improves(:foo_bar).enum_for(:each, plan).to_set
	assert_equal(Set.new, result)
	result = TaskMatcher.which_improves(:other_info).enum_for(:each, plan).to_set
	assert_equal([t1].to_set, result)
	result = TaskMatcher.which_needs(:source_info).
	    which_improves(:yet_another_info).
	    enum_for(:each, plan).to_set

	assert_equal([t2].to_set, result)
    end

    def assert_query_finds_tasks(task_set)
	assert_equal(task_set.to_set, yield.enum_for(:each).to_set)
    end

    def assert_finds_tasks(task_set, msg = "")
	assert_equal(task_set.to_set, yield.enum_for(:each, plan).to_set, msg)
    end

    def test_query_predicates
	t1 = Class.new(SimpleTask) { argument :fake }.new
	t2 = Roby::Task.new
	plan.discover [t1, t2]

	assert_finds_tasks([]) { TaskMatcher.executable }
	assert_finds_tasks([t1,t2]) { TaskMatcher.not_executable }
	assert_finds_tasks([t2]) { TaskMatcher.abstract }
	assert_finds_tasks([t1]) { TaskMatcher.partially_instanciated }
	assert_finds_tasks([t2]) { TaskMatcher.fully_instanciated }
	t1.arguments[:fake] = 2
	assert_finds_tasks([t1, t2]) { TaskMatcher.fully_instanciated }
	assert_finds_tasks([t2]) { TaskMatcher.fully_instanciated.abstract }

	assert_finds_tasks([t1, t2]) { TaskMatcher.pending }
	t1.start!
	assert_finds_tasks([t2]) { TaskMatcher.pending }
	assert_finds_tasks([t1, t2]) { TaskMatcher.not_failed }
	assert_finds_tasks([t1, t2]) { TaskMatcher.not_success }
	assert_finds_tasks([t1, t2]) { TaskMatcher.not_finished }

	assert_finds_tasks([t1]) { TaskMatcher.running }
	t1.success!
	assert_finds_tasks([t1], plan.task_index.by_state) { TaskMatcher.success }
	assert_finds_tasks([t1]) { TaskMatcher.finished }
	assert_finds_tasks([t1, t2]) { TaskMatcher.not_failed }
	assert_finds_tasks([t2]) { TaskMatcher.not_finished }

	plan.remove_object(t1)

	t1 = SimpleTask.new
	plan.discover(t1)
	t1.start!
	t1.failed!
	assert_finds_tasks([t1]) { TaskMatcher.failed }
	assert_finds_tasks([t1]) { TaskMatcher.finished }
	assert_finds_tasks([t1]) { TaskMatcher.finished.not_success }
    end

    def test_query_plan_predicates
	t1, t2, t3 = prepare_plan :missions => 1, :discover => 1, :tasks => 1
	plan.permanent(t3)
	assert_query_finds_tasks([t1]) { plan.find_tasks.mission }
	assert_query_finds_tasks([t2, t3]) { plan.find_tasks.not_mission }
	assert_query_finds_tasks([t3]) { plan.find_tasks.permanent }
	assert_query_finds_tasks([t1, t2]) { plan.find_tasks.not_permanent }
    end

    def test_negate
	t1 = Class.new(SimpleTask) { argument :id }.new(:id => 1)
	t2 = Class.new(SimpleTask) { argument :id }.new(:id => 2)
	t3 = Roby::Task.new
	plan.discover [t1, t2, t3]

	assert_finds_tasks([t3]) { (TaskMatcher.with_arguments(:id => 1) | TaskMatcher.with_arguments(:id => 2)).negate }
    end

    def test_or
	t1 = Class.new(SimpleTask) { argument :id }.new(:id => 1)
	t2 = Class.new(SimpleTask) { argument :id }.new(:id => 2)
	t3 = Roby::Task.new
	plan.discover [t1, t2, t3]

	assert_finds_tasks([t1, t2]) { TaskMatcher.with_arguments(:id => 1) | TaskMatcher.with_arguments(:id => 2) }
    end

    def test_and
	t1 = Class.new(SimpleTask) { argument :id }.new(:id => 1)
	t2 = Class.new(SimpleTask) { argument :id }.new(:id => 2)
	t3 = Roby::Task.new
	plan.discover [t1, t2, t3]

	assert_finds_tasks([t1, t2]) { TaskMatcher.fully_instanciated & TaskMatcher.executable }
	assert_finds_tasks([t1]) { (TaskMatcher.fully_instanciated & TaskMatcher.executable).with_arguments(:id => 1) }
	assert_finds_tasks([t3]) { TaskMatcher.fully_instanciated & TaskMatcher.abstract }
    end

    def test_merged_generated_subgraphs
	(d1, d2, d3, d4, d5, d6), t1 = prepare_plan :discover => 6, :tasks => 1

	trsc = Transaction.new(plan)
	d1.realized_by d2
	d2.realized_by d3
	d4.realized_by d5
	d5.realized_by d6

	# Add a new relation which connects two components. Beware that
	# modifying trsc[d3] and trsc[d4] makes d2 and d5 proxies to be
	# discovered
	trsc[d3].realized_by t1
	t1.realized_by trsc[d4]
	plan_set, trsc_set = trsc.merged_generated_subgraphs(TaskStructure::Hierarchy, [d1], [])
	assert_equal([trsc[d3], trsc[d4], t1].to_value_set, trsc_set)
	assert_equal([d1, d2, d5, d6].to_value_set, plan_set)
	
	# Remove the relation and check the result
	trsc[d3].remove_child t1
	plan_set, trsc_set = trsc.merged_generated_subgraphs(TaskStructure::Hierarchy, [d1], [])
	assert_equal([d1, d2].to_value_set, plan_set)
	assert_equal([trsc[d3]].to_value_set, trsc_set)
	plan_set, trsc_set = trsc.merged_generated_subgraphs(TaskStructure::Hierarchy, [], [t1])
	assert_equal([d5, d6].to_value_set, plan_set)
	assert_equal([t1, trsc[d4]].to_value_set, trsc_set)

	# Remove a plan relation inside the transaction, and check it is taken into account
	trsc[d2].remove_child trsc[d3]
	plan_set, trsc_set = trsc.merged_generated_subgraphs(TaskStructure::Hierarchy, [d1], [])
	assert_equal([d1].to_value_set, plan_set)
	assert_equal([trsc[d2]].to_value_set, trsc_set)
    end

    def test_roots
	(t1, t2, t3), (tr1, tr2, tr3) = prepare_plan :discover => 3, :tasks => 3
	trsc = Transaction.new(plan)
	[tr1, tr2, tr3].each { |t| trsc.discover(t) }

	assert_equal([t1, t2, t3].to_value_set, plan.find_tasks.roots(TaskStructure::Hierarchy).to_value_set)
	t1.realized_by t2
	assert_equal([t1, t3].to_value_set, plan.find_tasks.roots(TaskStructure::Hierarchy).to_value_set)

	tr1.realized_by tr2
	trsc[t3].realized_by tr3
	assert_equal([trsc[t1], trsc[t3], tr1].to_value_set, trsc.find_tasks.roots(TaskStructure::Hierarchy).to_value_set)
    end

    def test_transactions_simple
	model = Class.new(Roby::Task) do
	    argument :id
	end
	t1, t2, t3 = (1..3).map { |i| model.new(:id => i) }
	t1.realized_by t2
	plan.discover(t1)

	trsc = Transaction.new(plan)
	assert(trsc.find_tasks.which_fullfills(SimpleTask).to_a.empty?)
	assert(!trsc[t1, false])
	assert(!trsc[t2, false])
	assert(!trsc[t3, false])

	result = trsc.find_tasks.which_fullfills(model, :id => 1).to_a
	assert_equal([trsc[t1]], result)
	assert(!trsc[t2, false])
	assert(!trsc[t3, false])

	# Now that the proxy is in the transaction, check that it is still
	# found by the query
	result = trsc.find_tasks.which_fullfills(model, :id => 1).to_a
	assert_equal([trsc[t1]], result)

	trsc.discover(t3)
	result = trsc.find_tasks.which_fullfills(model, :id => 3).to_a
	assert_equal([t3], result)

	# Commit the transaction and check that the tasks are added to the plan
	# index
	trsc.commit_transaction
	result = plan.find_tasks.which_fullfills(model, :id => 3).to_a
	assert_equal([t3], result)
    end
end



