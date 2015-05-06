require 'roby/distributed'
require 'stringio'
require 'roby/schedulers/state'

module Roby
    module LogReplay
        module ReplayPlan
            # The set of tasks that have been finalized since the last call to
            # #clear_integrated
            attribute(:finalized_tasks)  { ValueSet.new }
            # The set of free event generators that have been finalized since
            # the last call to #clear_integrated
            attribute(:finalized_events) { ValueSet.new }
            # The set of objects (tasks and events) that got garbage collected.
            # For display purposes, they only get removed from the plan at the
            # next cycle.
            attribute(:garbaged_objects) { ValueSet.new }
            # The set of events emitted since the last call to
            # #clear_integrated
            attribute(:emitted_events)   { Array.new }
            # The set of event propagations that have been recorded since the
            # last call to # #clear_integrated
            attribute(:propagated_events) { Array.new }
            # The set of events that have been postponed since the last call to
            # #clear_integrated
            attribute(:postponed_events) { Array.new }
            # The set of events that have failed to emit since the last call to
            # #clear_integrated
            attribute(:failed_emissions) { Array.new }
            # The set of tasks that failed to start since the last call to
            # #clear_integrated
            attribute(:failed_to_start) { Array.new }
            # The list of scheduler states since the last call to
            # #clear_integrated
            #
            # @return [Array<Schedulers::State>]
            attribute(:scheduler_states) { Array.new }

            def self_owned?; true end

            def executable?; false end

            def copy_to(copy)
                copy.extend ReplayPlan
                super
                [:finalized_events, :finalized_tasks,
                    :emitted_events,
                    :propagated_events, :postponed_events,
                    :failed_emissions, :failed_to_start, :scheduler_states].each do |m|
                    copy.send("#{m}=", send(m).dup)
                end
            end

            def finalize_object(object, timestamp = nil)
                # Don't do anything. Due to the nature of the plan replay
                # mechanisms, tasks that are already finalized can very well be
                # kept included in plans. That is something that would be caught
                # by the finalization paths in Plan
                object.clear_relations
            end

            def clear
                super
                clear_integrated
            end

            # A consolidated representation of the states in {#scheduler_states}
            #
            # It removes duplicates, and removes "non-scheduled" reports for
            # tasks that have in fine been scheduled
            def consolidated_scheduler_state
                state = Schedulers::State.new
                scheduler_states.each do |s|
                    state.pending_non_executable_tasks = s.pending_non_executable_tasks
                    s.called_generators.each do |g|
                        state.non_scheduled_tasks.delete(g.task)
                        state.called_generators << g
                    end
                    s.non_scheduled_tasks.each do |task, reports|
                        reports.each do |report|
                            if !state.non_scheduled_tasks[task].include?(report)
                                state.non_scheduled_tasks[task] << report
                            end
                        end
                    end
                end
                state
            end

            def clear_integrated
                emitted_events.clear
                finalized_tasks.clear
                finalized_events.clear
                propagated_events.clear
                postponed_events.clear
                failed_emissions.clear
                failed_to_start.clear
                scheduler_states.clear

                garbaged_objects.each do |object|
                    # Do remove the GCed object. We use object.finalization_time
                    # to store the actual finalization time. Pass it again to
                    # #remove_object so that it does not get reset to Time.now
                    object.plan.remove_object(object, object.finalization_time)
                end
                garbaged_objects.clear
            end
        end

        module ReplayTask
            def current_display_state(current_time)
                if failed_to_start?
                    if failed_to_start_time > current_time
                        return :pending
                    else
                        return :finished
                    end
                end

                last_emitted_event = nil
                history.each do |ev|
                    break if ev.time > current_time
                    last_emitted_event = ev
                end

                if !last_emitted_event
                    return :pending
                end

                gen = last_emitted_event.generator
                if !gen
                    return :pending
                elsif gen.terminal?
                    return [:success, :finished, :running].find { |flag| send("#{flag}?") } 
                else
                    return :running
                end
            end
        end

        # Support to unmarshal transactions while doing log replay
        #
        # This is normally forbidden in dRoby. This module adds support for it
        # in case of log replay. It gets mixed-in Transaction::DRoby instances
        # in PlanRebuilder#local_object
        module TransactionLogRebuilder
            class ReplayedTransaction < Roby::Plan
                include ReplayPlan
            end
            def proxy(object_manager)
                ReplayedTransaction.new
            end
        end

        # Support to unmarshal transactions while doing log replay
        #
        # Plan objects, while being unmarshalled, usually add themselves to
        # whatever plan they are part of
        #
        # This is fine *unless* you want to support transactions without having
        # to go through the normal transaction commit process. So, we disable
        # that and make sure the plan rebuilder takes care of it
        module PlanObjectLogRebuilder
            def update(peer, proxy)
                BasicObject::DRoby.instance_method(:update).bind(self).call(peer, proxy)
            end
        end

        module PlanReplayTaskModel
            def create_remote_event(symbol, peer, marshalled_event)
                if !self.model.has_event?(symbol)
                    event_model = self.model.
                        event(symbol, :controlable => marshalled_event.controlable)
                else
                    event_model = self.model.find_event_model(symbol)
                end

                generator = Roby::TaskEventGenerator.new(self, event_model)
                @bound_events[symbol] = generator
                generator.plan = plan
                generator
            end
            def override_remote_event(symbol, peer, marshalled_event)
                # Check if we need to override the model, or only the bound
                # event
                if !self.model.event_model(symbol).controlable? && marshalled_event.controlable
                    terminal = self.model.event_model(symbol).terminal?
                    event_model = self.model.
                        event(symbol, :controlable => marshalled_event.controlable,
                              :terminal => terminal)
                else
                    event_model = self.model.event_model(symbol)
                end

                if @bound_events[symbol]
                    @bound_events[symbol].override_model(event_model)
                    @bound_events[symbol]
                else
                    generator = Roby::TaskEventGenerator.new(self, event_model)
                    @bound_events[symbol] = generator
                end
            end
        end

        class PlanReplayPeer < Roby::Distributed::RemoteObjectManager
            def connected?
                false
            end

            def transmit(*args)
            end

            def local_model(parent_model, name, &block)
                new_model = Roby::Distributed::DRobyModel.anon_model_factory(parent_model, name, false)
                if new_model <= Roby::Task && !new_model.has_ancestor?(PlanReplayTaskModel)
                    new_model.include(PlanReplayTaskModel)
                end
                new_model
            end

            def local_server
            end
            def remote_name
                "log_replay"
            end
            def name; remote_name end

	    def local_object(object, create = true)
		return nil unless object

                if object.kind_of?(Roby::Transaction::DRoby)
                    # Cannot use the normal proxying mechanism for transactions,
                    # as it is not supported on dRoby
                    # Extend this DRoby object with unmarshalling support
                    object.extend TransactionLogRebuilder
                end

                if object.kind_of?(Roby::PlanObject::DRoby)
                    object.extend PlanObjectLogRebuilder
                end
                if object.kind_of?(Roby::Task::Proxying::DRoby)
                    throw :ignored
                end
                if object.kind_of?(Roby::TaskEventGenerator::DRoby) && object.task.kind_of?(Roby::Task::Proxying::DRoby)
                    throw :ignored
                end
                super

            rescue Roby::Distributed::MissingProxyError
                throw :ignored
            end
        end

	# This class rebuilds a plan-like structure from events saved by a
	# FileLogger object.
        #
        # The data can be fed in two ways. From an EventFileStream object
        # reading a file, passed to #analyze_stream, or on a per-cycle basis,
        # which cycle being passed to #push_data
	class PlanRebuilder
            # The PlanReplayPeer that is being used to do RemoteID-to-local
            # object mapping
	    attr_reader :manager
            # The Plan object into which we rebuild information
            attr_reader :plan
            # For future use, right now it is [plan]
            attr_reader :plans
            # A list of snapshots that represent cycles where something happened
            attr_reader :history
            # A hash representing the statistics for this execution cycle
            attr_reader :stats
            # A representation of the state for this execution cycle
            attr_reader :state
            # A hash that stores (at a high level) what changed since the last
            # call to #clear_integrated
            #
            # Don't manipulate directly, but use the announce_* and
            # has_*_changes? methods
            attr_reader :changes
            # A set of EventFilter objects that list the labelling objects /
            # filters applied on the event stream
            attr_reader :event_filters

	    def initialize(options = Hash.new)
                if !options.kind_of?(Hash)
                    options = { :main => options }
                end
                options = Kernel.validate_options options,
                    :plan => Roby::Plan.new,
                    :main => true

                @plan = options[:plan]
                @plan.extend ReplayPlan
                @plans = [@plan]
                @manager = create_remote_object_manager
                if options[:main]
                    Distributed.setup_log_replay(manager)
                end
                Distributed.disable_ownership
                @history = Array.new
                clear_changes
                @event_filters = Array.new
                @filter_matches = Array.new
                @filter_exclusions = Array.new
                @all_relations = Set.new
                @stats = Hash.new
	    end

            attr_reader :all_relations

            def find_model(stream, model_name, &block)
                analyze_stream(stream) do
                    model = Roby::Distributed::DRobyModel.local_to_remote.find { |model, (name, id)| name =~ model_name }
                    if model
                        return model.first
                    end
                end
            end

            def analyze_stream(event_stream, until_cycle = nil)
                while !event_stream.eof? && (!until_cycle || (cycle_index && cycle_index == until_cycle))
                    begin
                        data = event_stream.read
                        interesting = process(data)
                        if block_given?
                            interesting = yield
                        end

                        if interesting
                            relations = if !has_structure_updates? && !history.empty?
                                            history.last.relations
                                        end
                                
                            history << snapshot(relations)
                        end

                    ensure
                        clear_integrated
                    end
                end
            end

            # The time of the first processed cycle
            def start_time
                @start_time
            end

            # The starting time of the last processed cycle
            def cycle_start_time
                Time.at(*stats[:start])
            end

            # The time of the last processed log item
            attr_reader :current_time

            # The starting time of the last processed cycle
            def cycle_end_time
                Time.at(*stats[:start]) + stats[:end]
            end

            # The cycle index of the last processed cycle
            def cycle_index
                stats[:cycle_index]
            end

            # True if there are stuff recorded in the last played cycles that
            # demand a snapshot to be created
            def has_interesting_events?
                has_structure_updates? || has_event_propagation_updates?
            end

            # Push one cycle worth of data
            def push_data(data)
                process(data)
                if has_interesting_events? || @last_cycle_snapshotted
                    relations = if !has_structure_updates? && !history.empty?
                                    history.last.relations
                                end
                    history << snapshot(relations)
                    result = true
                end
                @last_cycle_snapshotted = has_interesting_events?

                clear_integrated
                result
            end

            PlanRebuilderSnapshot = Struct.new :stats, :state, :plan, :relations

            class PlanRebuilderSnapshot
                def apply(plan)
                    relations.each do |rel_graph, rel_data|
                        rel_graph.clear
                        rel_data.copy_to(rel_graph)
                    end
                    plan.clear
                    self.plan.copy_to(plan)
                end
            end

            # Returns a copy of this plan rebuilder's state (including the plan
            # itself and the remote object manager).
            #
            # This snapshot can be used to synchronize this plan rebuilder state
            # with #apply_snapshot
            def snapshot(reused_relation_graphs = nil)
                plan = self.plan.dup
                plan.extend ReplayPlan

                if reused_relation_graphs
                    relations = reused_relation_graphs
                else
                    relations = Hash.new
                    all_relations.each do |rel|
                        relations[rel] = rel.dup
                    end
                end

                return PlanRebuilderSnapshot.new(stats, state, plan, relations)
            end

            def create_remote_object_manager
		manager = PlanReplayPeer.new(plan)
                manager.use_local_sibling = false
                manager.proxies[Distributed.remote_id] = manager
                manager
            end
	    
	    def clear
                plans.each(&:clear)
                manager.clear
                history.clear
	    end

            # Processes one cycle worth of data coming from an EventStream, and
            # builds the corresponding plan representation
            #
            # It returns true if there was something noteworthy in there, and
            # false otherwise.
	    def process(data)
		data.each_slice(4) do |m, sec, usec, args|
                    process_one_event(m, sec, usec, args)
		end
                has_event_propagation_updates? || has_structure_updates?
	    end

            def process_one_event(m, sec, usec, args)
                time = Time.at(sec, usec)
                @current_time = time
                reason = catch :ignored do
                    begin
                        if respond_to?(m)
                            send(m, time, *args)
                        end
                    rescue Exception => e
                        display_args = args.map do |obj|
                            case obj
                            when NilClass then 'nil'
                            when Time then obj.to_hms
                            when DRbObject then obj.inspect
                            else (obj.to_s rescue "failed_to_s")
                            end
                        end

                        raise e, "#{e.message} while serving #{m}(#{display_args.join(", ")})", e.backtrace
                    end
                    nil
                end
                if reason
                    Roby.warn "Ignored #{m}(#{args.join(", ")}): #{reason}"
                end
            end

	    def local_object(object, create = true)
                return manager.local_object(object, create)
	    end

	    def clear_integrated
                clear_changes
                if modified_plans = plans.find_all { |p| !p.garbaged_objects.empty? }
                    modified_plans.each do |p|
                        announce_structure_update(p)
                        announce_state_update(p)
                    end
                end
                plans.each(&:clear_integrated)
                filter_matches.clear
                filter_exclusions.clear
	    end

            def clear_changes
                @changes =
                    Hash[:state => Hash.new,
                     :structure => Hash.new,
                     :event_propagation => Hash.new]
            end

	    def inserted_tasks(time, plan, task)
		plan = local_object(plan)
                task = local_object(task)
		plan.add_mission( task )
                task.addition_time = time
                announce_structure_update(plan)
	    end
	    def discarded_tasks(time, plan, task)
		plan = local_object(plan)
		plan.remove_mission(local_object(task))
                announce_structure_update(plan)
	    end
	    def replaced_tasks(time, plan, from, to)
		plan = local_object(plan)
                announce_structure_update(plan)
	    end
	    def added_events(time, plan, events)
		plan = local_object(plan)
		events.each do |ev| 
                    ev = local_object(ev)
		    plan.add(ev)
                    ev.addition_time = ev
                    if ev.root_object?
                        announce_structure_update(plan)
                    end
		end
	    end
	    def added_tasks(time, plan, tasks)
		plan = local_object(plan)
		local_tasks = tasks.map do |remote_task| 
                    task = local_object(remote_task)
                    if task.plan
                        task.plan.known_tasks.delete(task)
                    end
                    task
                end
                local_tasks.each do |task|
		    plan.add(task)
                    task.addition_time = time
                    task.extend ReplayTask
		end
                announce_structure_update(plan)
	    end
	    def garbage(time, plan, object)
                plan = local_object(plan)
                object = local_object(object)
                plan.garbaged_objects << object
	    end
	    def finalized_event(time, plan, event_id)
		event = local_object(event_id)
		plan  = local_object(plan)
                event.finalization_time = time
                if !plan.garbaged_objects.include?(event) && event.root_object?
                    plan.finalized_events << event
                    plan.remove_object(event)
                    announce_structure_update(plan)
                end
                manager.removed_sibling(event_id)
	    end
	    def finalized_task(time, plan, task_id)
		task = local_object(task_id)
		plan = local_object(plan)
                task.finalization_time = time
                if !plan.garbaged_objects.include?(task)
                    plan.finalized_tasks << task
                    plan.remove_object(task)
                    announce_structure_update(plan)
                end
                manager.removed_sibling(task_id)
	    end
	    def added_transaction(time, plan, trsc)
		plan = local_object(plan)
		trsc = local_object(trsc, true)
                plans << trsc
	    end
	    def removed_transaction(time, plan, trsc_id)
		plan = local_object(plan)
		trsc = local_object(trsc_id)
		plans.delete(trsc)
                manager.removed_sibling(trsc_id)
	    end

	    GENERATOR_TO_STATE = { :start => :started,
		:success => :success,
		:stop => :finished }

            def task_failed_to_start(time, task, reason)
                task   = local_object(task)
                reason = local_object(reason)
                task.plan.failed_to_start << [task, reason]
                task.failed_to_start!(reason, time)
                announce_event_propagation_update(task.plan)
            end

            def task_arguments_updated(time, task, key, value)
                task = local_object(task)
                task.arguments.values[key] = value
            end

	    def added_task_child(time, parent, rel, child, info)
		parent = local_object(parent)
		child  = local_object(child)
		if !parent   then throw :ignored, "unknown parent"
		elsif !child then throw :ignored, "unknown child"
		end

		rel    = rel.first if rel.kind_of?(Array)
		rel    = local_object(rel)
		parent.add_child_object(child, rel, info)
                all_relations << rel
                announce_structure_update(parent.plan)
                return parent, rel, child
	    end

	    def removed_task_child(time, parent, rel, child)
		parent = local_object(parent)
		child  = local_object(child)
		rel    = rel.first if rel.kind_of?(Array)
		rel    = local_object(rel)
                if !plan.garbaged_objects.include?(parent) && !plan.garbaged_objects.include?(child)
                    parent.remove_child_object(child, rel)
                    announce_structure_update(parent.plan)
                end
                return parent, rel, child
	    end

            def updated_task_relation(time, parent, rel, child, info)
		parent = local_object(parent)
		child  = local_object(child)
                info   = local_object(info)
		rel    = rel.first if rel.kind_of?(Array)
		rel    = local_object(rel)
                if !rel.linked?(parent, child)
                    rel.link(parent, child, info)
                else
                    parent[child, rel] = info
                end
            end

	    def added_event_child(time, parent, rel, child, info)
		parent = local_object(parent)
		child  = local_object(child)
		rel    = rel.first if rel.kind_of?(Array)
		rel    = local_object(rel)
                all_relations << rel
		parent.add_child_object(child, rel, info)
	    end

	    def removed_event_child(time, parent, rel, child)
		parent = local_object(parent)
		child  = local_object(child)
                rel    = local_object(rel)
                if !plan.garbaged_objects.include?(parent) && !plan.garbaged_objects.include?(child)
                    parent.remove_child_object(child, rel.first)
                end
	    end
	    def added_owner(time, object, peer)
		object = local_object(object)
		object.owners << peer
	    end
	    def removed_owner(time, object, peer)
		object = local_object(object)
		object.owners.delete(peer)
	    end

            def cycle_end(time, timings)
                @state = timings.delete(:state)
                @stats = timings
                @start_time ||= self.cycle_start_time
                announce_state_update(plan)
            end

            def self.update_type(type)
                define_method("announce_#{type}_update") do |plan|
                    @changes[type][plan] = true
                end
                define_method("has_#{type}_updates?") do |plan = nil|
                    if plan
                        !!@changes[type][plan]
                    else
                        !!@changes[type].each_value.any? { |b| b }
                    end
                end
            end
            ##
            # :method: announce_structure_update
            ##
            # :method: has_structure_updates?
            update_type :structure
            ##
            # :method: announce_state_update
            ##
            # :method: has_state_updates?
            update_type :state
            ##
            # :method: announce_event_propagation_update
            ##
            # :method: has_event_propagation_updates?
            update_type :event_propagation

            PROPAG_SIGNAL   = 1
            PROPAG_FORWARD  = 2
            PROPAG_CALLING  = 3
            PROPAG_EMITTING = 4
            PROPAG_ORDERING = {
                PROPAG_SIGNAL => [],
                PROPAG_FORWARD => [],
                PROPAG_CALLING => [PROPAG_SIGNAL],
                PROPAG_EMITTING => [PROPAG_SIGNAL, PROPAG_FORWARD, PROPAG_CALLING]
            }

            EVENT_CONTINGENT  = 0
            EVENT_CONTROLABLE = 1
            EVENT_CALLED      = 2
            EVENT_EMITTED     = 4
            EVENT_CALLED_AND_EMITTED = EVENT_CALLED | EVENT_EMITTED

            FAILED_EMISSION   = 8

            attr_reader :filter_matches
            attr_reader :filter_exclusions

	    def add_internal_propagation(flag, generator, source_generators)
		generator = local_object(generator)
		if source_generators && !source_generators.empty?
		    source_generators = source_generators.map { |source_generator| local_object(source_generator) }.
                        delete_if { |gen| gen == generator }
                    if !source_generators.empty?
                        has_superseding_event = generator.plan.propagated_events.find do |fl, src, g|
                            PROPAG_ORDERING[flag].include?(fl) && g == generator && src == source_generators
                        end
                        if !has_superseding_event
                            generator.plan.propagated_events << [flag, source_generators, generator]
                        end
                    end
		end
                return generator, source_generators
	    end
	    def generator_calling(*args)
		if args.size == 3
		    time, generator, context = *args
		    source_generators = []
		else
		    time, generator, source_generators, context = *args
		end

		generator, source_generators =
                    add_internal_propagation(PROPAG_CALLING, generator, source_generators)

                filtering_result = filter_event(generator)
                source_filtering = source_generators.map { |ev| filter_event(ev) }
                if filtering_result.any? { |res| res != :ignored } ||
                   (filtering_result.empty? && source_filtering.any? { |res| res != :ignored })
                    announce_event_propagation_update(generator.plan)
                    filter_matches << [time, generator, filtering_result]
                else
                    filter_exclusions << generator
                end
	    end
	    def generator_emitting(*args)
		if args.size == 3
		    time, generator, context = *args
		    source_generators = []
		else
		    time, generator, source_generators, context = *args
		end

		generator, source_generators =
                    add_internal_propagation(PROPAG_EMITTING, generator, source_generators)
                filtering_result = filter_event(generator)
                source_filtering = source_generators.map { |ev| filter_event(ev) }

                if filtering_result.any? { |res| res != :ignored } ||
                   (filtering_result.empty? &&  source_filtering.any? { |res| res != :ignored })
                    announce_event_propagation_update(generator.plan)
                    filter_matches << [time, generator, filtering_result]
                else
                    filter_exclusions << generator
                end
	    end
	    def generator_signalling(time, flag, from, to, event_id, event_time, event_context)
                from = local_object(from)
                to   = local_object(to)
		from.plan.propagated_events << [PROPAG_SIGNAL, [from], to]

                if !filter_exclusions.include?(from) && !filter_exclusions.include?(to)
                    announce_event_propagation_update(from.plan)
                end
	    end
	    def generator_forwarding(time, flag, from, to, event_id, event_time, event_context)
                from = local_object(from)
                to   = local_object(to)
		from.plan.propagated_events << [PROPAG_FORWARD, [from], to]
                if !filter_exclusions.include?(from) && !filter_exclusions.include?(to)
                    announce_event_propagation_update(from.plan)
                end
	    end

	    def generator_called(time, generator, context)
                generator = local_object(generator)
		generator.plan.emitted_events << [EVENT_CALLED, generator]
                filtering_result = filter_event(generator)
                if filtering_result.any? { |res| res != :ignored }
                    announce_event_propagation_update(generator.plan)
                    filter_matches << [time, generator, filtering_result]
                else
                    filter_exclusions << generator
                end
	    end
	    def generator_fired(time, generator, event_id, event_time, event_context)
		generator = local_object(generator)

		found_pending = false
		generator.plan.emitted_events.delete_if do |flags, ev| 
		    if flags == EVENT_CALLED && generator == ev
			found_pending = true
		    end
		end
                event = generator.new(event_context, event_id, event_time)
                generator.history << event
                if generator.respond_to?(:task)
                    generator.task.update_task_status(event)
                end
		generator.plan.emitted_events << [(found_pending ? EVENT_CALLED_AND_EMITTED : EVENT_EMITTED), generator]
                announce_event_propagation_update(generator.plan)
	    end
	    def generator_postponed(time, generator, context, until_generator, reason)
                generator = local_object(generator)
		generator.plan.postponed_events << [generator, local_object(until_generator)]
                announce_event_propagation_update(generator.plan)
	    end

            def generator_emit_failed(time, generator, error)
                generator = local_object(generator)
                error = local_object(error)
                generator.plan.failed_emissions << [generator, error]
                announce_event_propagation_update(generator.plan)
            end

            def report_scheduler_state(time, plan, pending_non_executable_tasks, called_generators, non_scheduled_tasks)
                plan = local_object(plan)
                state = Schedulers::State.new
                state.pending_non_executable_tasks = local_object(pending_non_executable_tasks)
                state.called_generators = local_object(called_generators)
                state.non_scheduled_tasks = local_object(non_scheduled_tasks)

                plan.scheduler_states << state
            end

            class FilterLabel
                attr_accessor :text
                attr_accessor :color

                def load_options(options)
                    if text = options['text']
                        @text = text
                    end
                    if color = options['color']
                        @color = color
                    end
                end

                def dump_options
                    result = Hash.new
                    if @text
                        result['text'] = @text
                    end
                    if @color
                        result['color'] = @color
                    end
                    result
                end
            end

            class EventFilter
                def initialize(block = nil)
                    if block
                        @block = block
                        singleton_class.class_eval do
                            define_method(:custom_match, &block)
                        end
                    end
                    @label = FilterLabel.new
                end

                def from_task(name)
                    @task_model_name = name
                    self
                end

                def with_name(name)
                    @generator_name = name
                    self
                end

                def name(string)
                    @name = string
                    self
                end

                def label(string)
                    @label.text = string
                    self
                end

                def color(color)
                    @label.color = color
                    self
                end

                def match(generator)
                    if @task_model_name
                        if !generator.respond_to?(:task)
                            return false
                        elsif generator.task.model.ancestors.none? { |m| m.name == @task_model_name }
                            return false
                        end
                    end

                    if @generator_name
                        if !generator.respond_to?(:symbol)
                            return false
                        elsif generator.symbol != @generator_name.to_sym
                            return false
                        end
                    end

                    if respond_to?(:custom_match)
                        if !custom_match(generator)
                            return false
                        end
                    end
                    if @ignore
                        throw :filter_ignore_cycle
                    else
                        return @label
                    end
                end

                # If called, the filter will *reject* matching events instead of
                # labelling them
                def ignore
                    @ignore = true
                end

                def to_s
                    desc = []
                    if @task_model_name && @generator_name
                        desc << "#{@task_model_name}/#{@generator_name}"
                    elsif @task_model_name
                        desc << "#{@task_model_name}/*"
                    elsif @generator_name
                        desc << "*/#{@generator_name}"
                    end
                    if respond_to?(:custom_match)
                        desc << block.to_s
                    end
                    "#<EventFilter #{desc.join(" ")}>"
                end

                def load_options(options)
                    options = options.dup
                    if options.delete('ignore')
                        self.ignore
                    end

                    if label_config = options.delete('label')
                        @label.load_options(options)
                    end

                    options.each do |key, value|
                        self.send(key, value)
                    end
                end

                def dump_options
                    result = Hash.new
                    result['type']   = 'event'
                    result['ignore'] = @ignore
                    if @block
                        raise ArgumentError, "cannot dump a filter with custom block"
                    end

                    if @task_model_name
                        result['from_task'] = @task_model_name
                    end
                    if @generator_name
                        result['with_name'] = @generator_name
                    end
                    result['label'] = @label.dump_options
                    result
                end
            end

            # Adds a filter to this plan rebuilder
            def event_filter(&block)
                filter = EventFilter.new(block)
                @event_filters << filter
                filter
            end

            def filter_event(generator)
                event_filters.map do |filter|
                    result = catch(:filter_ignore_cycle) do
                        filter.match(generator)
                    end
                    result || :ignored
                end
            end

            def apply_options(options)
                filters = options['filters']
                if filters
                    filters.each do |filter_config|
                        filter_config = filter_config.dup
                        if filter_config.delete('type') == 'event'
                            new_filter = event_filter
                            new_filter.load_options(filter_config)
                        else
                            raise ArgumentError, "unknown filter type #{filter_config['type']}"
                        end
                    end
                end
            end

            def save_options
                result = Hash.new

                filters = Array.new
                event_filters.each do |filter|
                    filters << filter.dump_options
                end
                result['filters'] = filters
                result
            end
	end
    end
end

