# frozen_string_literal: true

require "roby/test/self"

class TC_Dependency < Minitest::Test
    # Set to true to have the tests display the pretty-printed errors.
    DISPLAY_FORMATTED_ERRORS = false

    Dependency = TaskStructure::Dependency

    def dependency_graph
        plan.task_relation_graph_for(Dependency)
    end

    def test_check_structure_registration
        assert plan.structure_checks.include?(dependency_graph.method(:check_structure))
    end

    def assert_formatting_succeeds(object)
        message = Roby.format_exception(object)
        if DISPLAY_FORMATTED_ERRORS
            puts message.join("\n")
        end
    end

    def test_definition
        tag   = TaskService.new_submodel
        klass = Tasks::Simple.new_submodel do
            argument :id
            include tag
        end
        plan.add(t1 = Tasks::Simple.new)

        # Check validation of the model
        child = nil
        t1.depends_on((child = klass.new), model: Tasks::Simple)
        assert_equal([[Tasks::Simple], {}], t1[child, Dependency][:model])

        t1.depends_on klass.new, model: [Roby::Task, {}]
        t1.depends_on klass.new, model: tag

        plan.add(simple_task = Tasks::Simple.new)
        assert_raises(ArgumentError) { t1.depends_on simple_task, model: [Roby::Task.new_submodel, {}] }
        assert_raises(ArgumentError) { t1.depends_on simple_task, model: TaskService.new_submodel }

        # Check validation of the arguments
        plan.add(model_task = klass.new)
        assert_raises(ArgumentError) { t1.depends_on model_task, model: [Tasks::Simple, { id: "bad" }] }

        plan.add(child = klass.new(id: "good"))
        assert_raises(ArgumentError) { t1.depends_on child, model: [klass, { id: "bad" }] }
        t1.depends_on child, model: [klass, { id: "good" }]
        assert_equal([[klass], { id: "good" }], t1[child, Dependency][:model])

        # Check edge annotation
        t2 = Tasks::Simple.new
        t1.depends_on t2, model: Tasks::Simple
        assert_equal([[Tasks::Simple], {}], t1[t2, Dependency][:model])
        t2 = klass.new(id: 10)
        t1.depends_on t2, model: [klass, { id: 10 }]

        # Check the various allowed forms for :model
        expected = [[Tasks::Simple], { id: 10 }]
        t2 = Tasks::Simple.new(id: 10)
        t1.depends_on t2, model: [Tasks::Simple, { id: 10 }]
        assert_equal expected, t1[t2, Dependency][:model]
        t2 = Tasks::Simple.new(id: 10)
        t1.depends_on t2, model: Tasks::Simple
        assert_equal [[Tasks::Simple], {}], t1[t2, Dependency][:model]
        t2 = Tasks::Simple.new(id: 10)
        t1.depends_on t2, model: [[Tasks::Simple], { id: 10 }]
        assert_equal expected, t1[t2, Dependency][:model]
    end

    # This method is a common method used in the various error/nominal tests
    # below. It creates two tasks:
    #  p1 which is an instance of Tasks::Simple
    #  child which is an instance of a task model with two controllable events
    #  'first' and 'second'
    #
    # p1 is a parent of child. Both tasks are started and returned.
    def create_pair(options)
        do_start = options.delete(:start)
        if do_start.nil?
            do_start = true
        end

        child_model = Tasks::Simple.new_submodel do
            event :first, controlable: true
            event :second, controlable: true
        end

        p1 = Tasks::Simple.new
        child = child_model.new
        plan.add([p1, child])
        p1.depends_on child, options
        plan.add(p1)

        if do_start
            execute { child.start!; p1.start! }
        end
        [p1, child]
    end

    def assert_child_fails(child, reason, plan, &block)
        error = assert_raises(ChildFailedError, &block)
        assert_child_failed(child, error, reason.last, plan)
    end

    def assert_child_failed(child, error, reason, plan)
        result = plan.check_structure
        assert_equal(child, error.failed_task)
        assert_equal(reason, error.failure_point)
        assert_formatting_succeeds(error)
        error
    end

    def test_it_keeps_the_relation_on_success_if_remove_when_done_is_false
        parent, child = create_pair success: [:first],
                                    failure: [:stop],
                                    remove_when_done: false

        assert_equal({}, plan.check_structure)
        execute { child.first! }
        assert_equal({}, plan.check_structure)
        assert(parent.depends_on?(child))
    end

    def test_it_removes_the_relation_on_success_if_remove_when_done_is_true
        parent, child = create_pair success: [:first],
                                    failure: [:stop],
                                    remove_when_done: true

        execute { child.first! }
        assert_equal({}, plan.check_structure)
        assert(!parent.depends_on?(child))
    end

    def test_decision_control_can_ignore_failure_on_pending_relation
        FlexMock.use do |mock|
            decision_control = Roby::DecisionControl.new
            decision_control.singleton_class.class_eval do
                define_method(:pending_dependency_failed) do |parent, child, reason|
                    mock.decision_control_called
                    false
                end
            end

            plan.execution_engine.control = decision_control
            parent, child = create_pair success: [], failure: [:stop], start: false
            execute { child.start! }

            mock.should_receive(:decision_control_called).once

            execute { child.stop! }
            result = plan.check_structure
            assert(result.empty?)
        end
    end

    def test_implicit_fullfilled_model_does_not_include_a_singleton_class_if_the_object_has_one
        task_m = Roby::Task.new_submodel
        plan.add(task = task_m.new)
        assert_equal [task_m, Roby::Task], task.singleton_class.fullfilled_model
    end

    def test_fullfilled_model_determination_from_dependency_relation
        tag = TaskService.new_submodel
        klass = Tasks::Simple.new_submodel do
            include tag
        end

        p1, p2, child = prepare_plan add: 3, model: klass

        p1.depends_on child, model: [Tasks::Simple, { id: "discover-3" }]
        p2.depends_on child, model: Roby::Task
        assert_equal([[Tasks::Simple], { id: "discover-3" }], child.fullfilled_model)
        p1.remove_child(child)
        assert_equal([[Roby::Task], {}], child.fullfilled_model)
        p1.depends_on child, model: tag
        assert_equal([[Roby::Task, tag], {}], child.fullfilled_model)
        p2.remove_child(child)
        p2.depends_on child, model: [klass, { id: "discover-3" }]
        assert_equal([[klass, tag], { id: "discover-3" }], child.fullfilled_model)
    end

    def test_fullfilled_model_uses_model_fullfilled_model_for_its_default_value
        task_model = Roby::Task.new_submodel
        flexmock(task_model).should_receive(:fullfilled_model).and_return([Roby::Task, subtask = Roby::Task.new_submodel])
        plan.add(task = task_model.new)
        assert_equal [subtask], task.fullfilled_model[0]
    end

    def test_depends_on_ignores_delayed_arguments_when_computing_the_required_model
        task_m = Roby::Task.new_submodel { argument :arg }
        parent, child = prepare_plan add: 2, model: task_m
        child.arg = flexmock(evaluate_delayed_argument: nil)
        parent.depends_on child
        assert_equal({}, parent[child, Dependency][:model][1])
    end

    def test_explicit_fullfilled_model
        tag = TaskService.new_submodel
        klass = Tasks::Simple.new_submodel do
            include tag
        end
        t, p = prepare_plan add: 2, model: klass
        t.fullfilled_model = [Roby::Task, [], {}]
        assert_equal([[Roby::Task], {}], t.fullfilled_model)
        assert_equal([[Roby::Task], {}], t.fullfilled_model)
        t.fullfilled_model = [Roby::Task, [tag], {}]
        assert_equal([[Roby::Task, tag], {}], t.fullfilled_model)
        assert_equal([[Roby::Task, tag], {}], t.fullfilled_model)

        p.depends_on t, model: klass
        assert_equal([[klass, tag], {}], t.fullfilled_model)
        assert_equal([[klass, tag], {}], t.fullfilled_model)
    end

    def test_fullfilled_model_transaction
        tag = TaskService.new_submodel
        klass = Tasks::Simple.new_submodel do
            include tag
        end

        p1, p2, child = prepare_plan add: 3, model: klass.new_submodel
        trsc = Transaction.new(plan)

        p1.depends_on child, model: [Tasks::Simple, { id: "discover-3" }]
        p2.depends_on child, model: klass

        t_child = trsc[child]
        assert_equal([[klass], { id: "discover-3" }], t_child.fullfilled_model)
        t_p2 = trsc[p2]
        assert_equal([[klass], { id: "discover-3" }], t_child.fullfilled_model)
        t_p2.remove_child(t_child)
        assert_equal([[Tasks::Simple], { id: "discover-3" }], t_child.fullfilled_model)
        t_p2.depends_on t_child, model: klass
        assert_equal([[klass], { id: "discover-3" }], t_child.fullfilled_model)
        trsc.remove_task(t_p2)
        assert_equal([[klass], { id: "discover-3" }], t_child.fullfilled_model)
    ensure
        trsc&.discard_transaction
    end

    def test_first_children
        p, c1, c2 = prepare_plan add: 3, model: Tasks::Simple
        p.depends_on c1
        p.depends_on c2
        assert_equal([c1, c2].to_set, p.first_children)

        c1.start_event.signals c2.start_event
        assert_equal([c1].to_set, p.first_children)
    end

    def test_remove_finished_children
        p, c1, c2 = prepare_plan add: 3, model: Tasks::Simple
        plan.add_permanent_task(p)
        p.depends_on c1
        p.depends_on c2

        execute do
            p.start!
            c1.start!
            c1.success!
        end
        p.remove_finished_children
        refute p.depends_on?(c1)
        assert p.depends_on?(c2)
    end

    def test_role_definition
        plan.add(parent = Tasks::Simple.new)

        child = Tasks::Simple.new
        parent.depends_on child, role: "child1"
        assert_equal(["child1"].to_set, parent.roles_of(child))

        child = Tasks::Simple.new
        parent.depends_on child, roles: %w[child1 child2]
        assert_equal(%w[child1 child2].to_set, parent.roles_of(child))
    end

    def setup_merging_test(special_options = {})
        plan.add(parent = Tasks::Simple.new)
        tag = TaskService.new_submodel
        intermediate = Tasks::Simple.new_submodel
        intermediate.provides tag
        child_model = intermediate.new_submodel
        child = child_model.new(id: "child")

        options = { role: "child1", model: Task, failure: :start.never }
            .merge(special_options)
        parent.depends_on child, options

        expected_info = { consider_in_pending: true,
                          :remove_when_done => true,
                          model: [[Roby::Task], {}],
                          roles: ["child1"].to_set,
                          success: :success.to_unbound_task_predicate, failure: :start.never }.merge(special_options)
        assert_equal expected_info, parent[child, Dependency]

        [parent, child, expected_info, child_model, tag]
    end

    def test_merging_events
        parent, child, info, child_model, =
            setup_merging_test(success: :success.to_unbound_task_predicate, failure: false.to_unbound_task_predicate)

        parent.depends_on child, success: [:success]
        info[:model] = [[child_model], { id: "child" }]
        info[:success] = :success.to_unbound_task_predicate
        assert_equal info, parent[child, Dependency]

        parent.depends_on child, success: [:stop]
        info[:success] = info[:success].and(:stop.to_unbound_task_predicate)
        assert_equal info, parent[child, Dependency]

        parent.depends_on child, failure: [:stop]
        info[:failure] = :stop.to_unbound_task_predicate
        assert_equal info, parent[child, Dependency]
    end

    def test_merging_remove_when_done_cannot_change
        parent, child, info, = setup_merging_test
        assert_raises(ModelViolation) { parent.depends_on child, remove_when_done: false }
        parent.depends_on child, model: info[:model], remove_when_done: true, success: []
        assert_equal info, parent[child, Dependency]
    end

    def test_merging_models
        parent, child, info, child_model, tag = setup_merging_test

        # Test that models are "upgraded"
        parent.depends_on child, model: Tasks::Simple, success: []
        info[:model][0] = [Tasks::Simple]
        assert_equal info, parent[child, Dependency]
        parent.depends_on child, model: Roby::Task, remove_when_done: true, success: []
        assert_equal info, parent[child, Dependency]

        # Test that arguments are merged
        parent.depends_on child, model: [Tasks::Simple, { id: "child" }], success: []
        info[:model][1] = { id: "child" }
        assert_equal info, parent[child, Dependency]
        # NOTE: arguments can't be changed on the task *and* #depends_on
        # validates them, so we don't need to test that.

        # Test model/tag handling: #depends_on should find the most generic
        # model matching +task+ that includes all required models
        parent.depends_on child, model: tag, success: []
        info[:model][0] << tag
        assert_equal info, parent[child, Dependency]
    end

    def test_merge_dependency_options_uses_fullfills_to_determine_which_model_to_return
        root = flexmock(:<= => true)
        submodel = flexmock(:<= => true)
        root.should_receive(:fullfills?).with(submodel).and_return(false)
        submodel.should_receive(:fullfills?).with(root).and_return(true)
        opt1 = Hash[model: [[root], {}]]
        opt2 = Hash[model: [[submodel], {}]]
        result = Dependency.merge_dependency_options(opt1, opt2)
        assert_equal [[submodel], {}], result[:model]
    end

    def test_merge_dependency_options_raises_ArgumentError_if_the_models_are_not_related
        m1, m2 = flexmock(:<= => true), flexmock(:<= => true)
        m1.should_receive(:fullfills?).with(m2).and_return(false)
        m2.should_receive(:fullfills?).with(m1).and_return(false)
        opt1 = Hash[model: [[m1], {}]]
        opt2 = Hash[model: [[m2], {}]]
        assert_raises(Roby::ModelViolation) do
            Dependency.merge_dependency_options(opt1, opt2)
        end
    end

    def test_merging_roles
        parent, child, info, = setup_merging_test

        parent.depends_on child, model: Roby::Task, role: "child2", success: []
        info[:roles] << "child2"
        assert_equal info, parent[child, Dependency]
    end

    def test_role_paths
        t1, t2, t3, t4 = prepare_plan add: 4, model: Tasks::Simple

        t1.depends_on t2, role: "1"
        t2.depends_on t3, role: "2"

        assert_raises(ArgumentError) { t3.role_paths(t1) }
        assert_same nil, t3.role_paths(t1, false)

        assert_equal [%w[1 2]], t1.role_paths(t3)

        t4.depends_on t3, role: "4"
        assert_equal [%w[1 2]], t1.role_paths(t3)

        t1.depends_on t4, role: "3"
        assert_equal [%w[1 2], %w[3 4]].to_set, t1.role_paths(t3).to_set
    end

    def test_resolve_role_path
        t1, t2, t3, t4 = prepare_plan add: 4, model: Tasks::Simple

        t1.depends_on t2, role: "1"
        t2.depends_on t3, role: "2"

        assert_raises(ArgumentError) { t1.resolve_role_path(%w[1 4]) }
        assert_raises(ArgumentError) { t3.resolve_role_path(%w[1 4]) }

        assert_same t2, t1.resolve_role_path(["1"])
        assert_same t3, t1.resolve_role_path(%w[1 2])
    end

    def test_as_plan_handler
        model = Tasks::Simple.new_submodel
        flexmock(model).should_receive(:as_plan).and_return { model.new(id: 10) }
        task = prepare_plan add: 1, model: Tasks::Simple
        child = task.depends_on(model)
        assert_kind_of model, child
        assert_equal 10, child.arguments[:id]
    end

    def test_child_from_role_in_planless_tasks
        parent, child = Roby::Task.new, Roby::Task.new
        parent.depends_on(child, role: "child0")

        assert_equal child, parent.child_from_role("child0")
        assert_nil parent.find_child_from_role("nonexist")
        assert_raises(NoSuchChild) { parent.child_from_role("nonexist") }
    ensure
        plan.add(parent) if parent
    end

    def test_child_from_role
        parent, child = prepare_plan add: 2
        parent.depends_on(child, role: "child0")

        assert_equal child, parent.child_from_role("child0")
        assert_nil parent.find_child_from_role("nonexist")
        assert_raises(NoSuchChild) { parent.child_from_role("nonexist") }
    end

    def test_child_from_role_in_transaction
        parent, child0, child1 = prepare_plan add: 3
        parent.depends_on(child0, role: "child0")
        parent.depends_on(child1, role: "child1")
        info = parent[child0, TaskStructure::Dependency]

        plan.in_transaction do |trsc|
            parent = trsc[parent]

            child = parent.child_from_role("child0")
            assert_equal trsc[child], child

            assert_equal([[child, info]], parent.each_child.to_a)
        end
    end

    def test_each_fullfilled_model_returns_the_task_model_itself_by_default
        model = Roby::Task.new_submodel
        plan.add(task = model.new)
        assert_equal [model], task.each_fullfilled_model.to_a
    end

    def test_each_fullfilled_model_with_explicit_assignation_on_task_model
        model = Roby::Task.new_submodel
        tag = Roby::TaskService.new_submodel
        model.fullfilled_model = [Roby::Task, tag]
        assert_equal [Roby::Task, tag].to_set, model.each_fullfilled_model.to_set
    end

    def test_fullfilled_model_on_instance_with_explicit_assignation_on_task_model
        model = Roby::Task.new_submodel
        submodel = model.new_submodel
        tag = Roby::TaskService.new_submodel
        submodel.fullfilled_model = [model, tag]
        plan.add(task = submodel.new)
        assert_equal [[model, tag], {}], task.fullfilled_model
    end

    def test_merging_dependency_options_should_not_add_success_if_none_is_given
        options = Dependency.validate_options({})
        result = Dependency.merge_dependency_options(options, options)
        assert !result.has_key?(:success)
    end

    def test_merging_dependency_options_should_not_add_failure_if_none_is_given
        options = Dependency.validate_options({})
        result = Dependency.merge_dependency_options(options, options)
        assert !result.has_key?(:failure)
    end

    def test_direct_child_failure_due_to_grandchild_is_assigned_to_the_direct_child
        parent, child, grandchild = prepare_plan add: 3, model: Roby::Tasks::Simple
        plan.add(parent)
        plan.add(grandchild)
        parent.depends_on child, failure: :failed
        grandchild.stop_event.forward_to child.aborted_event

        expect_execution do
            parent.start!
            child.start!
            grandchild.start!
            grandchild.stop!
        end.to do
            have_error_matching ChildFailedError.match
                .with_origin(child)
                .to_execution_exception_matcher
                .with_trace(child => parent)
        end
    end

    def test_unreachability_child_failure_due_to_grandchild_is_assigned_to_the_direct_child
        parent, child, grandchild = prepare_plan add: 3, model: Roby::Tasks::Simple
        plan.add(parent)
        plan.add(grandchild)
        parent.depends_on child, failure: :start.never
        expect_execution do
            grandchild.start!
            parent.start!
            child.start_event.unreachable!(grandchild.start_event.last)
        end.to do
            have_error_matching ChildFailedError.match
                .with_origin(child.start_event)
                .to_execution_exception_matcher
                .with_trace(child => parent)
        end
    end
