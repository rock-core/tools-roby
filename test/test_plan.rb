require 'roby/test/self'
require_relative './behaviors/plan_common_behavior'
require_relative './behaviors/plan_replace_behaviors'

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
            it "instanciates graphs for all the relation graphs registered on Roby::Task" do
                space = flexmock(instanciate: Hash[1 => 2])
                flexmock(Roby::Task).should_receive(:all_relation_spaces).and_return([space])
                plan = Roby::Plan.new
                assert_equal Hash[1 => 2], plan.task_relation_graphs
            end
            it "instanciates graphs for all the relation graphs registered on Roby::Task's submodels" do
                root_space = flexmock(instanciate: Hash[1 => 2])
                submodel_space = flexmock(instanciate: Hash[41 => 42])
                task_m = Roby::Task.new_submodel
                flexmock(Roby::Task).should_receive(:all_relation_spaces).and_return([root_space, submodel_space])
                plan = Roby::Plan.new
                assert_equal Hash[1 => 2, 41 => 42], plan.task_relation_graphs
            end
            it "configures #task_relation_graphs to raise if an invalid graph is being resolved" do
                space = flexmock
                flexmock(Roby::Task).should_receive(:all_relation_spaces).and_return([space])
                assert_raises(ArgumentError) do
                    plan.task_relation_graphs[invalid = flexmock]
                end
            end
            it "configures #task_relation_graphs to return nil if nil is being resolved" do
                plan = Roby::Plan.new
                assert_nil plan.task_relation_graphs[nil]
            end

            it "instanciates graphs for all the relation graphs registered on Roby::EventGenerator" do
                space = flexmock(instanciate: Hash[1 => 2])
                flexmock(Roby::EventGenerator).should_receive(:all_relation_spaces).and_return([space])
                plan = Roby::Plan.new
                assert_equal Hash[1 => 2], plan.event_relation_graphs
            end
            it "configures #event_relation_graphs to raise if an invalid graph is being resolved" do
                space = flexmock
                flexmock(Roby::EventGenerator).should_receive(:all_relation_spaces).and_return([space])
                assert_raises(ArgumentError) do
                    plan.event_relation_graphs[invalid = flexmock]
                end
            end
            it "configures #task_relation_graphs to return nil if nil is being resolved" do
                plan = Roby::Plan.new
                assert_nil plan.event_relation_graphs[nil]
            end
        end

        describe "#locally_useful_tasks" do
            it "computes the merge of all strong relation graphs from permanent tasks" do
                parent, (child, planner, planner_child) = prepare_plan permanent: 1, add: 3, model: Roby::Tasks::Simple
                parent.depends_on child
                child.planned_by planner
                planner.depends_on planner_child
                assert_equal [parent, child, planner, planner_child].to_set, plan.locally_useful_tasks
            end
            it "ignores tasks that are not used by a permanent task" do
                parent, (other_root, child, planner, planner_child) = prepare_plan permanent: 1, add: 4, model: Roby::Tasks::Simple
                parent.depends_on child
                child.planned_by planner
                planner.depends_on planner_child
                other_root.depends_on planner
                assert_equal [parent, child, planner, planner_child].to_set, plan.locally_useful_tasks
            end

            it "returns standalone mission tasks" do
                parent = prepare_plan missions: 1, model: Roby::Tasks::Simple
                assert_equal [parent].to_set, plan.locally_useful_tasks
            end

            it "returns standalone permanent tasks" do
                parent = prepare_plan permanent: 1, model: Roby::Tasks::Simple
                assert_equal [parent].to_set, plan.locally_useful_tasks
            end

            it "computes the merge of all strong relation graphs from mission tasks" do
                parent, (child, planner, planner_child) = prepare_plan missions: 1, add: 3, model: Roby::Tasks::Simple
                parent.depends_on child
                child.planned_by planner
                planner.depends_on planner_child
                assert_equal [parent, child, planner, planner_child].to_set, plan.locally_useful_tasks
            end
            it "ignores tasks that are not used by a missions" do
                parent, (other_root, child, planner, planner_child) = prepare_plan missions: 1, add: 4, model: Roby::Tasks::Simple
                parent.depends_on child
                child.planned_by planner
                planner.depends_on planner_child
                other_root.depends_on planner
                assert_equal [parent, child, planner, planner_child].to_set, plan.locally_useful_tasks
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
            it "yields tasks whose modifications within the transaction created a match" do
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
                new, removed = plan.compute_subplan_replacement(Hash[source => target], [graph])
                assert_equal [[graph, parent, target, info]], new
                assert_equal [[graph, parent, source]], removed
            end
            it "moves relations for which the target is not a key in the task mapping" do
                plan.add(source = Roby::Task.new)
                plan.add(child = Roby::Task.new)
                plan.add(target = Roby::Task.new)
                graph.add_edge(source, child, info = flexmock)
                new, removed = plan.compute_subplan_replacement(Hash[source => target], [graph])
                assert_equal [[graph, target, child, info]], new
                assert_equal [[graph, source, child]], removed
            end
            it "ignores relations if both objects are within the mapping" do
                plan.add(parent = Roby::Task.new)
                plan.add(parent_target = Roby::Task.new)
                plan.add(child = Roby::Task.new)
                plan.add(child_target = Roby::Task.new)
                graph.add_edge(parent, child, flexmock)
                new, removed = plan.compute_subplan_replacement(Hash[parent => parent_target, child => child_target], [graph])
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
                new, removed = plan.compute_subplan_replacement(Hash[parent => nil, child => child_target], [graph])
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
                new, removed = plan.compute_subplan_replacement(Hash[source => target], [graph])
                assert_equal [], new
                assert_equal [], removed
            end
            it "copies relations instead of moving them if the graph is copy_on_replace" do
                plan.add(parent = Roby::Task.new)
                plan.add(source = Roby::Task.new)
                plan.add(target = Roby::Task.new)
                graph = Roby::Relations::Graph.new(copy_on_replace: true)
                graph.add_edge(parent, source, info = flexmock)
                new, removed = plan.compute_subplan_replacement(Hash[source => target], [graph])
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
        end
        
        describe "deep_copy" do
            it "copies the plan objects and their structure" do
                parent, (child, planner) = prepare_plan missions: 1, add: 2, model: Roby::Tasks::Simple
                plan.add(ev = Roby::EventGenerator.new)

                child.success_event.forward_to ev
                parent.depends_on child
                child.planned_by planner

                copy, mappings = plan.deep_copy
                assert_equal (plan.tasks | plan.free_events | plan.task_events), mappings.keys.to_set
                assert plan.same_plan?(copy, mappings)
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
                task_event_mappings = Hash.new
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
                plan.same_plan?(copy, Hash.new)
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
                mappings = prepare_mappings(task_parent => task_parent_copy, task_child => task_child_copy)
                assert plan.same_plan?(copy, mappings)
            end

            it "returns false for a plan with differing task relations" do
                plan.add(task_parent = Task.new)
                task_parent.depends_on(task_child = Task.new)
                copy.add(task_parent_copy = Task.new)
                copy.add(task_child_copy = Task.new)
                mappings = prepare_mappings(task_parent => task_parent_copy, task_child => task_child_copy)
                assert !plan.same_plan?(copy, mappings)
            end

            it "returns false for a plan with a missing task" do
                plan.add(task = Task.new)
                assert !plan.same_plan?(copy, Hash.new)
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
                mappings = prepare_mappings(event_parent => event_parent_copy, event_child => event_child_copy)
                assert plan.same_plan?(copy, mappings)
            end

            it "returns false on a plan with differing event relations" do
                plan.add(event_parent = EventGenerator.new)
                event_parent.add_signal(event_child = EventGenerator.new)
                copy.add(event_parent_copy = EventGenerator.new)
                copy.add(event_child_copy = EventGenerator.new)
                mappings = prepare_mappings(event_parent => event_parent_copy, event_child => event_child_copy)
                assert !plan.same_plan?(copy, mappings)
            end

            it "returns false on a plan with differing task event relations" do
                plan.add(task_parent = Task.new)
                plan.add(task_child = Task.new)
                copy.add(task_parent_copy = Task.new)
                copy.add(task_child_copy = Task.new)
                task_parent.start_event.forward_to task_child.start_event
                mappings = prepare_mappings(task_parent => task_parent_copy, task_child => task_child_copy)
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
            it "returns true if the argument is a descendant of the child through a single graph" do
                @reference_task.depends_on(intermediate = Roby::Task.new)
                intermediate.depends_on @tested_task
                assert plan.in_useful_subplan?(@reference_task, @tested_task)
            end
            it "returns true if the argument is a descendant of the child through multiple graphs" do
                @reference_task.depends_on(intermediate = Roby::Task.new)
                intermediate.start_event.handle_with @tested_task
                assert plan.in_useful_subplan?(@reference_task, @tested_task)
            end
        end
    end
end

