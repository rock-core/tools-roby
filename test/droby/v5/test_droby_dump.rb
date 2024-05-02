# frozen_string_literal: true

require "roby/test/self"

module Roby
    module DRoby
        module V5
            class TestLocalizedError < LocalizedError
            end

            describe "marshalling and demarshalling of Roby objects" do
                let :local_id do
                    1
                end
                let :marshaller_object_manager do
                    ObjectManager.new(local_id)
                end
                let :marshaller do
                    Marshal.new(marshaller_object_manager, remote_id)
                end
                let :remote_id do
                    2
                end
                let :demarshaller_object_manager do
                    ObjectManager.new(remote_id)
                end
                let :demarshaller do
                    Marshal.new(demarshaller_object_manager, local_id)
                end
                let(:local_plan) do
                    p = Roby::ExecutablePlan.new
                    ExecutionEngine.new(p)
                    p
                end
                let(:remote_plan) { Roby::ExecutablePlan.new }

                def execute(plan: local_plan, **options)
                    super
                end

                def expect_execution(plan: local_plan, **options)
                    super
                end

                def create_task_pair
                    local_plan.add(task = Roby::Task.new)
                    marshaller_object_manager.register_object(task)
                    [task, transfer(task)]
                end

                before do
                    demarshaller_object_manager.register_object(remote_plan, local_id => local_plan.droby_id)
                end

                def transfer(obj)
                    droby_unmarshalled = ::Marshal.load(::Marshal.dump(marshaller.dump(obj)))
                    demarshaller.local_object(droby_unmarshalled)
                end

                describe BidirectionalGraphDumper do
                    it "dumps and reloads objects, edges and information" do
                        graph = Relations::BidirectionalDirectedAdjacencyGraph.new
                        task_a, remote_a = create_task_pair
                        task_b, remote_b = create_task_pair
                        graph.add_edge(task_a, task_b, { v: 10 })
                        graph.add_edge(task_a.start_event, task_b.stop_event, { v: 42 })
                        remote_g = transfer(graph)
                        assert_equal({ v: 10 }, remote_g.edge_info(remote_a, remote_b))
                        assert_equal({ v: 42 }, remote_g.edge_info(remote_a.start_event, remote_b.stop_event))
                    end
                end

                describe Models::TaskDumper do
                    before do
                        demarshaller.register_model(Roby::Task)
                    end

                    it "stops marshaling ancestry at Roby::Task" do
                        task_m = Roby::Task.new_submodel(name: "Test")
                        marshalled = marshaller.dump(task_m)
                        assert !marshalled.supermodel.supermodel
                        assert_equal "Roby::Task", marshalled.supermodel.name
                    end

                    it "reuses an already known task model" do
                        task_m = Roby::Task.new_submodel(name: "Test")
                        marshalled = marshaller.dump(task_m)
                        loaded = demarshaller.local_object(marshalled)
                        assert_same loaded, demarshaller.local_object(marshalled)
                    end

                    it "resolves its default arguments" do
                        other_m = Roby::Task.new_submodel(name: "Argument")
                        task_m = Roby::Task.new_submodel(name: "Test")
                        task_m.argument :test, default: other_m

                        remote_m = transfer(task_m)
                        assert_same remote_m.find_argument(:test).default.value, transfer(other_m)
                    end

                    it "resolves a model by name" do
                        task_m = Roby::Task.new_submodel(name: "Test")
                        remote_m = Roby::Task.new_submodel(name: "RemoteTest")
                        flexmock(demarshaller).should_receive(:find_local_model).with(->(m) { m.name == "Test" }).and_return(remote_m)
                        flexmock(demarshaller).should_receive(:find_local_model).pass_thru

                        transferred = transfer(task_m)
                        assert_same remote_m, transferred
                    end

                    it "loads objects within its default arguments even if the model can be resolved by name" do
                        other_m = Roby::Task.new_submodel(name: "RemoteTest")
                        task_m = Roby::Task.new_submodel(name: "Test")
                        task_m.argument :test, default: other_m
                        remote_m = Roby::Task.new_submodel(name: "RemoteTest")
                        flexmock(demarshaller).should_receive(:find_local_model).with(->(m) { m.name == "Test" }).and_return(remote_m)
                        flexmock(demarshaller).should_receive(:find_local_model).pass_thru
                        flexmock(demarshaller).should_receive(:local_object).with(V5::DefaultArgumentDumper::DRoby).once
                        flexmock(demarshaller).should_receive(:local_object).pass_thru

                        transfer(task_m)
                    end

                    it "replicates the model's arguments" do
                        task_m = Roby::Task.new_submodel(name: "Test") { argument :test }
                        loaded = transfer(task_m)
                        assert loaded.has_argument?(:test)
                    end

                    it "replicates the model's events" do
                        task_m = Roby::Task.new_submodel(name: "Test")
                        task_m.event :controlable, controlable: true
                        task_m.event :terminal, terminal: true
                        loaded = transfer(task_m)
                        assert loaded.find_event(:controlable).controlable?
                        assert loaded.find_event(:terminal).terminal?
                    end

                    it "handles task models without names properly" do
                        task_m = Roby::Task.new_submodel
                        task_m.event :controlable, controlable: true
                        task_m.event :terminal, terminal: true
                        marshaller.register_model(task_m)
                        marshalled = marshaller.dump(task_m)
                        ::Marshal.load(::Marshal.dump(marshalled))
                        loaded = demarshaller.local_object(marshalled)
                        assert loaded.find_event(:controlable).controlable?
                        assert loaded.find_event(:terminal).terminal?
                        # They can't be resolved by name, but should be resolved
                        # by ID
                        assert_same loaded, demarshaller.local_object(marshalled)
                    end

                    it "registers its model" do
                        task_m = Roby::Task.new_submodel
                        task_m.new
                        droby_transfer(task_m.new)
                        assert_kind_of Roby::DRoby::RemoteDRobyID,
                                       droby_local_marshaller.dump(task_m)
                    end

                    it "handles a model that is also referenced in its arguments" do
                        task_m = Roby::Task.new_submodel
                        task_m.argument :arg
                        task = task_m.new(arg: task_m)
                        remote = droby_transfer task
                        assert_same remote.class, remote.arg
                    end
                end

                describe "marshalling and demarshalling of plan objects" do
                    describe EventGeneratorDumper do
                        it "adds the event on the remote plan" do
                            ev = EventGenerator.new(plan: local_plan)
                            ev = transfer(ev)
                            assert_equal remote_plan, ev.plan
                            assert remote_plan.has_free_event?(ev)
                        end

                        it "replicates the controlable status" do
                            ev = EventGenerator.new(plan: local_plan, controlable: true)
                            ev = transfer(ev)
                            assert ev.controlable?

                            ev = EventGenerator.new(plan: local_plan, controlable: true)
                            ev = transfer(ev)
                            assert ev.controlable?
                        end

                        it "replicates the cached emitted flag" do
                            ev = EventGenerator.new(plan: local_plan)
                            execute { ev.emit }
                            ev = transfer(ev)
                            assert ev.emitted?
                        end
                    end

                    describe TaskDumper do
                        attr_reader :task_m

                        before do
                            @task_m = Roby::Task.new_submodel
                            task_m.terminates
                        end

                        it "adds the task on the remote plan" do
                            task = Task.new(plan: local_plan)
                            task = transfer(task)
                            assert_equal remote_plan, task.plan
                            assert remote_plan.has_task?(task)
                        end

                        it "replicates the arguments" do
                            task_m.argument :test
                            local_plan.add(task = task_m.new(test: flexmock(droby_dump: 10)))
                            task = transfer(task)
                            assert_equal 10, task.arguments[:test]
                        end

                        it "replicates delayed arguments" do
                            task_m.argument :test
                            local_plan.add(task = task_m.new(test: DefaultArgument.new(10)))
                            task = transfer(task)

                            test_arg = task.arguments.raw_get(:test)
                            assert_kind_of DefaultArgument, test_arg
                            assert_equal 10, test_arg.value
                        end

                        it "replicates the cached started status" do
                            local_plan.add(task = task_m.new)
                            execute { task.start! }
                            task = transfer(task)
                            assert task.running?
                        end

                        it "replicates the cached finished status" do
                            local_plan.add(task = task_m.new)
                            execute do
                                task.start!
                                task.stop!
                            end
                            task = transfer(task)
                            assert task.finished?
                        end

                        it "replicates the cached success status" do
                            local_plan.add(task = task_m.new)
                            execute do
                                task.start!
                                task.success_event.emit
                            end
                            task = transfer(task)
                            assert task.success?
                        end

                        it "replicates the mission status" do
                            task_m = Roby::Task.new_submodel do
                                event :additional, controlable: true
                            end
                            local_plan.add_mission_task(task = task_m.new)
                            task = transfer(task)
                            assert task.mission?
                            assert remote_plan.mission_task?(task)
                        end

                        it "updates the mission status on an already known sibling" do
                            task_m = Roby::Task.new_submodel do
                                event :additional, controlable: true
                            end
                            local_plan.add_mission_task(task = task_m.new)
                            transfer(task)

                            local_plan.unmark_mission_task(task)
                            remote_task = transfer(task)
                            assert !remote_task.mission?
                            assert !remote_plan.mission_task?(remote_task)

                            local_plan.add_mission_task(task)
                            remote_task = transfer(task)
                            assert remote_task.mission?
                            assert remote_plan.mission_task?(remote_task)
                        end

                        it "replicates the mission status" do
                            task_m = Roby::Task.new_submodel do
                                event :additional, controlable: true
                            end
                            local_plan.add_mission_task(task = task_m.new)
                            task = transfer(task)
                            assert task.mission?
                            assert remote_plan.mission_task?(task)
                        end

                        it "replicates the task model" do
                            task_m = Roby::Task.new_submodel do
                                event :additional, controlable: true
                            end
                            local_plan.add(task = task_m.new)
                            task = transfer(task)
                            assert task.event(:additional).controlable?
                        end
                    end

                    describe TaskEventGeneratorDumper do
                        it "resolves the event on the unmarshalled task" do
                            local_plan.add(task = Roby::Task.new)
                            marshaller_object_manager.register_object(task)
                            remote_task = transfer(task)
                            remote_event = transfer(task.start_event)
                            assert_same remote_task.start_event, remote_event
                        end

                        it "duplicates the event's emitted status" do
                            local_plan.add(task = Roby::Task.new_submodel.new)
                            execute { task.start_event.emit }
                            remote_event = transfer(task.start_event)
                            assert remote_event.emitted?
                        end
                    end
                end

                describe PlanDumper do
                    attr_reader :plan, :task_m

                    before do
                        @plan = Roby::Plan.new
                        @task_m = Task.new_submodel
                        task_m.argument :test
                    end

                    it "transfers the tasks" do
                        plan.add(task_m.new(test: 20))
                        plan = transfer(self.plan)
                        assert_equal 1, plan.tasks.size
                        assert_equal Roby::Task, plan.tasks.first.class.superclass
                        assert_equal 20, plan.tasks.first.arguments[:test]
                    end

                    it "handles tasks in arguments" do
                        plan.add(task0 = task_m.new)
                        plan.add(task_m.new(test: task0))
                        plan = transfer(self.plan)
                        task0, task1 = plan.tasks.to_a
                        assert_equal task0, task1.arguments[:test]
                    end

                    it "marshals relations between tasks" do
                        plan.add(task0 = task_m.new)
                        plan.add(task1 = task_m.new)
                        marshaller_object_manager.register_model(task_m)
                        task0.depends_on task1

                        plan = transfer(self.plan)
                        r_task0, r_task1 = plan.tasks.to_a
                        assert r_task0.depends_on?(r_task1)

                        info   = task0[task1, TaskStructure::Dependency]
                        r_info = r_task0[r_task1, TaskStructure::Dependency]
                        assert_equal [[r_task1.model], {}], r_info.delete(:model)
                        assert_equal r_info, info.slice(*(info.keys - [:model]))
                    end

                    it "marshals relations between events" do
                        plan.add(task = task_m.new)
                        plan.add(ev   = EventGenerator.new)
                        task.start_event.forward_to ev

                        plan = transfer(self.plan)
                        r_task = plan.tasks.first
                        r_ev   = plan.free_events.first
                        assert_child_of r_task.start_event, r_ev, EventStructure::Forwarding
                    end
                end

                describe ExceptionBaseDumper do
                    it "marshals and unmarshals the original_exceptions" do
                        original_e = ::Exception.new("a message")
                        e = ExceptionBase.new([original_e])
                        e = transfer(e)
                        assert_equal 1, e.original_exceptions.size
                        assert_equal "a message", e.original_exceptions.first.message
                    end
                end

                describe LocalizedErrorDumper do
                    attr_reader :local_task, :remote_task

                    before do
                        @local_task, @remote_task = create_task_pair
                    end

                    it "unmarshals as an UntypedLocalizedError with the relevant failure point" do
                        e = LocalizedError.new(local_task.start_event)
                        e = transfer(e)
                        assert_equal UntypedLocalizedError, e.class
                        assert_equal remote_task.start_event, e.failure_point
                    end

                    it "propagates the original exception type" do
                        exception_type = Class.new(LocalizedError)
                        e = exception_type.new(local_task.start_event)
                        e = transfer(e)
                        assert_equal LocalizedError, e.exception_class.superclass
                    end

                    it "demarshals the exception type as model" do
                        exception_type = TestLocalizedError
                        e = exception_type.new(local_task.start_event)
                        e = transfer(e)
                        assert_equal exception_type, e.exception_class
                    end

                    it "reports that it is kind_of? the actual exception class" do
                        exception_type = Class.new(LocalizedError)
                        e = exception_type.new(local_task.start_event)
                        e = transfer(e)
                        assert_kind_of e.exception_class, e
                    end

                    it "propagates the original exception's fatal? flag" do
                        exception_type = Class.new(LocalizedError)
                        e = exception_type.new(local_task.start_event)
                        def e.fatal?
                            false
                        end
                        e = transfer(e)
                        assert !e.fatal?
                    end

                    it "transfers the original_exceptions array" do
                        e = LocalizedError.new(local_task.start_event)
                        e.original_exceptions << flexmock(droby_dump: 42)
                        flexmock(demarshaller).should_receive(:local_object).with(42)
                                              .and_return(r_exceptions = flexmock)
                        flexmock(demarshaller).should_receive(:local_object).pass_thru
                        e = transfer(e)
                        assert_equal [r_exceptions], e.original_exceptions
                    end
                end

                describe ExecutionExceptionDumper do
                    it "is droby-marshallable" do
                        task, r_task = create_task_pair
                        parent_task, r_parent_task = create_task_pair
                        ee = LocalizedError.new(task.start_event).to_execution_exception
                        ee.propagate(task, parent_task)
                        ee.handled = true

                        ee = transfer(ee)
                        assert_equal r_task.start_event, ee.exception.failure_point
                        assert_equal [[r_task, r_parent_task, nil]], ee.trace.each_edge.to_a
                        assert ee.handled?
                    end
                end

                describe PlanningFailedErrorDumper do
                    it "marshals the planned, planning and failure reason" do
                        planned_t, r_planned_t = create_task_pair
                        planning_t, r_planning_t = create_task_pair

                        e = PlanningFailedError.new(planned_t, planning_t, failure_reason: flexmock(droby_dump: 42))
                        e = transfer(e)
                        assert_equal r_planned_t, e.planned_task
                        assert_equal r_planning_t, e.planning_task
                        assert_equal 42, e.failure_reason
                    end
                end

                describe DefaultArgumentDumper do
                    it "transfers the default argument value" do
                        local = Roby::Task.new_submodel
                        DefaultArgument.new(local)
                        arg = Roby::DefaultArgument.new(local)

                        remote_arg = droby_transfer(arg)
                        assert_kind_of Roby::DefaultArgument, remote_arg
                        assert_same droby_transfer(local), remote_arg.value
                    end
                end

                describe DelayedArgumentFromObjectDumper do
                    it "handles DelayedArgumentFromObject" do
                        obj = Object.new
                        arg = Roby::DelayedArgumentFromObject.new(obj, false).bla

                        transfer(arg)
                        assert_kind_of Object, arg.instance_variable_get(:@object)
                        assert_equal [:bla], arg.instance_variable_get(:@methods)
                        assert_equal Object, arg.instance_variable_get(:@expected_class)
                        assert !arg.instance_variable_get(:@weak)
                    end

                    it "handles DelayedArgumentFromState" do
                        arg = Roby::DelayedArgumentFromState.new.bla

                        transfer(arg)
                        assert_kind_of Roby::StateSpace, arg.instance_variable_get(:@object)
                        assert_equal [:bla], arg.instance_variable_get(:@methods)
                        assert_equal Object, arg.instance_variable_get(:@expected_class)
                        assert arg.instance_variable_get(:@weak)
                    end
                end

                describe Actions do
                    describe Actions::ActionDumper do
                        it "resolves the action arguments and model" do
                            task_m = Roby::Task.new_submodel
                            interface_m = Roby::Actions::Interface.new_submodel(name: "Test") do
                                describe("action")
                                    .returns(task_m)
                                    .required_arg("test")
                                def an_action(arguments); end
                            end
                            marshaller.register_model(task_m)
                            demarshaller.register_model(interface_m)

                            action = interface_m.an_action(test: task_m)
                            loaded = transfer(action)
                            assert_same action.model, loaded.model
                            assert_equal task_m.droby_id, demarshaller_object_manager.known_sibling_on(
                                loaded.arguments[:test], local_id
                            )
                        end
                    end

                    describe Actions::Models do
                        describe Actions::Models::ActionDumper do
                            it "resolves them on existing interface models" do
                                task_m = Roby::Task.new_submodel
                                interface_m = Roby::Actions::Interface.new_submodel(name: "Test") do
                                    describe("action")
                                        .returns(task_m)
                                    def an_action; end
                                end
                                demarshaller.register_model(interface_m)

                                action_m = interface_m.find_action_by_name("an_action")
                                loaded = transfer(action_m)
                                assert_same action_m, loaded
                            end

                            it "marshals actions with non trivial default arguments" do
                                task_m = Roby::Task.new_submodel(name: "Test")
                                interface_m = Roby::Actions::Interface.new_submodel do
                                    describe("action")
                                        .optional_arg("test", "", task_m)
                                        .returns(task_m)
                                    def an_action(arguments = {}); end
                                end

                                action_m = interface_m.find_action_by_name("an_action")
                                loaded = transfer(action_m)
                                assert loaded.find_arg("test").default <= Roby::Task
                                assert_equal "Test", loaded.find_arg("test").default.name
                            end
                        end
                    end
                end

                describe Queries do
                    describe Queries::AndMatcherDumper do
                        it "is droby-marshallable" do
                            q0, q1 = flexmock, flexmock
                            and_q  = Roby::Queries::AndMatcher.new(q0, q1)
                            flexmock(marshaller).should_receive(:dump).with(and_q).pass_thru
                            flexmock(marshaller).should_receive(:dump).with([q0, q1]).and_return(42).once
                            flexmock(demarshaller).should_receive(:local_object).with(Queries::AndMatcherDumper::DRoby).pass_thru
                            flexmock(demarshaller).should_receive(:local_object).with(42).and_return([q0, q1]).once
                            q = transfer(and_q)
                            assert_kind_of Roby::Queries::AndMatcher, q
                            assert_equal [q0, q1], q.instance_variable_get(:@ops)
                        end
                    end

                    describe Queries::OrMatcherDumper do
                        it "is droby-marshallable" do
                            q0, q1 = flexmock, flexmock
                            or_q = Roby::Queries::OrMatcher.new(q0, q1)
                            flexmock(marshaller).should_receive(:dump).with(or_q).pass_thru
                            flexmock(marshaller).should_receive(:dump).with([q0, q1]).and_return(42).once
                            flexmock(demarshaller).should_receive(:local_object).with(Queries::OrMatcherDumper::DRoby).pass_thru
                            flexmock(demarshaller).should_receive(:local_object).with(42).and_return([q0, q1]).once
                            q = transfer(or_q)
                            assert_kind_of Roby::Queries::OrMatcher, q
                            assert_equal [q0, q1], q.instance_variable_get(:@ops)
                        end
                    end

                    describe Queries::NotMatcherDumper do
                        it "is droby-marshallable" do
                            not_q = Roby::Queries::NotMatcher.new(q = flexmock)
                            flexmock(marshaller).should_receive(:dump).with(not_q).pass_thru
                            flexmock(marshaller).should_receive(:dump).with(q).and_return(42).once
                            flexmock(demarshaller).should_receive(:local_object).with(Queries::NotMatcherDumper::DRoby).pass_thru
                            flexmock(demarshaller).should_receive(:local_object).with(42)
                                                  .and_return(q).once
                            unmarshalled = transfer(not_q)
                            assert_kind_of Roby::Queries::NotMatcher, unmarshalled
                            assert_equal q, unmarshalled.instance_variable_get(:@op)
                        end
                    end

                    describe Queries::PlanObjectMatcherDumper do
                        let(:matcher) { Roby::Queries::PlanObjectMatcher.new }

                        it "demarshals as PlanObjectMatcher" do
                            assert_kind_of Roby::Queries::PlanObjectMatcher,
                                           transfer(matcher)
                        end

                        it "marshals a given model" do
                            task_m = Task.new_submodel
                            marshaller_object_manager.register_object(task_m)
                            r_task_m = transfer(task_m)

                            matcher.with_model(task_m)
                            matcher = transfer(self.matcher)
                            assert_equal [r_task_m], matcher.model
                        end

                        it "marshals predicates" do
                            matcher.predicates << :a
                            matcher.indexed_predicates << :b
                            matcher.neg_predicates << :c
                            matcher.indexed_neg_predicates << :d
                            matcher = transfer(self.matcher)
                            assert_equal [:a], matcher.predicates
                            assert_equal [:b], matcher.indexed_predicates
                            assert_equal [:c], matcher.neg_predicates
                            assert_equal [:d], matcher.indexed_neg_predicates
                        end

                        describe "relation matching" do
                            attr_reader :task_m, :r_task_m, :r_dependency

                            before do
                                @task_m = Task.new_submodel
                                marshaller_object_manager.register_object(task_m)
                                marshaller_object_manager.register_object(Roby::TaskStructure::Dependency)
                                @r_task_m = transfer(@task_m)
                                @r_dependency = transfer(Roby::TaskStructure::Dependency)
                            end

                            it "marshals parent specifications" do
                                matcher.with_child(task_m, Roby::TaskStructure::Dependency,
                                                   flexmock(droby_dump: 42))
                                flexmock(demarshaller).should_receive(:local_object).with(42).and_return({}).once
                                flexmock(demarshaller).should_receive(:local_object).with(any, any).pass_thru
                                matcher = transfer(self.matcher)

                                edges = matcher.children.fetch(Roby::TaskStructure::Dependency)
                                query, info = edges.first
                                assert_equal [r_task_m], query.model
                                assert_equal({}, info)
                            end

                            it "marshals children specifications" do
                                matcher.with_parent(task_m, Roby::TaskStructure::Dependency,
                                                    flexmock(droby_dump: 42))
                                flexmock(demarshaller).should_receive(:local_object).with(42).and_return({}).once
                                flexmock(demarshaller).should_receive(:local_object).with(any, any).pass_thru
                                matcher = transfer(self.matcher)

                                edges = matcher.parents.fetch(Roby::TaskStructure::Dependency)
                                query, info = edges.first
                                assert_equal [r_task_m], query.model
                                assert_equal({}, info)
                            end
                        end
                    end

                    describe Queries::TaskMatcherDumper do
                        let(:matcher) { Roby::Queries::TaskMatcher.new }

                        it "marshals the argument specifications" do
                            matcher.with_arguments(test: flexmock(droby_dump: 42))
                            flexmock(demarshaller).should_receive(:local_object).with(42).and_return({}).once
                            flexmock(demarshaller).should_receive(:local_object).with(any).pass_thru
                            matcher = transfer(self.matcher)
                            assert_kind_of Roby::Queries::TaskMatcher, matcher
                            assert_equal({ test: {} }, matcher.arguments)
                        end
                    end

                    describe Queries::QueryDumper do
                        it "maps the plan" do
                            query = local_plan.find_tasks
                            query = transfer(query)
                            assert_same remote_plan, query.plan
                        end

                        it "marshals the scope" do
                            query = transfer(local_plan.find_tasks)
                            assert_equal :global, query.scope

                            query = transfer(local_plan.find_tasks.local_scope)
                            assert_equal :local, query.scope
                        end

                        it "marshals the plan predicates" do
                            query = local_plan.find_tasks
                            query.plan_predicates << :a
                            query.neg_plan_predicates << :b
                            query = transfer(query)
                            assert_equal Set[:a], query.plan_predicates
                            assert_equal Set[:b], query.neg_plan_predicates
                        end
                    end
                end
            end
        end
    end
end