end

module Roby
    module TaskStructure
        describe Dependency do
            def dependency_graph
                plan.task_relation_graph_for(Dependency)
            end

            it "handles replacement of tasks with unset delayed arguments" do
                task_m = Roby::Task.new_submodel do
                    argument :arg
                end
                delayed_arg = flexmock(evaluate_delayed_argument: nil)
                plan.add(original = task_m.new(arg: delayed_arg))
                plan.add(replacing = task_m.new(arg: 10))
                plan.replace(original, replacing)
            end

            describe "#remove_roles" do
                attr_reader :parent
                attr_reader :child

                before do
                    plan.add(@parent = Roby::Task.new)
                    plan.add(@child  = Roby::Task.new)
                    parent.depends_on child, roles: %w[test1 test2]
                end

                it "removes the role" do
                    parent.remove_roles(child, "test1")
                    assert_equal ["test2"].to_set, parent.roles_of(child)
                end

                it "raises ArgumentError if the child does not have the expected role" do
                    assert_raises(ArgumentError) { parent.remove_roles(child, "foo") }
                end

                it "removes the child if the role set becomes empty and remove_child_when_empty is set" do
                    parent.remove_roles(child, "test1")
                    parent.remove_roles(child, "test2", remove_child_when_empty: true)
                    assert !parent.depends_on?(child)
                end

                it "does not remove the child if the role set becomes empty and remove_child_when_empty is not set" do
                    parent.remove_roles(child, "test1")
                    parent.remove_roles(child, "test2", remove_child_when_empty: false)
                    assert parent.depends_on?(child)
                end
            end

            describe ".merge_fullfilled_model" do
                let(:task_m) { Task.new_submodel }
                let(:target_tag_m) { TaskService.new_submodel }
                let(:source_tag_m) { TaskService.new_submodel }
                it "does not modify the target argument" do
                    target = [task_m, [target_tag_m], Hash[arg0: 10]]
                    Dependency.merge_fullfilled_model(target, [source_tag_m], Hash[arg1: 20])
                    assert_equal [task_m, [target_tag_m], Hash[arg0: 10]], target
                end
                it "picks the most specialized task model" do
                    target = [task_m, [target_tag_m], Hash[arg0: 10]]
                    subclass_m = task_m.new_submodel
                    merged = Dependency.merge_fullfilled_model(target, [subclass_m], Hash[])
                    assert_equal subclass_m, merged[0]
                    target[0] = subclass_m
                    merged = Dependency.merge_fullfilled_model(target, [task_m], Hash[])
                    assert_equal subclass_m, merged[0]
                end
                it "concatenates tags" do
                    target = [task_m, [target_tag_m], Hash[arg0: 10]]
                    merged = Dependency.merge_fullfilled_model(target, [source_tag_m], Hash[arg1: 20])
                    assert_equal [target_tag_m, source_tag_m], merged[1]
                end
                it "removes duplicate tags" do
                    target = [task_m, [target_tag_m], Hash[arg0: 10]]
                    merged = Dependency.merge_fullfilled_model(target, [target_tag_m], Hash[arg1: 20])
                    assert_equal [target_tag_m], merged[1]
                end
                it "merges the arguments" do
                    target = [task_m, [target_tag_m], Hash[arg0: 10]]
                    merged = Dependency.merge_fullfilled_model(target, [source_tag_m], Hash[arg1: 20])
                    assert_equal Hash[arg0: 10, arg1: 20], merged.last
                end
            end

            describe "#provided_models" do
                it "returns an explicitly set model if one is set" do
                    task_m = Task.new_submodel
                    sub_m  = task_m.new_submodel
                    task = sub_m.new
                    task.fullfilled_model = [task_m, [], {}]
                    assert_equal [task_m], task_m.new.provided_models
                end

                it "puts the task model first" do
                    task_m = Task.new_submodel
                    srv_m = TaskService.new_submodel
                    task_m.singleton_class.class_eval do
                        define_method :fullfilled_model do
                            [srv_m, task_m]
                        end
                    end
                    assert_equal [task_m, srv_m], task_m.new.provided_models
                end

                it "filters out services that the task model provides" do
                    task_m = Task.new_submodel
                    srv_m = TaskService.new_submodel
                    task_m.provides srv_m
                    task_m.singleton_class.class_eval do
                        define_method :fullfilled_model do
                            [srv_m, task_m]
                        end
                    end
                    assert_equal [task_m], task_m.new.provided_models
                end

                it "deals with a provided model set that has no class" do
                    task_m = Task.new_submodel
                    srv_m = TaskService.new_submodel
                    task_m.singleton_class.class_eval do
                        define_method :fullfilled_model do
                            [srv_m]
                        end
                    end
                    assert_equal [srv_m], task_m.new.provided_models
                end

                it "falls back on the models' fullfilled model" do
                    task_m = Task.new_submodel
                    sub_m  = task_m.new_submodel
                    sub_m.fullfilled_model = [task_m]
                    assert_equal [task_m], task_m.new.provided_models
                end
            end

            describe "interesting_events set" do
                def self.runs(context)
                    context.it "registers the start event of a parent" do
                        parent, child = create_parent_child do |parent, child|
                            parent.depends_on child, success: :start
                        end
                        flexmock(dependency_graph.interesting_events)
                            .should_receive(:<<).with(parent.start_event).at_least.once
                        flexmock(dependency_graph.interesting_events)
                            .should_receive(:<<)
                        execute { parent.start! }
                    end

                    context.it "registers an event emitted that is positively involved in a dependency" do
                        parent, child = create_parent_child do |parent, child|
                            parent.depends_on child, success: :start
                        end
                        flexmock(dependency_graph.interesting_events)
                            .should_receive(:<<).with(child.start_event).at_least.once
                        flexmock(dependency_graph.interesting_events)
                            .should_receive(:<<)
                        execute { child.start! }
                    end

                    context.it "registers an unreachable event that is positively involved in a dependency" do
                        parent, child = create_parent_child do |parent, child|
                            parent.depends_on child, success: :start
                        end
                        flexmock(dependency_graph.interesting_events)
                            .should_receive(:<<).with(child.start_event).at_least.once.pass_thru
                        flexmock(dependency_graph.interesting_events)
                            .should_receive(:<<)
                        expect_execution { child.failed_to_start!(nil) }
                            .to do
                                have_error_matching ChildFailedError.match
                                    .with_origin(child)
                                    .to_execution_exception_matcher
                                    .with_trace(child => parent)
                            end
                    end

                    context.it "registers an event emitted that is negatively involved in a dependency" do
                        parent, child = create_parent_child do |parent, child|
                            parent.depends_on child, failure: :start
                        end
                        flexmock(dependency_graph.interesting_events)
                            .should_receive(:<<).with(child.start_event).at_least.once.pass_thru
                        flexmock(dependency_graph.interesting_events)
                            .should_receive(:<<)
                        expect_execution { child.start! }
                            .to do
                                have_error_matching ChildFailedError.match
                                    .with_origin(child)
                                    .to_execution_exception_matcher
                                    .with_trace(child => parent)
                            end
                    end

                    context.it "removes a finalized event" do
                        parent, child = create_parent_child do |parent, child|
                            parent.depends_on child, success: :start
                        end
                        plan.add_mission_task(parent)
                        execute do
                            parent.start!
                            plan.remove_task(child)
                        end
                        assert dependency_graph.interesting_events.empty?
                    end

                    context.it "removes a failing finalized task" do
                        parent, child = create_parent_child do |parent, child|
                            parent.depends_on child, failure: :stop
                        end
                        plan.add_mission_task(parent)
                        execute do
                            parent.start!
                            child.start!
                        end

                        plan.on_exception ChildFailedError do
                            plan.remove_task(child)
                        end
                        execute { child.stop! }

                        assert dependency_graph.failing_tasks.empty?
                    end
                end

                describe "when adding the dependency within the plan" do
                    def create_parent_child
                        parent, child = prepare_plan add: 2, model: Tasks::Simple
                        yield(parent, child)
                        [parent, child]
                    end
                    runs(self)
                end
                describe "when adding the dependency outside the plan" do
                    def create_parent_child
                        parent, child = prepare_plan tasks: 2, model: Tasks::Simple
                        yield(parent, child)
                        plan.add(parent)
                        [parent, child]
                    end
                    runs(self)
                end
                describe "when adding the tasks and dependency within a transaction" do
                    def create_parent_child
                        parent, child = prepare_plan tasks: 2, model: Tasks::Simple
                        plan.in_transaction do |trsc|
                            trsc.add([parent, child])
                            yield(parent, child)
                            trsc.commit_transaction
                        end
                        [parent, child]
                    end
                    runs(self)
                end
                describe "when adding the dependency within a transaction" do
                    def create_parent_child
                        parent, child = prepare_plan add: 2, model: Tasks::Simple
                        plan.in_transaction do |trsc|
                            yield(trsc[parent], trsc[child])
                            trsc.commit_transaction
                        end
                        [parent, child]
                    end
                    runs(self)
                end
                describe "when updating an existing dependency" do
                    def create_parent_child
                        parent, child = prepare_plan add: 2, model: Tasks::Simple
                        parent.depends_on child, success: :stop
                        yield(parent, child)
                        [parent, child]
                    end
                    runs(self)
                end
            end

            describe "failure on pending relation" do
                attr_reader :parent, :child, :decision_control

                before do
                    @decision_control = flexmock
                    plan.execution_engine.control = @decision_control
                end

                def expect_pending_relation(**options)
                    plan.add(@parent = Tasks::Simple.new)
                    @parent.depends_on(@child = Tasks::Simple.new, failure: :stop, **options)
                    expect_execution do
                        child.start!
                        child.stop!
                    end
                end

                it "generates an error on failure events if the decision control object returns true" do
                    decision_control.should_receive(pending_dependency_failed: true).at_least.once
                    expect_pending_relation.to do
                        have_error_matching ChildFailedError.match
                            .with_origin(child)
                            .to_execution_exception_matcher
                            .with_trace(child => parent)
                    end
                end

                it "does not generate an error on failure events if the decision control object returns false" do
                    decision_control.should_receive(pending_dependency_failed: false).at_least.once
                    expect_pending_relation.to_run
                end

                it "does not generate an error on failure events if the relation was created with consider_in_pending: false" do
                    decision_control.should_receive(:pending_dependency_failed).never
                    expect_pending_relation(consider_in_pending: false).to_run
                end

                it "fails on parent startup if the relation's failure was ignored by the decision control" do
                    decision_control.should_receive(pending_dependency_failed: false).at_least.once
                    expect_pending_relation.to_run
                    expect_execution { parent.start! }
                        .to { have_error_matching ChildFailedError.match.with_origin(child.stop_event) }
                end
                it "fails on parent startup if the relation's failure was ignored with 'consider_in_pending'" do
                    expect_pending_relation(consider_in_pending: false).to_run
                    expect_execution { parent.start! }
                        .to { have_error_matching ChildFailedError.match.with_origin(child.stop_event) }
                end
            end

            describe "structure check" do
                attr_reader :parent, :child_m

                before do
                    plan.add(@parent = Tasks::Simple.new)
                    @child_m = Roby::Tasks::Simple.new_submodel do
                        event :intermediate
                    end
                    execute { parent.start! }
                end

                it "creates a ChildFailedError that points to the original exception if the failure is caused by one" do
                    error = Class.new(RuntimeError)
                    child_m.event(:start) { |context| raise error }
                    parent.depends_on(child = child_m.new(id: 10))

                    command_failed_matcher = CommandFailed.match
                        .with_origin(child.start_event)
                        .with_ruby_exception(error)

                    expect_execution { child.start! }
                        .to do
                            fail_to_start child, reason: command_failed_matcher
                            have_error_matching ChildFailedError.match.with_origin(child).with_original_exception(command_failed_matcher)
                        end
                end

                it "reports a ChildFailedError if a positive 'start' event becomes unreachable" do
                    parent.depends_on(child = Roby::Tasks::Simple.new, success: :start)
                    expect_execution { child.start_event.unreachable! }.to do
                        have_error_matching ChildFailedError.match
                            .with_origin(child.start_event)
                            .to_execution_exception_matcher
                            .with_trace(child => parent)
                    end
                end

                it "reports a ChildFailedError if a positive intermediate event becomes unreachable" do
                    parent.depends_on(child = child_m.new, success: :intermediate)
                    expect_execution { child.start!; child.stop_event.emit }.to do
                        have_error_matching ChildFailedError.match
                            .with_origin(child.stop_event)
                            .to_execution_exception_matcher
                            .with_trace(child => parent)
                    end
                end

                it "reports a ChildFailedError if an event listed in 'failure' is emitted" do
                    parent.depends_on(child = child_m.new, failure: :intermediate)
                    expect_execution { child.start!; child.intermediate_event.emit }.to do
                        have_error_matching ChildFailedError.match
                            .with_origin(child.intermediate_event)
                            .to_execution_exception_matcher
                            .with_trace(child => parent)
                    end
                end

                it "reports a ChildFailedError if adding a new dependency while a failure event was already emitted" do
                    plan.add(child = child_m.new)
                    execute { child.start! }
                    parent.depends_on(child, failure: :start)
                    expect_execution.to do
                        have_error_matching ChildFailedError.match
                            .with_origin(child.start_event)
                            .to_execution_exception_matcher
                            .with_trace(child => parent)
                    end
                end

                it "reports a ChildFailedError if adding a new dependency while the success event was already unreachable" do
                    plan.add(child = child_m.new)
                    execute do
                        child.start!
                        child.intermediate_event.unreachable!
                    end
                    parent.depends_on(child, success: :intermediate)
                    expect_execution.to do
                        have_error_matching ChildFailedError.match
                            .with_origin(child.intermediate_event)
                            .to_execution_exception_matcher
                            .with_trace(child => parent)
                    end
                end

                it "reports success if both a positive and negative events are emitted at the same time" do
                    parent.depends_on(child = child_m.new,
                                      success: :intermediate,
                                      failure: :stop)
                    execute { child.start! }
                    execute do
                        child.intermediate_event.emit
                        child.stop_event.emit
                    end
                end

                it "reports success if the positive event is emitted and becomes unreachable in the same cycle" do
                    parent.depends_on(child = child_m.new,
                                      success: :intermediate)
                    execute { child.start! }
                    execute do
                        child.intermediate_event.emit
                        child.stop_event.emit
                    end
                end
            end

            describe "pretty-printing ChildFailedError" do
                before do
                    parent_m = Roby::Task.new_submodel(name: "Parent") { terminates }
                    @child_m = Roby::Task.new_submodel(name: "Child") { terminates }
                    plan.add(@parent = parent_m.new)
                end
                it "pretty-prints when caused by the emission of an event" do
                    @parent.depends_on(@child = @child_m.new,
                                       role: "test", success: [], failure: [:stop])
                    execute do
                        @parent.start!
                        @child.start!
                    end
                    exception = expect_execution do
                        @child.success_event.emit
                    end.to { have_error_matching ChildFailedError }

                    stop_event = @child.stop_event.last
                    stop_to_s = "[#{Roby.format_time(stop_event.time)} "\
                        "@#{stop_event.propagation_id}]"
                    success_event = @child.success_event.last
                    success_to_s = "[#{Roby.format_time(success_event.time)} "\
                        "@#{success_event.propagation_id}]"
                    expected = <<~MESSAGE.chomp
                        Child<id:#{@child.droby_id.id}> finished
                          no arguments
                        child 'test' of Parent<id:#{@parent.droby_id.id}> running
                          no arguments

                        Child triggered the failure predicate '(never(start?)) || (stop?)': stop? is true
                          the following event has been emitted:
                          event 'stop' emitted at #{stop_to_s}
                            No context

                          The emission was caused by the following events
                          < event 'success' emitted at #{success_to_s}
                    MESSAGE
                    assert_pp expected, exception.exception
                end

                it "pretty-prints when caused by the unreachability of an event" do
                    @parent.depends_on(@child = @child_m.new,
                                       role: "test", success: [:start])
                    execute do
                        @parent.start!
                    end
                    exception = expect_execution do
                        @child.start_event.emit_failed
                    end.to { have_error_matching ChildFailedError }

                    expected = <<~MESSAGE.chomp
                        Child<id:#{@child.droby_id.id}> failed to start
                          no arguments
                        child 'test' of Parent<id:#{@parent.droby_id.id}> running
                          no arguments

                        success condition can no longer be reached 'start?': the value of start? will not change anymore
                          the following event is unreachable:
                          event 'start'

                          The unreachability was caused by
                            failed emission of the event 'start' of
                              Child<id:#{@child.droby_id.id}> failed to start
                                no arguments (Roby::EmissionFailed)
                    MESSAGE
                    assert_pp expected, exception.exception
                end
            end
        end
    end
end
