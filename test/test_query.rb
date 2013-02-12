$LOAD_PATH.unshift File.expand_path(File.join('..', 'lib'), File.dirname(__FILE__))
require 'roby/test/common'
require 'roby/tasks/simple'
require 'roby/state/information'
require 'flexmock'

class TC_Query < Test::Unit::TestCase
    include Roby::SelfTest

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
	task_model = Task.new_submodel do
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

    def test_match_tag
        tag = TaskService.new_submodel
        tag.argument :id
	task_model = Tasks::Simple.new_submodel
        task_model.provides tag

        plan.add(task = task_model.new(:id => 3))
        assert(Task.match(tag)              === task)
        assert(Task.match(tag, :id => 3)    === task)
        assert(! (Task.match(tag, :id => 2) === task))

        plan.add(task = Tasks::Simple.new)
        assert(! (Task.match(tag)           === task))
        assert(! (Task.match(tag, :id => 3) === task))
        assert(! (Task.match(tag, :id => 2) === task))
    end

    def test_match_proxy_fullfills
	task_model = Task.new_submodel do
	    argument :value
	end

	t0 = Roby::Task.new(:value => 1)
	t1 = task_model.new(:value => 1)
	t2 = task_model.new(:value => 2)

	plan.add_mission(t0)
	plan.add_mission(t1)
	plan.add_mission(t2)

        plan.in_transaction do |trsc|
            check_matches_fullfill(task_model, trsc, trsc[t0], trsc[t1], trsc[t2])
        end
    end

    def assert_query_finds_tasks(task_set)
	assert_equal(task_set.to_set, yield.enum_for(:each).to_set)
    end

    def assert_finds_tasks(task_set, msg = "")
	assert_equal(task_set.to_set, yield.enum_for(:each, plan).to_set, msg)
    end

    def test_query_predicates
	t1 = Tasks::Simple.new_submodel { argument :fake }.new
	t2 = Roby::Task.new
	plan.add [t1, t2]

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

	t1 = Tasks::Simple.new
	plan.add(t1)
	t1.start!
	t1.failed!
	assert_finds_tasks([t1]) { TaskMatcher.failed }
	assert_finds_tasks([t1]) { TaskMatcher.finished }
	assert_finds_tasks([t1]) { TaskMatcher.finished.not_success }
    end

    def test_query_plan_predicates
	t1, t2, t3 = prepare_plan :missions => 1, :add => 1, :tasks => 1
	plan.add_permanent(t3)
	assert_query_finds_tasks([t1]) { plan.find_tasks.mission }
	assert_query_finds_tasks([t2, t3]) { plan.find_tasks.not_mission }
	assert_query_finds_tasks([t3]) { plan.find_tasks.permanent }
	assert_query_finds_tasks([t1, t2]) { plan.find_tasks.not_permanent }
    end

    def test_negate
	t1 = Tasks::Simple.new_submodel { argument :id }.new(:id => 1)
	t2 = Tasks::Simple.new_submodel { argument :id }.new(:id => 2)
	t3 = Roby::Task.new
	plan.add [t1, t2, t3]

	assert_finds_tasks([t3]) { (TaskMatcher.with_arguments(:id => 1) | TaskMatcher.with_arguments(:id => 2)).negate }
    end

    def test_or
	t1 = Tasks::Simple.new_submodel { argument :id }.new(:id => 1)
	t2 = Tasks::Simple.new_submodel { argument :id }.new(:id => 2)
	t3 = Roby::Task.new
	plan.add [t1, t2, t3]

	assert_finds_tasks([t1, t2]) { TaskMatcher.with_arguments(:id => 1) | TaskMatcher.with_arguments(:id => 2) }
    end

    def test_and
	t1 = Tasks::Simple.new_submodel { argument :id }.new(:id => 1)
	t2 = Tasks::Simple.new_submodel { argument :id }.new(:id => 2)
	t3 = Roby::Task.new
	plan.add [t1, t2, t3]

	assert_finds_tasks([t1, t2]) { TaskMatcher.fully_instanciated & TaskMatcher.executable }
	assert_finds_tasks([t1]) { (TaskMatcher.fully_instanciated & TaskMatcher.executable).with_arguments(:id => 1) }
	assert_finds_tasks([t3]) { TaskMatcher.fully_instanciated & TaskMatcher.abstract }
    end

    def test_merged_generated_subgraphs
	(d1, d2, d3, d4, d5, d6), t1 = prepare_plan :add => 6, :tasks => 1

        plan.in_transaction do |trsc|
            d1.depends_on d2
            d2.depends_on d3
            d4.depends_on d5
            d5.depends_on d6

            # Add a new relation which connects two components. Beware that
            # modifying trsc[d3] and trsc[d4] makes d2 and d5 proxies to be
            # discovered
            trsc[d3].depends_on t1
            t1.depends_on trsc[d4]
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
    end

    def test_roots
	(t1, t2, t3), (tr1, tr2, tr3) = prepare_plan :add => 3, :tasks => 3
        plan.in_transaction do |trsc|
            [tr1, tr2, tr3].each { |t| trsc.add(t) }

            assert_equal([t1, t2, t3].to_value_set, plan.find_tasks.roots(TaskStructure::Hierarchy).to_value_set)
            t1.depends_on t2
            assert_equal([t1, t3].to_value_set, plan.find_tasks.roots(TaskStructure::Hierarchy).to_value_set)

            tr1.depends_on tr2
            trsc[t3].depends_on tr3
            assert_equal([trsc[t1], trsc[t3], tr1].to_value_set, trsc.find_tasks.roots(TaskStructure::Hierarchy).to_value_set)
        end
    end

    def test_child_match
        plan.add(t1 = Tasks::Simple.new(:id => 1))
        t2 = Tasks::Simple.new_submodel.new(:id => '2')
        tag = TaskService.new_submodel do
            argument :tag_id
        end
        t3_model = Tasks::Simple.new_submodel
        t3_model.include tag
        t3 = t3_model.new(:id => 3, :tag_id => 3)
        t1.depends_on t2
        t2.depends_on t3
        t1.depends_on t3

        # t1    Tasks::Simple                   :id => 1
        # t2    t2_model < Tasks::Simple        :id => '2'
        # t3    t3_model < tag < Tasks::Simple  :id => 3
        # t1 -> t2 -> t3
        # t1 -> t3

        assert_equal(3, plan.find_tasks(t1.model).to_a.size)

        child_match = TaskMatcher.which_fullfills(Tasks::Simple, :id => 1)
        assert_equal([], plan.find_tasks(t1.model).
            with_child(child_match).to_a)

        assert_equal([t1, t2].to_set, plan.find_tasks(Tasks::Simple).
            with_child(Tasks::Simple).to_set)
        assert_equal([t1].to_set, plan.find_tasks(Tasks::Simple).
            with_child(Tasks::Simple, :id => '2').to_set)
        assert_equal([t1].to_set, plan.find_tasks(Tasks::Simple).
            with_child(t2.model).with_child(t3.model).to_set)
        assert_equal([t1, t2].to_set, plan.find_tasks(Tasks::Simple).
            with_child(t3.model).to_set)
        assert_equal([t1, t2].to_set, plan.find_tasks(Tasks::Simple).
            with_child(tag, :id => 3).to_set)
        # :id is not an argument of +tag+, so the following should match, but
        # the next one not.
        assert_equal([t1, t2].to_set, plan.find_tasks(Tasks::Simple).
            with_child(tag, :id => 2).to_set)
        assert_equal([].to_set, plan.find_tasks(Tasks::Simple).
            with_child(tag, :tag_id => 2).to_set)
        assert_equal([], plan.find_tasks(t1.model).
            with_child(Tasks::Simple, TaskStructure::PlannedBy).to_a)

        t1.planned_by t2
        assert_equal([t1], plan.find_tasks(t1.model).
            with_child(Tasks::Simple, TaskStructure::PlannedBy).to_a)
        assert_equal([t1], plan.find_tasks(t1.model).
            with_child(Tasks::Simple, :relation => TaskStructure::PlannedBy).to_a)
        assert_equal([], plan.find_tasks(t1.model).
            with_child(Tasks::Simple, :id => 42, :relation => TaskStructure::PlannedBy).to_a)
        assert_equal([], plan.find_tasks(t1.model).
            with_child(Tasks::Simple, TaskStructure::PlannedBy, :an_argument => :which_is_set).to_a)
        t1.remove_child_object(t2, TaskStructure::PlannedBy)

        child_match = TaskMatcher.which_fullfills(Tasks::Simple, :id => t2.arguments[:id])
        assert_equal([t1].to_set, plan.find_tasks(t1.model).
            with_child(child_match).to_set)
        assert_equal([], plan.find_tasks(t1.model).
            with_child(Tasks::Simple, TaskStructure::PlannedBy).to_a)
    end

    def test_child_in_transactions
	(t1, t2), t3 = prepare_plan :add => 2, :tasks => 1, :model => Tasks::Simple
        t1.depends_on t2
        plan.in_transaction do |trsc|
            trsc[t2].depends_on t3

            assert_equal(3, trsc.find_tasks(t1.model).to_a.size)
            child_match = TaskMatcher.which_fullfills(Tasks::Simple, :id => 1)
            assert_equal([], trsc.find_tasks(t1.model).
                with_child(child_match).to_a)

            child_match = TaskMatcher.which_fullfills(Tasks::Simple)
            assert_equal([trsc[t1], trsc[t2]].to_set, trsc.find_tasks(t1.model).
                with_child(child_match).to_set)

            child_match = TaskMatcher.which_fullfills(Tasks::Simple, :id => t2.arguments[:id])
            assert_equal([trsc[t1]].to_set, trsc.find_tasks(t1.model).
                with_child(child_match).to_set)
        end
    end

    def test_parent_match
        plan.add(t1 = Tasks::Simple.new(:id => 1))
        t2 = Tasks::Simple.new_submodel.new(:id => 2)
        t3 = Tasks::Simple.new_submodel.new(:id => 3)
        t3.depends_on t2
        t3.depends_on t1
        t2.depends_on t1

        assert_equal(3, plan.find_tasks(Tasks::Simple).to_a.size)

        parent_match = TaskMatcher.which_fullfills(Tasks::Simple, :id => 1)
        assert_equal([], plan.find_tasks(Tasks::Simple).
            with_parent(parent_match).to_a)

        assert_equal([t1, t2].to_set, plan.find_tasks(Tasks::Simple).
            with_parent(Tasks::Simple).to_set)
        assert_equal([t1].to_set, plan.find_tasks(Tasks::Simple).
            with_parent(t3.model).with_parent(t2.model).to_set)
        assert_equal([], plan.find_tasks(Tasks::Simple).
            with_parent(Tasks::Simple, TaskStructure::PlannedBy).to_a)
        t2.planned_by t1
        assert_equal([t1], plan.find_tasks(t1.model).
            with_parent(Tasks::Simple, TaskStructure::PlannedBy).to_a)
        assert_equal([t1], plan.find_tasks(t1.model).
            with_parent(Tasks::Simple, :relation => TaskStructure::PlannedBy).to_a)
        assert_equal([], plan.find_tasks(t1.model).
            with_parent(Tasks::Simple, :id => 42, :relation => TaskStructure::PlannedBy).to_a)
        assert_equal([], plan.find_tasks(t1.model).
            with_parent(Tasks::Simple, TaskStructure::PlannedBy, :an_argument => :which_is_set).to_a)
        t2.remove_child_object(t1, TaskStructure::PlannedBy)

        assert_equal([t1].to_set, plan.find_tasks(Tasks::Simple).
            with_parent(Tasks::Simple, :id => t2.arguments[:id]).to_set)
        assert_equal([], plan.find_tasks(Tasks::Simple).
            with_parent(Tasks::Simple, :id => t2.arguments[:id], :relation => TaskStructure::PlannedBy).to_a)
    end

    def test_parent_in_transaction
	(t1, t2), t3 = prepare_plan :add => 2, :tasks => 1, :model => Tasks::Simple
        t1.depends_on t2
        plan.in_transaction do |trsc|
            trsc[t2].depends_on t3

            assert_equal(3, trsc.find_tasks(Tasks::Simple).to_a.size)

            parent_match = TaskMatcher.which_fullfills(Tasks::Simple, :id => 1)
            assert_equal([], trsc.find_tasks(Tasks::Simple).
                with_parent(parent_match).to_a)

            parent_match = TaskMatcher.which_fullfills(Tasks::Simple)
            assert_equal([trsc[t2], t3].to_set, trsc.find_tasks(Tasks::Simple).
                with_parent(parent_match).to_set)

            parent_match = TaskMatcher.which_fullfills(Tasks::Simple, :id => t2.arguments[:id])
            assert_equal([t3].to_set, trsc.find_tasks(Tasks::Simple).
                with_parent(parent_match).to_set)
        end
    end

    def test_transactions_simple
	model = Roby::Task.new_submodel do
	    argument :id
	end
	t1, t2, t3 = (1..3).map { |i| model.new(:id => i) }
	t1.depends_on t2
	plan.add(t1)

        plan.in_transaction do |trsc|
            assert(trsc.find_tasks.which_fullfills(Tasks::Simple).to_a.empty?)
            assert(!trsc.include?(t1))
            assert(!trsc.include?(t2))
            assert(!trsc.include?(t3))

            result = trsc.find_tasks.which_fullfills(model, :id => 1).to_a
            assert_equal([trsc[t1]], result)
            assert(!trsc.include?(t2))
            assert(!trsc.include?(t3))

            # Now that the proxy is in the transaction, check that it is still
            # found by the query
            result = trsc.find_tasks.which_fullfills(model, :id => 1).to_a
            assert_equal([trsc[t1]], result)

            trsc.add(t3)
            result = trsc.find_tasks.which_fullfills(model, :id => 3).to_a
            assert_equal([t3], result)

            # Commit the transaction and check that the tasks are added to the plan
            # index
            trsc.commit_transaction
            result = plan.find_tasks.which_fullfills(model, :id => 3).to_a
            assert_equal([t3], result)
        end
    end
end



