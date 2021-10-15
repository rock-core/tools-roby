# frozen_string_literal: true

require "roby/test/self"
require_relative "./behaviors/plan_common_behavior"
require_relative "./behaviors/plan_replace_behaviors"

module Roby
    describe Plan do
        include PlanCommonBehavior

        attr_reader :plan

        before do
            @plan = Plan.new
        end

        it "is the only element of its transaction stack" do
            assert_equal [plan], plan.transaction_stack
        end

        it "is root" do
            assert @plan.root_plan?
        end

        describe "#initialize" do
            it "instanciates graphs for all the relation graphs "\
               "registered on Roby::Task" do
                space = flexmock(instanciate: Hash[1 => 2])
                flexmock(Roby::Task)
                    .should_receive(:all_relation_spaces).and_return([space])
                plan = Roby::Plan.new
                assert_equal Hash[1 => 2], plan.task_relation_graphs
            end
            it "instanciates graphs for all the relation graphs "\
               "registered on Roby::Task's submodels" do
                root_space = flexmock(instanciate: Hash[1 => 2])
                submodel_space = flexmock(instanciate: Hash[41 => 42])
                task_m = Roby::Task.new_submodel
                flexmock(Roby::Task)
                    .should_receive(:all_relation_spaces)
                    .and_return([root_space, submodel_space])
                plan = Roby::Plan.new
                assert_equal Hash[1 => 2, 41 => 42], plan.task_relation_graphs
            end
            it "configures #task_relation_graphs to raise "\
               "if an invalid graph is being resolved" do
                space = flexmock
                flexmock(Roby::Task)
                    .should_receive(:all_relation_spaces).and_return([space])
                assert_raises(ArgumentError) do
                    plan.task_relation_graphs[invalid = flexmock]
                end
            end
            it "configures #task_relation_graphs to return nil "\
               "if nil is being resolved" do
                plan = Roby::Plan.new
                assert_nil plan.task_relation_graphs[nil]
            end

            it "instanciates graphs for all the relation graphs "\
               "registered on Roby::EventGenerator" do
                space = flexmock(instanciate: Hash[1 => 2])
                flexmock(Roby::EventGenerator)
                    .should_receive(:all_relation_spaces).and_return([space])
                plan = Roby::Plan.new
                assert_equal Hash[1 => 2], plan.event_relation_graphs
            end
            it "configures #event_relation_graphs to raise "\
               "if an invalid graph is being resolved" do
                space = flexmock
                flexmock(Roby::EventGenerator)
                    .should_receive(:all_relation_spaces).and_return([space])
                assert_raises(ArgumentError) do
                    plan.event_relation_graphs[invalid = flexmock]
                end
            end
            it "configures #task_relation_graphs to return nil if nil "\
               "is being resolved" do
                plan = Roby::Plan.new
                assert_nil plan.event_relation_graphs[nil]
            end
        end

        describe "#locally_useful_tasks" do
            before do
                @tasks = (1..10).map { Roby::Task.new }
                @tasks.each { |t| plan.add(t) }
            end

            it "computes the merge of all strong relation graphs "\
               "from locally useful roots" do
                @tasks[0].depends_on @tasks[1]
                @tasks[1].planned_by @tasks[2]
                @tasks[2].depends_on @tasks[3]
                @tasks[5].planned_by @tasks[6]
                @tasks[7].depends_on @tasks[8]
                flexmock(plan).should_receive(:locally_useful_roots)
                              .and_return(Set[@tasks[0], @tasks[5]])
                assert_equal [*@tasks[5, 2], *@tasks[0, 4]].to_set, plan.useful_tasks
            end

            it "passes the with_transactions flag to locally_useful_roots" do
                flexmock(plan).should_receive(:locally_useful_roots)
                              .with(with_transactions: (flag = flexmock))
                              .and_return(Set.new)
                plan.useful_tasks(with_transactions: flag)
            end

            it "ignores tasks for which the useful set is a dependency" do
                @tasks[0].depends_on @tasks[1]
                @tasks[1].planned_by @tasks[2]
                flexmock(plan).should_receive(:locally_useful_roots)
                              .and_return(Set[@tasks[1]])
                assert_equal @tasks[1, 2].to_set, plan.useful_tasks
            end

            it "returns standalone tasks" do
                flexmock(plan).should_receive(:locally_useful_roots)
                              .and_return(Set[@tasks[1]])
                assert_equal [@tasks[1]].to_set, plan.locally_useful_tasks
            end
        end

        describe "#useful_tasks" do
            before do
                @tasks = (1..10).map { Roby::Task.new }
                @tasks.each { |t| plan.add(t) }
            end

            it "computes the merge of all strong relation graphs "\
               "from locally useful roots" do
                @tasks[0].depends_on @tasks[1]
                @tasks[1].planned_by @tasks[2]
                @tasks[2].depends_on @tasks[3]
                @tasks[5].planned_by @tasks[6]
                @tasks[7].depends_on @tasks[8]
                flexmock(plan).should_receive(:locally_useful_roots)
                              .and_return(Set[@tasks[0], @tasks[5]])
                assert_equal [*@tasks[5, 2], *@tasks[0, 4]].to_set, plan.useful_tasks
            end

            it "passes the with_transactions flag to locally_useful_roots" do
                flexmock(plan).should_receive(:locally_useful_roots)
                              .with(with_transactions: (flag = flexmock))
                              .and_return(Set.new)
                plan.useful_tasks(with_transactions: flag)
            end

            it "ignores tasks for which the useful set is a dependency" do
                @tasks[0].depends_on @tasks[1]
                @tasks[1].planned_by @tasks[2]
                flexmock(plan).should_receive(:locally_useful_roots)
                              .and_return(Set[@tasks[1]])
                assert_equal @tasks[1, 2].to_set, plan.useful_tasks
            end

            it "returns standalone tasks" do
                flexmock(plan).should_receive(:locally_useful_roots)
                              .and_return(Set[@tasks[1]])
                assert_equal [@tasks[1]].to_set, plan.locally_useful_tasks
            end

            it "allows to explicitely pass tasks to be used as root "\
               "beyond locally_useful_roots" do
                flexmock(plan).should_receive(:locally_useful_roots)
                              .and_return(Set[])
                assert_equal [@tasks[1]].to_set,
                             plan.useful_tasks(additional_roots: Set[@tasks[1]])
            end
        end

        describe "#locally_useful_roots" do
            before do
                plan.add_mission_task(@mission = Task.new)
                plan.add_permanent_task(@permanent = Task.new)
                plan.add(@task = Task.new)
            end

            it "adds permanent and mission tasks" do
                assert_equal Set[@mission, @permanent], plan.locally_useful_roots
            end

            it "adds the proxied tasks if with_transactions is true" do
                plan.in_transaction do |trsc|
                    trsc[@task]
                    assert_equal Set[@mission, @permanent, @task],
                                 plan.locally_useful_roots
                end
            end

            it "does not add the proxied tasks if with_transactions is false" do
                plan.in_transaction do |trsc|
                    trsc[@task]
                    assert_equal Set[@mission, @permanent],
                                 plan.locally_useful_roots(with_transactions: false)
                end
            end
        end

        describe "#unneeded_tasks" do
            before do
                @tasks = (1..10).map { Roby::Task.new }
                @tasks.each { |t| plan.add(t) }
            end

            it "returns the set of tasks that are not useful" do
                flexmock(plan).should_receive(:useful_tasks)
                              .and_return([@tasks[0], @tasks[5], @tasks[7]])
                assert_equal (@tasks[1, 4] + @tasks[6, 1] + @tasks[8, 2]).to_set,
                             plan.unneeded_tasks
            end

            it "passes the additional roots to useful_tasks" do
                roots = [@tasks[0], @tasks[5], @tasks[7]]
                assert_equal (@tasks[1, 4] + @tasks[6, 1] + @tasks[8, 2]).to_set,
                             plan.unneeded_tasks(additional_useful_roots: roots)
            end
        end

        describe "#static_garbage_collect" do
            before do
                @tasks = (1..10).map { Roby::Task.new }
                @tasks.each { |t| plan.add(t) }
            end

            it "yields the unneeded tasks if a block is given" do
                flexmock(plan).should_receive(:useful_tasks)
                              .and_return([@tasks[0], @tasks[5], @tasks[7]])

                result = Set.new
                plan.static_garbage_collect { |t| result << t }
                assert_equal (@tasks[1, 4] + @tasks[6, 1] + @tasks[8, 2]).to_set,
                             result
            end

            it "allows to protect some tasks and their useful subnet" do
                roots = [@tasks[0], @tasks[5], @tasks[7]]
                plan.static_garbage_collect(protected_roots: roots)
                assert_equal roots.to_set, plan.tasks
            end
        end

        describe "#add_trigger" do
            attr_reader :task_m, :task, :recorder

            before do
                @task_m = Roby::Task.new_submodel
                @task   = task_m.new
                @recorder = flexmock
            end
            it "yields new tasks that match the given object" do
                recorder.should_receive(:called).once.with(task)
                plan.add_trigger task_m do |task|
                    recorder.called(task)
                end
                plan.add task
            end
            it "does not yield new tasks that do not match the given object" do
                recorder.should_receive(:called).never
                plan.add_trigger task_m.query.abstract do |task|
                    recorder.called(task)
                end
                plan.add task
            end
            it "yields tasks whose modifications within the transaction "\
               "created a match" do
                recorder.should_receive(:called).once.with(task)
                plan.add_trigger task_m.query.mission do |task|
                    recorder.called(task)
                end
                plan.add task
                plan.in_transaction do |trsc|
                    trsc.add_mission_task trsc[task]
                    trsc.commit_transaction
                end
            end
            it "yields tasks added by applying a transaction" do
                recorder.should_receive(:called).once.with(task)
                plan.add_trigger task_m do |task|
                    recorder.called(task)
                end
                plan.in_transaction do |trsc|
                    trsc.add task
                    trsc.commit_transaction
                end
            end
            it "yields matching tasks that already are in the plan" do
                recorder.should_receive(:called).once
                plan.add task
                plan.add_trigger task_m do |task|
                    recorder.called(task)
                end
            end
            it "does not yield not matching tasks that already are in the plan" do
                recorder.should_receive(:called).never
                plan.add task
                plan.add_trigger task_m.query.abstract do |task|
                    recorder.called(task)
                end
            end
        end

        describe "#remove_trigger" do
            attr_reader :task_m, :task, :recorder

            before do
                @task_m = Roby::Task.new_submodel
                @task   = task_m.new
                @recorder = flexmock
            end
            it "allows to remove a trigger added by #add_trigger" do
                trigger = plan.add_trigger task_m do |task|
                    recorder.called
                end
                plan.remove_trigger trigger
                recorder.should_receive(:called).never
                plan.add task
            end
        end

        describe "#compute_subplan_replacement" do
            attr_reader :graph

            before do
                @graph = Roby::Relations::Graph.new
            end
            it "moves relations for which the source is not a key in the task mapping" do
                plan.add(parent = Roby::Task.new)
                plan.add(source = Roby::Task.new)
                plan.add(target = Roby::Task.new)
                graph.add_edge(parent, source, info = flexmock)
                new, removed =
                    plan.compute_subplan_replacement(Hash[source => target], [graph])
                assert_equal [[graph, parent, target, info]], new
                assert_equal [[graph, parent, source]], removed
            end
            it "moves relations for which the target is not a key in the task mapping" do
                plan.add(source = Roby::Task.new)
                plan.add(child = Roby::Task.new)
                plan.add(target = Roby::Task.new)
                graph.add_edge(source, child, info = flexmock)
                new, removed =
                    plan.compute_subplan_replacement(Hash[source => target], [graph])
                assert_equal [[graph, target, child, info]], new
                assert_equal [[graph, source, child]], removed
            end
            it "ignores relations if both objects are within the mapping" do
                plan.add(parent = Roby::Task.new)
                plan.add(parent_target = Roby::Task.new)
                plan.add(child = Roby::Task.new)
                plan.add(child_target = Roby::Task.new)
                graph.add_edge(parent, child, flexmock)
                new, removed = plan.compute_subplan_replacement(
                    Hash[parent => parent_target, child => child_target], [graph]
                )
                assert_equal [], new
                assert_equal [], removed
            end
            it "ignores relations involving parents that are not mapped" do
                plan.add(root = Roby::Task.new)
                plan.add(parent = Roby::Task.new)
                plan.add(child = Roby::Task.new)
                plan.add(child_target = Roby::Task.new)
                graph.add_edge(root, parent, flexmock)
                graph.add_edge(parent, child, flexmock)
                new, removed = plan.compute_subplan_replacement(
                    Hash[parent => nil, child => child_target], [graph]
                )
                assert_equal [], new
                assert_equal [], removed
            end
            it "accept a resolver object" do
                plan.add(parent = Roby::Task.new)
                plan.add(child = Roby::Task.new)
                plan.add(child_target = Roby::Task.new)
                graph.add_edge(parent, child, info = flexmock)
                mapping = Hash[child => child_target]
                resolver = ->(t) { mapping[t] }
                new, removed = plan.compute_subplan_replacement(
                    Hash[child => [nil, resolver]], [graph])
                assert_equal [[graph, parent, child_target, info]], new
                assert_equal [[graph, parent, child]], removed
            end
            it "ignores child objects if child_objects is false" do
                plan.add(parent = Roby::Task.new)
                plan.add(child = Roby::Task.new)
                plan.add(parent_target = Roby::Task.new)
                graph.add_edge(parent, child, flexmock)
                new, removed = plan.compute_subplan_replacement(
                    Hash[parent => parent_target], [graph], child_objects: false)
                assert_equal [], new
                assert_equal [], removed
            end
            it "ignores strong relations" do
                plan.add(parent = Roby::Task.new)
                plan.add(source = Roby::Task.new)
                plan.add(target = Roby::Task.new)
                graph = Roby::Relations::Graph.new(strong: true)
                graph.add_edge(parent, source, info = flexmock)
                new, removed =
                    plan.compute_subplan_replacement(Hash[source => target], [graph])
                assert_equal [], new
                assert_equal [], removed
            end
            it "copies relations instead of moving them "\
               "if the graph is copy_on_replace" do
                plan.add(parent = Roby::Task.new)
                plan.add(source = Roby::Task.new)
                plan.add(target = Roby::Task.new)
                graph = Roby::Relations::Graph.new(copy_on_replace: true)
                graph.add_edge(parent, source, info = flexmock)
                new, removed =
                    plan.compute_subplan_replacement(Hash[source => target], [graph])
                assert_equal [[graph, parent, target, info]], new
                assert_equal [], removed
            end
        end

        describe "#unneeded_events" do
            it "returns free events that are connected to nothing" do
                plan.add(ev = Roby::EventGenerator.new)
                assert_equal [ev].to_set, plan.unneeded_events.to_set
            end
            it "does not return free events that are reachable from a permanent event" do
                plan.add_permanent_event(ev = Roby::EventGenerator.new)
                assert plan.unneeded_events.empty?
            end
            it "does not return free events that are reachable from a task event" do
                plan.add(t = Roby::Task.new)
                ev = Roby::EventGenerator.new
                t.start_event.forward_to ev
                assert plan.unneeded_events.empty?
            end
            it "does not return free events that can reach a task event" do
                plan.add(t = Roby::Task.new)
                ev = Roby::EventGenerator.new
                ev.forward_to t.start_event
                assert plan.unneeded_events.empty?
            end
            it "does not return free events while they are used in a transaction" do
                plan.add(ev = Roby::EventGenerator.new)
                plan.in_transaction do |trsc|
                    trsc[ev]
                    assert plan.unneeded_events.empty?
                end
                assert_equal [ev], plan.unneeded_events.to_a
            end
        end

        describe "deep_copy" do
            before do
                @parent, @child, @planner =
                    prepare_plan add: 3, model: Roby::Tasks::Simple
                plan.add(@ev = Roby::EventGenerator.new)

                @child.success_event.forward_to @ev
                @parent.depends_on @child
                @child.planned_by @planner
            end

            it "copies the plan objects and their structure" do
                copy, mappings = plan.deep_copy
                assert_equal (@plan.tasks | @plan.free_events | @plan.task_events),
                             mappings.keys.to_set
                assert plan.same_plan?(copy, mappings)
            end

            it "copies a task's mission status" do
                plan.add_mission_task(@parent)
                copy, mappings = plan.deep_copy
                task_copy = mappings[@parent]
                assert task_copy.mission?
                assert copy.mission_task?(task_copy)
            end

            it "copies a task's permanent status" do
                plan.add_permanent_task(@parent)
                copy, mappings = plan.deep_copy
                task_copy = mappings[@parent]
                assert copy.permanent_task?(task_copy)
            end

            it "copies an event's permanent status" do
                plan.add_permanent_event(@ev)
                copy, mappings = plan.deep_copy
                ev_copy = mappings[@ev]
                assert copy.permanent_event?(ev_copy)
            end
        end

        describe "#useful_events" do
            it "considers standalone events as not useful" do
                plan.add(parent = EventGenerator.new(true))
                plan.add(child = EventGenerator.new(true))
                parent.signals child
                assert plan.useful_events.empty?
            end
            it "considers permanent events useful" do
                plan.add_permanent_event(ev = EventGenerator.new(true))
                assert_equal [ev], plan.useful_events.to_a
            end
            it "considers events parent of permanent events as useful" do
                plan.add(parent = EventGenerator.new(true))
                plan.add_permanent_event(child = EventGenerator.new(true))
                parent.signals child
                assert [parent, child].to_set, plan.useful_events.to_set
            end
            it "considers events parent of task events as useful" do
                plan.add(parent = EventGenerator.new(true))
                plan.add(task = Roby::Task.new)
                parent.forward_to task.start_event
                assert [parent].to_set, plan.useful_events.to_set
            end
            it "considers events children of permanent events as useful" do
                plan.add_permanent_event(parent = EventGenerator.new(true))
                plan.add(child = EventGenerator.new(true))
                parent.signals child
                assert [parent, child].to_set, plan.useful_events.to_set
            end
            it "considers events children of task events as useful" do
                plan.add(child = EventGenerator.new(true))
                plan.add(task = Roby::Task.new)
                task.start_event.forward_to child
                assert [child].to_set, plan.useful_events.to_set
            end
            it "considers any event linked to another useful event useful" do
                plan.add_permanent_event(parent_1 = EventGenerator.new)
                plan.add(parent_2 = EventGenerator.new)
                plan.add(aggregator = EventGenerator.new)
                parent_1.forward_to aggregator
                parent_2.forward_to aggregator
                assert [parent_1, parent_2, aggregator].to_set, plan.useful_events.to_set
            end
        end

        describe "#same_plan?" do
            attr_reader :plan, :copy

            before do
                @plan = Plan.new
                @copy = Plan.new
            end

            def prepare_mappings(mappings)
                task_event_mappings = {}
                mappings.each do |original, copy|
                    if original.respond_to?(:each_event)
                        original.each_event do |ev|
                            task_event_mappings[ev] = copy.event(ev.symbol)
                        end
                    end
                end
                task_event_mappings.merge(mappings)
            end

            it "returns true on two empty plans" do
                plan.same_plan?(copy, {})
            end

            it "returns true on a plan with a single task" do
                plan.add(task = Task.new)
                copy.add(task_copy = Task.new)
                mappings = prepare_mappings(task => task_copy)
                assert plan.same_plan?(copy, mappings)
            end

            it "returns true on a plan with a single event" do
                plan.add(event = EventGenerator.new)
                copy.add(event_copy = EventGenerator.new)
                mappings = prepare_mappings(event => event_copy)
                assert plan.same_plan?(copy, mappings)
            end

            it "returns true on a plan with identical task relations" do
                plan.add(task_parent = Task.new)
                task_parent.depends_on(task_child = Task.new)
                copy.add(task_parent_copy = Task.new)
                task_parent_copy.depends_on(task_child_copy = Task.new)
                mappings = prepare_mappings(
                    task_parent => task_parent_copy, task_child => task_child_copy
                )
                assert plan.same_plan?(copy, mappings)
            end

            it "returns false for a plan with differing task relations" do
                plan.add(task_parent = Task.new)
                task_parent.depends_on(task_child = Task.new)
                copy.add(task_parent_copy = Task.new)
                copy.add(task_child_copy = Task.new)
                mappings = prepare_mappings(
                    task_parent => task_parent_copy, task_child => task_child_copy
                )
                assert !plan.same_plan?(copy, mappings)
            end

            it "returns false for a plan with a missing task" do
                plan.add(task = Task.new)
                assert !plan.same_plan?(copy, {})
            end

            it "returns false if the plans mission sets differ" do
                plan.add_mission_task(task = Task.new)
                copy.add(task_copy = Task.new)
                mappings = prepare_mappings(task => task_copy)
                assert !plan.same_plan?(copy, mappings)
            end

            it "returns false if the plans permanent tasks differ" do
                plan.add_permanent_task(task = Task.new)
                copy.add(task_copy = Task.new)
                mappings = prepare_mappings(task => task_copy)
                assert !plan.same_plan?(copy, mappings)
            end

            it "returns false if the plans permanent events differ" do
                plan.add_permanent_event(event = EventGenerator.new)
                copy.add(event_copy = EventGenerator.new)
                mappings = prepare_mappings(event => event_copy)
                assert !plan.same_plan?(copy, mappings)
            end

            it "returns true on a plan with identical event relations" do
                plan.add(event_parent = EventGenerator.new)
                event_parent.add_signal(event_child = EventGenerator.new)
                copy.add(event_parent_copy = EventGenerator.new)
                event_parent_copy.add_signal(event_child_copy = EventGenerator.new)
                mappings = prepare_mappings(
                    event_parent => event_parent_copy, event_child => event_child_copy
                )
                assert plan.same_plan?(copy, mappings)
            end

            it "returns false on a plan with differing event relations" do
                plan.add(event_parent = EventGenerator.new)
                event_parent.add_signal(event_child = EventGenerator.new)
                copy.add(event_parent_copy = EventGenerator.new)
                copy.add(event_child_copy = EventGenerator.new)
                mappings = prepare_mappings(
                    event_parent => event_parent_copy, event_child => event_child_copy
                )
                assert !plan.same_plan?(copy, mappings)
            end

            it "returns false on a plan with differing task event relations" do
                plan.add(task_parent = Task.new)
                plan.add(task_child = Task.new)
                copy.add(task_parent_copy = Task.new)
                copy.add(task_child_copy = Task.new)
                task_parent.start_event.forward_to task_child.start_event
                mappings = prepare_mappings(
                    task_parent => task_parent_copy, task_child => task_child_copy
                )
                assert !plan.same_plan?(copy, mappings)
            end
        end

        describe "#replace_task" do
            before do
                plan.add(@task = Roby::Task.new)
                plan.add(@replaced_task = Roby::Task.new)
                plan.add(@replacing_task = Roby::Task.new)
            end

            PlanReplaceBehaviors.in_plan_context(self, :replace_task)
            PlanReplaceBehaviors.replace_task(self)
        end

        describe "#replace" do
            before do
                plan.add(@task = Roby::Task.new)
                plan.add(@replaced_task = Roby::Task.new)
                plan.add(@replacing_task = Roby::Task.new)
            end

            PlanReplaceBehaviors.in_plan_context(self, :replace)
            PlanReplaceBehaviors.replace(self)
        end

        describe "#in_useful_subplan?" do
            before do
                @reference_task = Roby::Task.new
                @tested_task = Roby::Task.new
                plan.add([@reference_task, @tested_task])
            end
            it "returns false if the two tasks are unrelated" do
                refute plan.in_useful_subplan?(@reference_task, @tested_task)
            end
            it "returns false if the tested task is a parent of the child" do
                @tested_task.depends_on @reference_task
                refute plan.in_useful_subplan?(@reference_task, @tested_task)
            end
            it "returns true if the argument is a descendant of the child "\
               "through a single graph" do
                @reference_task.depends_on(intermediate = Roby::Task.new)
                intermediate.depends_on @tested_task
                assert plan.in_useful_subplan?(@reference_task, @tested_task)
            end
            it "returns true if the argument is a descendant of the child "\
               "through multiple graphs" do
                @reference_task.depends_on(intermediate = Roby::Task.new)
                intermediate.start_event.handle_with @tested_task
                assert plan.in_useful_subplan?(@reference_task, @tested_task)
            end
        end

        describe "#merge" do
            it "merges the receiver with itself" do
                plan = make_random_plan
                reference, mappings = plan.deep_copy
                plan.merge(plan)
                plan.same_plan?(reference, mappings)
            end
        end

        describe "#merge!" do
            it "merges the receiver with itself" do
                plan = make_random_plan
                reference, mappings = plan.deep_copy
                plan.merge!(plan)
                plan.same_plan?(reference, mappings)
            end
        end

        describe "#add_plan_service" do
            before do
                plan.add(@task = Task.new)
            end
            it "registers the plan service" do
                # Note that PlanService#initialize already calls add_plan_service ...
                service = PlanService.new(@task)
                assert_equal Set[service], plan.registered_plan_services_for(@task)
            end
            it "raises if the service's underlying task is not in the plan" do
                other_plan = Plan.new
                other_plan.add(t = Task.new)
                assert_raises(ArgumentError) do
                    plan.add_plan_service(PlanService.new(t))
                end
            end
        end

        describe "#remove_plan_service" do
            before do
                plan.add(@task = Task.new)
                @service = PlanService.new(@task)
            end
            it "deregisters the service" do
                plan.remove_plan_service(@service)
                assert_equal Set.new, plan.registered_plan_services_for(@task)
            end
            it "leaves other services registered for the same task" do
                other = PlanService.new(@task)
                plan.remove_plan_service(@service)
                assert_equal Set[other], plan.registered_plan_services_for(@task)
            end
            it "ignores services that are have been already removed" do
                plan.remove_plan_service(@service)
                plan.remove_plan_service(@service)
                assert_equal Set[], plan.registered_plan_services_for(@task)
            end
        end

        describe "#move_plan_service" do
            before do
                plan.add(@task = Task.new)
                @service = PlanService.new(@task)
                plan.add(@new_task = Task.new)
            end
            it "moves the service's registration" do
                plan.move_plan_service(@service, @new_task)
                assert_equal Set.new, plan.registered_plan_services_for(@task)
                assert_equal @new_task, @service.task
                assert_equal Set[@service], plan.registered_plan_services_for(@new_task)
            end
            it "handles moving to the same task" do
                plan.move_plan_service(@service, @task)
                assert_equal Set[@service], plan.registered_plan_services_for(@task)
                assert_equal @task, @service.task
            end
        end

        describe "#in_transaction" do
            it "yields a new transaction on the plan" do
                plan.in_transaction do |t|
                    assert_kind_of Transaction, t
                    assert_equal plan, t.plan
                end
            end
            it "handles an exception during transaction creation" do
                error = Class.new(RuntimeError)
                flexmock(Transaction).should_receive(:new).and_raise(error)
                assert_raises(error) do
                    plan.in_transaction {}
                end
            end
            it "leaves the transaction alone if it has been committed" do
                plan.in_transaction do |trsc|
                    flexmock(trsc).should_receive(:discard_transaction).never
                    trsc.commit_transaction
                end
            end
            it "returns the block's value" do
                obj = flexmock
                ret = plan.in_transaction do |trsc|
                    obj
                end
                assert_equal obj, ret
            end
            it "discards the transaction if it has not been commited in the block" do
                plan.in_transaction do |trsc|
                    flexmock(trsc).should_receive(:discard_transaction).once
                end
            end
        end

        describe "#num_events" do
            it "returns the sum of free and task events" do
                plan.add(t = Task.new)
                plan.add(ev = EventGenerator.new)
                assert_equal (t.each_event.to_a.size + 1), plan.num_events
            end
        end

        describe "#num_tasks" do
            it "returns the sum of tasks" do
                plan.add(t = Task.new)
                assert_equal 1, plan.num_tasks
            end
        end

        describe "#each_task" do
            it "returns an enumerator if not given a block" do
                plan.add(t = Task.new)
                assert_equal [t], plan.each_task.to_a
            end
        end

        describe "#[]" do
            it "returns its argument if it is from the plan" do
                plan.add(task = Task.new)
                assert_equal task, plan[task]
            end
            it "auto-adds the argument if it is not yet included in any plan" do
                task = Task.new
                assert_equal task, plan[task]
                assert plan.has_task?(task)
            end
            it "raises if the argument is finalized" do
                plan.add(task = Task.new)
                plan.remove_task(task)
                assert_raises(ArgumentError) { plan[task] }
            end
            it "raises if the argument is from a different plan" do
                Plan.new.add(task = Task.new)
                assert_raises(ArgumentError) { plan[task] }
            end
        end

        describe "#verify_plan_object_finalization_sanity" do
            it "raises if attempting to finalize a non-root object" do
                plan.add(task = Task.new)
                assert_raises(ArgumentError) do
                    plan.verify_plan_object_finalization_sanity(task.start_event)
                end
            end
            it "raises if attempting to finalize an already finalized object" do
                plan.add(task = Task.new)
                plan.remove_task(task)
                assert_raises(ArgumentError) do
                    plan.verify_plan_object_finalization_sanity(task)
                end
            end
            it "raises if attempting to finalize a never-added object" do
                task = Task.new
                assert_raises(ArgumentError) do
                    plan.verify_plan_object_finalization_sanity(task)
                end
            end
            it "raises if attempting to finalize an object from a different plan" do
                Plan.new.add(task = Task.new)
                assert_raises(ArgumentError) do
                    plan.verify_plan_object_finalization_sanity(task)
                end
            end
        end

        describe "#remove_task" do
            before do
                plan.add(@task = Roby::Task.new)
            end
            it "validates its argument once first" do
                flexmock(plan)
                    .should_receive(:verify_plan_object_finalization_sanity)
                    .with(@task).once.globally.ordered
                flexmock(plan)
                    .should_receive(:remove_task!)
                    .with(@task, Time).once.globally.ordered
                plan.remove_task(@task)
            end
            it "passes the timestamp to remove_task!" do
                timestamp = Time.at(2)
                flexmock(plan).should_receive(:remove_task!).with(@task, timestamp).once
                plan.remove_task(@task, timestamp)
            end
        end

        describe "#remove_task!" do
            before do
                plan.add(@task = Roby::Task.new)
                flexmock(plan)
            end
            it "removes the task from the set of tasks" do
                plan.remove_task(@task)
                refute plan.has_task?(@task)
            end
            it "removes the task from the set of mission tasks" do
                plan.add_mission_task(@task)
                plan.remove_task(@task)
                refute plan.mission_task?(@task)
            end
            it "removes the task from the set of permanent tasks" do
                plan.add_permanent_task(@task)
                plan.remove_task(@task)
                refute plan.permanent_task?(@task)
            end
            it "removes the task from the task index" do
                flexmock(plan.task_index)
                    .should_receive(:remove)
                    .with(@task).once.pass_thru
                plan.remove_task(@task)
            end
            it "removes the task's own events from the set of task events" do
                plan.remove_task(@task)
                @task.each_event { |ev| !plan.has_task_event?(ev) }
            end
            it "finalizes the task" do
                plan.should_receive(:finalize_task).with(@task, Time).once
                plan.remove_task(@task)
            end
            it "passes an explicit timestamp to the finalization" do
                time = Time.at(2)
                plan.should_receive(:finalize_task).with(@task, time).once
                plan.remove_task(@task, time)
            end
            it "calls the finalized_plan_task hook on active transactions "\
               "that have a proxy" do
                plan.in_transaction do |trsc|
                    proxy = trsc[@task]
                    flexmock(trsc).should_receive(:finalized_plan_task).with(proxy).once
                    plan.remove_task(@task)
                end
            end
            it "does not call the finalized_plan_task hook on disabled transactions" do
                plan.in_transaction do |trsc|
                    proxy = trsc[@task]
                    flexmock(trsc).should_receive(:finalized_plan_task).never
                    trsc.disable_proxying do
                        plan.remove_task(@task)
                    end
                end
            end
            it "does not call the finalized_plan_task hook on active transactions "\
               "that do not have a proxy" do
                plan.in_transaction do |trsc|
                    flexmock(trsc).should_receive(:finalized_plan_task).never
                    plan.remove_task(@task)
                end
            end
        end

        describe "#finalize_task" do
            before do
                plan.add(@task = Roby::Task.new)
                flexmock(plan)
            end
            it "resets a task's mission flag" do
                @task.mission = true
                plan.finalize_task(@task)
                refute @task.mission?
            end
            it "calls the finalized_event hook for its own events" do
                @task.each_event do |ev|
                    plan.should_receive(:finalized_event).with(ev).once
                end
                plan.finalize_task(@task)
            end
            it "calls the finalized_task hook for itself, after the events" do
                plan.should_receive(:finalized_event).globally.ordered
                plan.should_receive(:finalized_task).with(@task).once.globally.ordered
                plan.finalize_task(@task)
            end
            it "calls the event's own finalized! hook" do
                timestamp = Time.at(2)
                @task.each_event do |ev|
                    flexmock(ev).should_receive(:finalized!).with(timestamp).once
                end
                plan.finalize_task(@task, timestamp)
            end
            it "calls the tasks's own finalized! hook" do
                timestamp = Time.at(2)
                flexmock(@task).should_receive(:finalized!).with(timestamp).once
                plan.finalize_task(@task, timestamp)
            end
        end

        describe "#remove_free_event" do
            before do
                plan.add(@event = EventGenerator.new)
            end
            it "validates its argument once first" do
                flexmock(plan).should_receive(:verify_plan_object_finalization_sanity)
                              .with(@event).once.globally.ordered
                flexmock(plan).should_receive(:remove_free_event!)
                              .with(@event, Time).once.globally.ordered
                plan.remove_free_event(@event)
            end
            it "passes the timestamp to remove_free_event!" do
                timestamp = Time.at(2)
                flexmock(plan).should_receive(:remove_free_event!)
                              .with(@event, timestamp).once
                plan.remove_free_event(@event, timestamp)
            end
        end

        describe "#remove_free_event!" do
            before do
                plan.add(@event = EventGenerator.new)
                flexmock(plan)
            end
            it "removes the event from the set of events" do
                plan.remove_free_event(@event)
                refute plan.has_free_event?(@event)
            end
            it "removes the event from the set of permanent events" do
                plan.add_permanent_event(@event)
                plan.remove_free_event(@event)
                refute plan.permanent_event?(@event)
            end
            it "finalizes the event" do
                plan.should_receive(:finalize_event).with(@event, Time).once
                plan.remove_free_event!(@event)
            end
            it "passes an explicit timestamp to the finalization" do
                time = Time.at(2)
                plan.should_receive(:finalize_event).with(@event, time).once
                plan.remove_free_event!(@event, time)
            end
            it "calls the finalized_plan_event hook on active transactions "\
               "that have a proxy" do
                plan.in_transaction do |trsc|
                    proxy = trsc[@event]
                    flexmock(trsc).should_receive(:finalized_plan_event).with(proxy).once
                    plan.remove_free_event!(@event)
                end
            end
            it "does not call the finalized_plan_event hook on disabled transactions" do
                plan.in_transaction do |trsc|
                    proxy = trsc[@event]
                    flexmock(trsc).should_receive(:finalized_plan_event).never
                    trsc.disable_proxying do
                        plan.remove_free_event!(@event)
                    end
                end
            end
            it "does not call the finalized_plan_event hook on transactions "\
               "that do not have a proxy" do
                plan.in_transaction do |trsc|
                    flexmock(trsc).should_receive(:finalized_plan_event).never
                    plan.remove_free_event!(@event)
                end
            end
        end

        describe "#finalize_event" do
            before do
                plan.add(@event = EventGenerator.new)
                flexmock(plan)
            end
            it "calls the finalized_event hook" do
                plan.should_receive(:finalized_event).with(@event).once
                plan.finalize_event(@event)
            end
            it "calls the event's own finalized! hook" do
                timestamp = Time.at(2)
                flexmock(@event).should_receive(:finalized!).with(timestamp).once
                plan.finalize_event(@event, timestamp)
            end
        end

        describe "#remove_object" do
            before do
                flexmock(Roby).should_receive(:warn_deprecated).once
                flexmock(plan)
            end
            it "dispatches for a task included in the plan" do
                plan.add(task = Task.new)
                plan.should_receive(:remove_task).with(task, Time).once
                plan.remove_object(task)
            end
            it "dispatches for an event included in the plan" do
                plan.add(event = EventGenerator.new)
                plan.should_receive(:remove_free_event).with(event, Time).once
                plan.remove_object(event)
            end
            it "raises for anything else" do
                event = EventGenerator.new
                assert_raises(ArgumentError) do
                    plan.remove_object(event)
                end
            end
        end

        describe "#clear" do
            it "finalizes the tasks that can be" do
                plan.add(task = Task.new)
                flexmock(plan).should_receive(:finalize_task).with(task).once
                plan.clear
            end
            it "finalizes the free events" do
                plan.add(event = EventGenerator.new)
                flexmock(plan).should_receive(:finalize_event).with(event).once
                plan.clear
            end
            it "warns about running tasks" do
                plan.add_permanent_task(task = Task.new)
                flexmock(task).should_receive(running?: true)
                flexmock(Roby)
                    .should_receive(:warn)
                    .with("1 tasks remaining after clearing the plan "\
                          "as they are still running").once
                flexmock(Roby).should_receive(:warn).with("  #{task}").once
                plan.clear
            end
        end

        describe "#find_tasks" do
            it "sets up a query with global scope" do
                query = plan.find_tasks
                assert_same plan, query.plan
                assert query.global_scope?
            end
        end

        describe "#find_local_tasks" do
            it "sets up a query with local scope" do
                query = plan.find_local_tasks
                assert_same plan, query.plan
                assert query.local_scope?
            end
        end

        describe "#add_job_action" do
            it "adds an action in a way compatible with the job system" do
                app = Roby::Application.new
                action_m = Actions::Interface.new_submodel do
                    describe "action"
                    def action; end
                end
                app.plan.add_job_action(action_m.action)

                jobs = Interface::Interface.new(app).jobs
                assert_equal 1, jobs.size
                _, placeholder, job = jobs.values.first

                assert_kind_of action_m::Action, placeholder
                assert_equal action_m, job.action_model.action_interface_model
                assert_equal "action", job.action_model.name
            end
        end

        describe "#make_useless" do
            it "marks a mission task as non-mission" do
                plan.add_mission_task(task = Roby::Task.new)
                plan.make_useless(task)
                refute plan.mission_task?(task)
            end

            it "marks a permanent task as non-permanent" do
                plan.add_permanent_task(task = Roby::Task.new)
                plan.make_useless(task)
                refute plan.permanent_task?(task)
            end

            it "looks at the parent tasks of the argument" do
                plan.add_permanent_task(parent = Roby::Task.new)
                parent.depends_on(child = Roby::Task.new)
                plan.make_useless(child)
                refute plan.permanent_task?(parent)
            end

            it "goes through the whole useful graph chain" do
                plan.add_permanent_task(parent = Roby::Task.new)
                parent.planned_by(planning_task = Roby::Task.new)
                planning_task.depends_on(child = Roby::Task.new)
                plan.make_useless(child)
                refute plan.permanent_task?(parent)
            end

            it "iterates over all parents" do
                plan.add_permanent_task(parent = Roby::Task.new)
                parent.planned_by(planning_task = Roby::Task.new)
                planning_task.depends_on(child = Roby::Task.new)
                plan.add_mission_task(other_parent = Roby::Task.new)
                other_parent.depends_on(child)
                plan.make_useless(child)
                refute plan.permanent_task?(parent)
                refute plan.mission_task?(other_parent)
            end
        end
    end
end
