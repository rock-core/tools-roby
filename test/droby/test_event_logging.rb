require 'roby/test/self'

require 'roby/droby/event_logger'
require 'roby/droby/plan_rebuilder'

module Roby
    module DRoby
        # For event logging ({EventLogger} and {PlanRebuilder}), I elected to do
        # some synthetic tests
        describe "Event logging" do
            attr_reader :logfile, :event_logger, :local_plan, :plan_rebuilder, :rebuilt_plan
            before do
                @logfile = Class.new do
                    attr_reader :cycles
                    def initialize; @cycles = Array.new end
                    def flush; end
                    def dump(cycle)
                        cycles << cycle
                    end
                end.new
                @event_logger = EventLogger.new(logfile)

                @local_plan = ExecutablePlan.new(event_logger: event_logger)
                @plan_rebuilder = PlanRebuilder.new
            end

            def rebuilt_plan
                plan_rebuilder.plan
            end

            def flush_cycle_events
                add_cycle_end
                event_logger.flush
                logfile.cycles.first
            end

            def add_cycle_end
                event_logger.dump(:cycle_end, Time.now, [Hash.new])
            end
            def process_logged_events
                flush_cycle_events
                logfile.cycles.each do |c|
                    plan_rebuilder.process_one_cycle(logfile.cycles.first)
                end
                logfile.cycles.clear
            end

            describe "plan structure" do
                it "can duplicate a merged plan" do
                    parent, child = Tasks::Simple.new(id: 'parent'), Tasks::Simple.new(id: 'child')
                    parent.depends_on child
                    parent.start_event.signals child.start_event
                    local_plan.add(parent)

                    process_logged_events

                    assert_equal 2, rebuilt_plan.known_tasks.size
                    parent = rebuilt_plan.find_tasks.with_arguments(id: 'parent').first
                    child  = rebuilt_plan.find_tasks.with_arguments(id: 'child').first
                    assert_child_of parent, child, TaskStructure::Dependency
                    assert_child_of parent.start_event, child.start_event, EventStructure::Signal
                end

                it "sets the addition_time to the initial logged time" do
                    task  = Tasks::Simple.new
                    event = EventGenerator.new

                    base_time = Time.now
                    addition_time = Time.at(base_time.tv_sec, base_time.tv_usec)
                    flexmock(Time).should_receive(:now).and_return { base_time }
                    local_plan.add(task)
                    local_plan.add(event)

                    base_time += 5
                    process_logged_events

                    task  = rebuilt_plan.known_tasks.first
                    event = rebuilt_plan.free_events.first
                    assert_equal addition_time, task.addition_time
                    assert_equal addition_time, task.start_event.addition_time
                    assert_equal addition_time, event.addition_time
                end

                it "propagates new relations" do
                    parent, child = Tasks::Simple.new(id: 'parent'), Tasks::Simple.new(id: 'child')
                    local_plan.add(parent)
                    local_plan.add(child)
                    process_logged_events

                    parent.depends_on child
                    parent.start_event.signals child.start_event
                    process_logged_events

                    assert_equal 2, rebuilt_plan.known_tasks.size
                    parent = rebuilt_plan.find_tasks.with_arguments(id: 'parent').first
                    child  = rebuilt_plan.find_tasks.with_arguments(id: 'child').first
                    assert_child_of parent, child, TaskStructure::Dependency
                    assert_child_of parent.start_event, child.start_event, EventStructure::Signal
                end

                it "propagates edge info change" do
                    parent, child = Tasks::Simple.new(id: 'parent'), Tasks::Simple.new(id: 'child')
                    parent.depends_on child, model: Task
                    local_plan.add(parent)
                    process_logged_events

                    parent.depends_on child, model: Tasks::Simple
                    process_logged_events

                    parent = rebuilt_plan.find_tasks.with_arguments(id: 'parent').first
                    child  = rebuilt_plan.find_tasks.with_arguments(id: 'child').first
                    assert_equal [[Tasks::Simple], Hash.new], parent[child, TaskStructure::Dependency][:model]
                end

                it "propagates relation removal" do
                    parent, child = Tasks::Simple.new(id: 'parent'), Tasks::Simple.new(id: 'child')
                    parent.depends_on child, model: Task
                    local_plan.add(parent)
                    process_logged_events

                    parent.remove_child child
                    process_logged_events

                    parent = rebuilt_plan.find_tasks.with_arguments(id: 'parent').first
                    child  = rebuilt_plan.find_tasks.with_arguments(id: 'child').first
                    refute_child_of parent, child, TaskStructure::Dependency
                end

                it "propagates the chain mission/permanent status of tasks" do
                    local_plan.add_mission(task = Task.new)
                    process_logged_events
                    r_task = rebuilt_plan.find_tasks.first
                    assert r_task

                    assert rebuilt_plan.mission?(r_task)
                    local_plan.unmark_mission task
                    process_logged_events
                    assert !rebuilt_plan.mission?(r_task)
                    local_plan.add_permanent(task)
                    process_logged_events
                    assert rebuilt_plan.permanent?(r_task)
                    local_plan.unmark_permanent(task)
                    process_logged_events
                    assert !rebuilt_plan.permanent?(r_task)
                end

                it "propagates the chain permanent status of events" do
                    local_plan.add_permanent(event = EventGenerator.new)
                    process_logged_events
                    r_event = rebuilt_plan.free_events.first
                    assert r_event

                    local_plan.unmark_permanent(event)
                    process_logged_events
                    assert !rebuilt_plan.permanent?(r_event)
                    local_plan.add_permanent(event)
                    process_logged_events
                    assert rebuilt_plan.permanent?(r_event)
                end

                it "stores a garbaged task in the plan structure" do
                    local_plan.add(task = Task.new)
                    process_logged_events
                    r_task = rebuilt_plan.known_tasks.first
                    local_plan.execution_engine.garbage_collect
                    process_logged_events
                    assert rebuilt_plan.garbaged_objects.include?(r_task)
                end

                it "remove a non-garbaged task immediately" do
                    local_plan.add(task = Task.new)
                    process_logged_events
                    r_task = rebuilt_plan.known_tasks.first
                    local_plan.remove_object(task)
                    process_logged_events
                    assert !rebuilt_plan.include?(r_task)
                end

                it "does not remove a garbaged task until #clear_integrated is called" do
                    local_plan.add(task = Task.new)
                    process_logged_events
                    r_task = rebuilt_plan.known_tasks.first
                    local_plan.execution_engine.garbage_collect
                    process_logged_events
                    assert rebuilt_plan.include?(r_task)
                    rebuilt_plan.clear_integrated
                    assert !rebuilt_plan.include?(r_task)
                    assert rebuilt_plan.garbaged_objects.empty?
                end

                it "stores a garbaged event in the plan structure" do
                    local_plan.add(event = EventGenerator.new)
                    process_logged_events
                    r_event = rebuilt_plan.free_events.first
                    local_plan.execution_engine.garbage_collect
                    process_logged_events
                    assert rebuilt_plan.garbaged_objects.include?(r_event)
                end

                it "does not remove a garbaged event until #clear_integrated is called" do
                    local_plan.add(event = EventGenerator.new)
                    process_logged_events
                    r_event = rebuilt_plan.free_events.first
                    local_plan.execution_engine.garbage_collect
                    process_logged_events
                    assert rebuilt_plan.include?(r_event)
                    rebuilt_plan.clear_integrated
                    assert !rebuilt_plan.include?(r_event)
                    assert rebuilt_plan.garbaged_objects.empty?
                end

                it "remove a non-garbaged task immediately" do
                    local_plan.add(event = EventGenerator.new)
                    process_logged_events
                    r_event = rebuilt_plan.free_events.first
                    local_plan.remove_object(event)
                    process_logged_events
                    assert !rebuilt_plan.include?(r_event)
                end

                it "propagates argument updates" do
                    task_m = Roby::Task.new_submodel { argument :test }
                    local_plan.add(task = task_m.new)
                    process_logged_events
                    r_task = rebuilt_plan.find_tasks.first
                    task.test = 10
                    process_logged_events
                    assert_equal 10, r_task.test
                end

                it "propagates the freezing of delayed arguments" do
                    local_plan.add(task = Tasks::Simple.new(id: DefaultArgument.new(10)))
                    process_logged_events
                    r_task = rebuilt_plan.find_tasks.first
                    assert !r_task.arguments.static?
                    task.freeze_delayed_arguments
                    process_logged_events
                    assert r_task.arguments.static?
                    assert_equal 10, r_task.id
                end
            end

            describe "transaction structure" do
                it "can duplicate a merged plan" do
                    local_plan.in_transaction do |t|
                        parent, child = Tasks::Simple.new(id: 'parent'), Tasks::Simple.new(id: 'child')
                        parent.depends_on child
                        parent.start_event.signals child.start_event
                        t.add(parent)
                        t.commit_transaction
                    end
                    process_logged_events

                    assert_equal 2, rebuilt_plan.known_tasks.size
                    parent = rebuilt_plan.find_tasks.with_arguments(id: 'parent').first
                    child  = rebuilt_plan.find_tasks.with_arguments(id: 'child').first
                    assert_child_of parent, child, TaskStructure::Dependency
                    assert_child_of parent.start_event, child.start_event, EventStructure::Signal
                end

                it "propagates new relations" do
                    parent, child = Tasks::Simple.new(id: 'parent'), Tasks::Simple.new(id: 'child')
                    local_plan.add(parent)
                    local_plan.add(child)
                    process_logged_events

                    local_plan.in_transaction do |t|
                        t[parent].depends_on t[child]
                        t[parent].start_event.signals t[child].start_event
                        t.commit_transaction
                    end
                    process_logged_events

                    assert_equal 2, rebuilt_plan.known_tasks.size
                    parent = rebuilt_plan.find_tasks.with_arguments(id: 'parent').first
                    child  = rebuilt_plan.find_tasks.with_arguments(id: 'child').first
                    assert_child_of parent, child, TaskStructure::Dependency
                    assert_child_of parent.start_event, child.start_event, EventStructure::Signal
                end

                it "propagates edge info change" do
                    parent, child = Tasks::Simple.new(id: 'parent'), Tasks::Simple.new(id: 'child')
                    parent.depends_on child, model: Task
                    local_plan.add(parent)
                    process_logged_events

                    local_plan.in_transaction do |t|
                        t[parent].depends_on t[child], model: Tasks::Simple
                        t.commit_transaction
                    end
                    process_logged_events

                    parent = rebuilt_plan.find_tasks.with_arguments(id: 'parent').first
                    child  = rebuilt_plan.find_tasks.with_arguments(id: 'child').first
                    assert_equal [[Tasks::Simple], Hash.new], parent[child, TaskStructure::Dependency][:model]
                end

                it "propagates relation removal" do
                    parent, child = Tasks::Simple.new(id: 'parent'), Tasks::Simple.new(id: 'child')
                    parent.depends_on child, model: Task
                    local_plan.add(parent)
                    process_logged_events

                    local_plan.in_transaction do |t|
                        t[parent].remove_child t[child]
                        t.commit_transaction
                    end
                    process_logged_events

                    parent = rebuilt_plan.find_tasks.with_arguments(id: 'parent').first
                    child  = rebuilt_plan.find_tasks.with_arguments(id: 'child').first
                    refute_child_of parent, child, TaskStructure::Dependency
                end

                it "propagates the chain mission/permanent status of tasks" do
                    local_plan.add_mission(task = Task.new)
                    process_logged_events
                    r_task = rebuilt_plan.find_tasks.first
                    assert r_task

                    assert rebuilt_plan.mission?(r_task)
                    local_plan.in_transaction do |t|
                        t.unmark_mission t[task]
                        t.commit_transaction
                    end
                    process_logged_events
                    assert !rebuilt_plan.mission?(r_task)

                    local_plan.in_transaction do |t|
                        t.add_permanent(t[task])
                        t.commit_transaction
                    end
                    process_logged_events
                    assert rebuilt_plan.permanent?(r_task)

                    local_plan.in_transaction do |t|
                        t.unmark_permanent(t[task])
                        t.commit_transaction
                    end
                    process_logged_events
                    assert !rebuilt_plan.permanent?(r_task)
                end

                it "propagates the chain permanent status of events" do
                    local_plan.add_permanent(event = EventGenerator.new)
                    process_logged_events
                    r_event = rebuilt_plan.free_events.first
                    assert r_event

                    local_plan.in_transaction do |t|
                        t.unmark_permanent(t[event])
                        t.commit_transaction
                    end
                    process_logged_events
                    assert !rebuilt_plan.permanent?(r_event)

                    local_plan.in_transaction do |t|
                        t.add_permanent(t[event])
                        t.commit_transaction
                    end
                    process_logged_events
                    assert rebuilt_plan.permanent?(r_event)
                end

                it "propagates argument updates" do
                    task_m = Roby::Task.new_submodel { argument :test }
                    local_plan.add(task = task_m.new)
                    process_logged_events
                    r_task = rebuilt_plan.find_tasks.first

                    local_plan.in_transaction do |t|
                        t[task].test = 10
                        t.commit_transaction
                    end
                    process_logged_events
                    assert_equal 10, task.test
                    assert_equal 10, r_task.test
                end

                it "propagates the freezing of delayed arguments" do
                    local_plan.add(task = Tasks::Simple.new(id: DefaultArgument.new(10)))
                    process_logged_events
                    r_task = rebuilt_plan.find_tasks.first
                    assert !r_task.arguments.static?

                    local_plan.in_transaction do |t|
                        t[task].freeze_delayed_arguments
                        t.commit_transaction
                    end
                    process_logged_events
                    assert task.arguments.static?
                    assert r_task.arguments.static?
                    assert_equal 10, r_task.id
                end
            end

            describe "runtime information" do
                it "propagates failed-to-start information" do
                    local_plan.add(task = Tasks::Simple.new)
                    process_logged_events
                    r_task = rebuilt_plan.known_tasks.first

                    task.start_event.emit_failed(ArgumentError.new)
                    process_logged_events
                    assert_equal r_task, rebuilt_plan.failed_to_start[0][0]
                    assert_kind_of EmissionFailed, rebuilt_plan.failed_to_start[0][1]
                    assert_kind_of ArgumentError, rebuilt_plan.failed_to_start[0][1].original_exceptions[0]
                end

                it "propagates event emission" do
                    local_plan.add(generator = EventGenerator.new)
                    event = generator.emit(flexmock(droby_dump: 42))
                    process_logged_events
                    r_generator = rebuilt_plan.free_events.first
                    assert r_generator.emitted?
                    assert_equal [42], r_generator.last.context
                end

                describe "handling of event propagation" do
                    attr_reader :source, :target, :r_source, :r_target
                    before do
                        local_plan.add(@source = EventGenerator.new)
                        local_plan.add(@target = EventGenerator.new(true))
                        process_logged_events
                        @r_source = rebuilt_plan.free_events.find { |e| !e.controlable? }
                        @r_target = rebuilt_plan.free_events.find { |e| e.controlable? }
                    end

                    it "propagates call information" do
                        source.on { target.call }
                        source.emit
                        process_logged_events

                        assert rebuilt_plan.propagated_events.find { |is_forward, events, generator|
                            !is_forward &&
                                generator == r_target &&
                                events.size == 1 &&
                                events.first.generator == r_source &&
                                events.first.propagation_id == source.last.propagation_id
                        }
                    end

                    it "propagates signalling information" do
                        source.signals target
                        source.emit
                        process_logged_events

                        assert rebuilt_plan.propagated_events.any? { |is_forward, events, generator|
                            !is_forward &&
                                generator == r_target &&
                                events.size == 1 &&
                                events.first.generator == r_source &&
                                events.first.propagation_id == source.last.propagation_id
                        }
                    end

                    it "propagates chained emission information" do
                        source.on { target.emit }
                        source.emit
                        process_logged_events

                        assert rebuilt_plan.propagated_events.any? { |is_forward, events, generator|
                            is_forward &&
                                generator == r_target &&
                                events.size == 1 &&
                                events.first.generator == r_source &&
                                events.first.propagation_id == source.last.propagation_id
                        }
                    end

                    it "propagates forwarding information" do
                        source.forward_to target
                        source.emit
                        process_logged_events

                        assert rebuilt_plan.propagated_events.any? { |is_forward, events, generator|
                            is_forward &&
                                generator == r_target &&
                                events.size == 1 &&
                                events.first.generator == r_source &&
                                events.first.propagation_id == source.last.propagation_id
                        }
                    end
                end
            end

            describe "marshalling and demarshalling behaviour" do
                it "dumps tasks using IDs once they are added to the plan" do
                    local_plan.add(task = Task.new)
                    assert_equal RemoteDRobyID.new(nil, task.droby_id),
                        event_logger.marshal.dump(task)
                end

                it "dumps task events using IDs once they are added to the plan" do
                    local_plan.add(event = EventGenerator.new)
                    assert_equal RemoteDRobyID.new(nil, event.droby_id),
                        event_logger.marshal.dump(event)
                end

                it "dumps free events using IDs once they are added to the plan" do
                    local_plan.add(task = Task.new)
                    assert_equal RemoteDRobyID.new(nil, task.start_event.droby_id),
                        event_logger.marshal.dump(task.start_event)
                end

                it "dumps tasks using their ID in the finalization message" do
                    local_plan.add(task = Task.new)
                    process_logged_events
                    local_plan.remove_object(task)
                    cycle_info = flush_cycle_events
                    assert cycle_info.each_slice(4).find { |m, _, _, args| m == :finalized_task && args == [local_plan.droby_id, RemoteDRobyID.new(nil, task.droby_id)] }
                end

                it "dumps task events using their ID in the finalization message" do
                    local_plan.add(task = Task.new)
                    process_logged_events
                    local_plan.remove_object(task)
                    cycle_info = flush_cycle_events
                    assert cycle_info.each_slice(4).find { |m, _, _, args| m == :finalized_event && args == [local_plan.droby_id, RemoteDRobyID.new(nil, task.start_event.droby_id)] }
                end

                it "dumps events using their ID in the finalization message" do
                    local_plan.add(event = EventGenerator.new)
                    process_logged_events
                    local_plan.remove_object(event)
                    cycle_info = flush_cycle_events
                    assert cycle_info.each_slice(4).find { |m, _, _, args| m == :finalized_event && args == [local_plan.droby_id, RemoteDRobyID.new(nil, event.droby_id)] }
                end

                it "dumps tasks fully once the task has been finalized" do
                    local_plan.add(task = Task.new)
                    local_plan.remove_object(task)
                    flexmock(task).should_receive(:droby_dump).once.and_return(m = flexmock)
                    assert_equal m, event_logger.marshal.dump(task)
                end

                it "dumps task events fully once they have been finalized" do
                    local_plan.add(task = Task.new)
                    local_plan.remove_object(task)
                    flexmock(task.start_event).should_receive(:droby_dump).once.and_return(m = flexmock)
                    assert_equal m, event_logger.marshal.dump(task.start_event)
                end

                it "dumps free events fully once they have been finalized" do
                    local_plan.add(event = EventGenerator.new)
                    local_plan.remove_object(event)
                    flexmock(event).should_receive(:droby_dump).once.and_return(m = flexmock)
                    assert_equal m, event_logger.marshal.dump(event)
                end
            end
        end
    end
end
