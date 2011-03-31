require 'roby/distributed'
require 'stringio'

module Roby
    module LogReplay
        module ReplayPlan
            # The set of tasks that have been finalized since the last call to
            # #clear_integrated
            attribute(:finalized_tasks)  { ValueSet.new }
            # The set of free event generators that have been finalized since
            # the last call to #clear_integrated
            attribute(:finalized_events) { ValueSet.new }
            # The set of events emitted since the last call to
            # #clear_integrated
            attribute(:emitted_events)   { Array.new }
            # The set of event propagations that have been recorded since the
            # last call to # #clear_integrated
            attribute(:propagated_events) { Array.new }
            # The set of events that have been postponed since the last call to
            # #clear_integrated
            attribute(:postponed_events) { Array.new }

            def self_owned?; true end

            def copy_to(copy)
                mappings = super
                copy.extend ReplayPlan

                copy.finalized_events = finalized_events.map do |gen|
                    new_gen = gen.dup
                    mappings[gen] = new_gen
                    new_gen
                end.to_value_set
                copy.finalized_tasks  = finalized_tasks.map do |t|
                    new_t = t.dup
                    mappings[t] = new_t
                    t.each_event do |ev|
                        mappings[ev] = new_t.event(ev.symbol)
                    end
                    new_t
                end.to_value_set

                mapped = emitted_events.map do |flag, generator|
                    [flag, mappings[generator]]
                end
                copy.emitted_events = mapped

                mapped = propagated_events.map do |flag, source_gens, target_gen|
                    [flag, source_gens.map { |g| mappings[g] }, mappings[target_gen]]
                end
                copy.propagated_events = mapped

                mapped = postponed_events.map do |gen, until_gen|
                    [mappings[gen], mappings[until_gen]]
                end
                copy.postponed_events = mapped

                mappings
            end

            def clear
                super
                clear_integrated
            end

            def clear_integrated
                emitted_events.clear
                finalized_tasks.clear
                finalized_events.clear
                propagated_events.clear
                postponed_events.clear
            end
        end

        module PlanReplayTaskModel
            def create_remote_event(symbol, peer, marshalled_event)
                event_model = self.model.
                    event(symbol, :controlable => marshalled_event.controlable)

                generator = Roby::TaskEventGenerator.new(self, event_model)
                @bound_events[symbol] = generator
                generator.plan = plan
                generator
            end
            def override_remote_event(symbol, peer, marshalled_event)
                terminal = event(symbol).terminal?
                event_model = self.model.
                    event(symbol, :controlable => marshalled_event.controlable, :terminal => terminal)

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
        end

	# This class rebuilds a plan-like structure from events saved by a
	# FileLogger object This is compatible with the EventStream data source
	class PlanRebuilder
	    attr_reader :manager

            attr_reader :plan
            attr_reader :plans
            attr_reader :event_stream

	    attr_reader :start_time
	    attr_reader :time
	    def initialize(event_stream, main_manager = true)
                @plan = Roby::Plan.new
                @plan.extend ReplayPlan
                @plans = [@plan]
                @event_stream = event_stream
                @manager = create_remote_object_manager
                if main_manager
                    Distributed.setup_log_replay(manager)
                end
	    end

            def analyze
                result = []
                event_stream.rewind
                while !event_stream.eof?
                    data = event_stream.read
                    if process(data)
                        result << [event_stream.current_time, snapshot]
                    end
                    clear_integrated
                end
                event_stream.rewind
                result
            end

            PlanRebuilderSnapshot = Struct.new :cycle, :plan, :manager

            # Returns a copy of this plan rebuilder's state (including the plan
            # itself and the remote object manager).
            #
            # This snapshot can be used to synchronize this plan rebuilder state
            # with #apply_snapshot
            def snapshot
                plan = Roby::Plan.new
                plan.owners << manager
                mappings = self.plan.copy_to(plan)

                manager = PlanReplayPeer.new(plan)
                self.manager.copy_to(manager, mappings)
                return PlanRebuilderSnapshot.new(event_stream.current_cycle, plan, manager)
            end

            def apply_snapshot(snapshot)
                event_stream.seek_to_cycle(snapshot.cycle)
                plan.clear
                mappings = snapshot.plan.copy_to(plan)

                manager.clear
                snapshot.manager.copy_to(manager, mappings)
            end

            def create_remote_object_manager
		manager = PlanReplayPeer.new(plan)
                manager.use_local_sibling = false
                manager.proxies[Distributed.remote_id] = manager
                plan.owners << manager
                manager
            end
	    
	    def clear
                plans.each(&:clear)
                manager.clear

		@start_time = nil
		@time = nil
	    end

	    def rewind
		clear
	    end

            def eof?
                event_stream.eof?
            end

            def step
                data = event_stream.read
                process(data)
            end
	    
            # Processes one cycle worth of data coming from an EventStream, and
            # builds the corresponding plan representation
            #
            # It returns true if there was something noteworthy in there, and
            # false otherwise.
	    def process(data)
		@time = data.last[0][:start]
	        @start_time ||= @time

                done_something = false
		data.each_slice(4) do |m, sec, usec, args|
		    time = Time.at(sec, usec)
		    reason = catch :ignored do
			begin
			    if respond_to?(m)
				send(m, time, *args)
                                done_something = true
			    end
			rescue Exception => e
			    display_args = args.map do |obj|
				case obj
				when NilClass: 'nil'
				when Time: obj.to_hms
				when DRbObject: obj.inspect
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
                done_something
	    end

	    def local_object(object, create = true)
		return nil unless object

                if object.kind_of?(Roby::Task::Proxying::DRoby)
                    throw :ignored
                end
                if object.kind_of?(Roby::TaskEventGenerator::DRoby) && object.task.kind_of?(Roby::Task::Proxying::DRoby)
                    throw :ignored
                end
                object = manager.local_object(object, create)
                object

            rescue Roby::Distributed::MissingProxyError
                #puts "WARN: ignoring missing proxy error, probably due to the fact that we ignore transactions completely"
                throw :ignored
	    end

	    def clear_integrated
                updated = !plans.all? do |p|
                    p.emitted_events.empty? &&
                    p.finalized_tasks.empty? &&
                    p.finalized_events.empty? &&
                    p.propagated_events.empty? &&
                    p.postponed_events.empty?
                end
                plans.each(&:clear_integrated)
                updated
	    end

	    def inserted_tasks(time, plan, task)
		plan = local_object(plan)
		plan.add_mission( local_object(task) )
	    end
	    def discarded_tasks(time, plan, task)
		plan = local_object(plan)
		plan.remove_mission(local_object(task))
	    end
	    def replaced_tasks(time, plan, from, to)
	    end
	    def added_events(time, plan, events)
		plan = local_object(plan)
		events.each do |ev| 
		    plan.add(local_object(ev))
		end
	    end
	    def added_tasks(time, plan, tasks)
		plan = local_object(plan)
		tasks.each do |t| 
		    plan.add(local_object(t))
		end
	    end
	    def garbage_task(time, plan, task)
	    end
	    def finalized_event(time, plan, event)
		event = local_object(event)
		plan  = local_object(plan)
		if event.root_object?
                    plan.finalized_events << event
		    plan.remove_object(event)
		end
	    end
	    def finalized_task(time, plan, task)
		task = local_object(task)
		plan = local_object(plan)
                plan.finalized_tasks << task
		plan.remove_object(task)
	    end
	    def added_transaction(time, plan, trsc)
		# plan = local_object(plan)
		# trsc = local_object(trsc, true)
                # plans << trsc
	    end
	    def removed_transaction(time, plan, trsc)
		# plan = local_object(plan)
		# trsc = local_object(trsc)
		# trsc.clear_finalized(trsc.finalized_tasks, trsc.finalized_events)
		# plans.delete(trsc)
	    end

	    GENERATOR_TO_STATE = { :start => :started,
		:success => :success,
		:stop => :finished }

	    def added_task_child(time, parent, rel, child, info)
		parent = local_object(parent)
		child  = local_object(child)
		if !parent   then throw :ignored, "unknown parent"
		elsif !child then throw :ignored, "unknown child"
		end

		rel    = rel.first if rel.kind_of?(Array)
		rel    = local_object(rel)
		parent.add_child_object(child, rel, info)
                return parent, rel, child
	    end

	    def removed_task_child(time, parent, rel, child)
		parent = local_object(parent)
		child  = local_object(child)
		rel    = rel.first if rel.kind_of?(Array)
		rel    = local_object(rel)
		parent.remove_child_object(child, rel)
                return parent, rel, child
	    end
	    def added_event_child(time, parent, rel, child, info)
		parent = local_object(parent)
		child  = local_object(child)
                rel    = local_object(rel)
		parent.add_child_object(child, rel.first, info)
	    end
	    def removed_event_child(time, parent, rel, child)
		parent = local_object(parent)
		child  = local_object(child)
                rel    = local_object(rel)
		parent.remove_child_object(child, rel.first)
	    end
	    def added_owner(time, object, peer)
		object = local_object(object)
		object.owners << peer
	    end
	    def removed_owner(time, object, peer)
		object = local_object(object)
		object.owners.delete(peer)
	    end

            PROPAG_SIGNAL   = 1
            PROPAG_FORWARD  = 2
            PROPAG_CALLING  = 3
            PROPAG_EMITTING = 4

            EVENT_CONTINGENT  = 0
            EVENT_CONTROLABLE = 1
            EVENT_CALLED      = 2
            EVENT_EMITTED     = 4
            EVENT_CALLED_AND_EMITTED = EVENT_CALLED | EVENT_EMITTED

	    def add_internal_propagation(flag, generator, source_generators)
		generator = local_object(generator)
		if source_generators && !source_generators.empty?
		    source_generators = source_generators.map { |source_generator| local_object(source_generator) }
		    source_generators.delete_if do |ev|
			ev == generator ||
			    generator.plan.propagated_events.find { |_, from, to| to == generator && from.include?(ev) }
		    end
		    unless source_generators.empty?
			generator.plan.propagated_events << [flag, source_generators, generator]
		    end
		end
	    end
	    def generator_calling(*args)
		if args.size == 3
		    time, generator, context = *args
		    source_generators = []
		else
		    time, generator, source_generators, context = *args
		end

		add_internal_propagation(PROPAG_CALLING, generator, source_generators)
	    end
	    def generator_emitting(*args)
		if args.size == 3
		    time, generator, context = *args
		    source_generators = []
		else
		    time, generator, source_generators, context = *args
		end

		add_internal_propagation(PROPAG_EMITTING, generator, source_generators)
	    end
	    def generator_signalling(time, flag, from, to, event_id, event_time, event_context)
                from = local_object(from)
		from.plan.propagated_events << [PROPAG_SIGNAL, [from], local_object(to)]
	    end
	    def generator_forwarding(time, flag, from, to, event_id, event_time, event_context)
                from = local_object(from)
		from.plan.propagated_events << [PROPAG_FORWARD, [from], local_object(to)]
	    end

	    def generator_called(time, generator, context)
                generator = local_object(generator)
		generator.plan.emitted_events << [EVENT_CALLED, generator]
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
                if generator.respond_to?(:task)
                    generator.task.update_task_status(event)
                end
		generator.plan.emitted_events << [(found_pending ? EVENT_CALLED_AND_EMITTED : EVENT_EMITTED), generator]
	    end
	    def generator_postponed(time, generator, context, until_generator, reason)
                generator = local_object(generator)
		generator.plan.postponed_events << [generator, local_object(until_generator)]
	    end
	end

        # This widget displays information about the event history in a list,
        # allowing to switch between the "important events" in this history
        class PlanRebuilderWidget < Qt::Widget
            attr_reader :list
            attr_reader :layout
            attr_reader :history
            attr_reader :plan_rebuilder
            attr_reader :displays

            def initialize(parent, plan_rebuilder, displays)
                super(parent)
                @list    = Qt::ListWidget.new(self)
                @layout  = Qt::VBoxLayout.new(self)
                @history = Hash.new
                @plan_rebuilder = plan_rebuilder
                @displays = displays
                layout.add_widget(list)

                connect(list, SIGNAL('currentItemChanged(QListWidgetItem*,QListWidgetItem*)'),
                           self, SLOT('currentItemChanged(QListWidgetItem*,QListWidgetItem*)'))
            end

            def append_to_history(cycle, time, snapshot)
                item = Qt::ListWidgetItem.new(list)
                item.text = "@#{cycle} - #{time.strftime('%H:%M:%S')}.#{'%.03i' % [time.tv_usec % 1000]}"
                item.setData(Qt::UserRole, Qt::Variant.new(cycle))
                history[cycle] = [time, snapshot, item]
            end

            slots 'currentItemChanged(QListWidgetItem*,QListWidgetItem*)'
            def currentItemChanged(new_item, previous_item)
                data = new_item.data(Qt::UserRole).toInt
                plan_rebuilder.apply_snapshot(history[data][1])
                displays.each(&:update)
            end

            def analyze
                stream = plan_rebuilder.event_stream
                stream.rewind
                while !plan_rebuilder.eof?
                    data = stream.read
                    if plan_rebuilder.process(data)
                        cycle = stream.current_cycle
                        append_to_history(cycle, stream.current_time, plan_rebuilder.snapshot)
                    end
                    plan_rebuilder.clear_integrated
                end
            end

            def step
                plan_rebuilder.clear_integrated
                if plan_rebuilder.step
                    stream = plan_rebuilder.event_stream
                    cycle = stream.cycle
                    if !history[cycle]
                        append_to_history(cycle, stream.current_time, plan_rebuilder.snapshot)
                    end
                end
                displays.each(&:update)
            end
        end

	module TaskDisplayConfiguration
            # A set of prefixes that should be removed from the task names
	    attribute(:removed_prefixes) { Set.new }

            # Any task whose label matches one regular expression in this set is
            # not displayed
            attribute(:hidden_labels) { Array.new }

	    # Compute the prefixes to remove from in filter_prefixes:
	    # enable only the ones that are flagged, and sort them by
	    # prefix length
	    def update_prefixes_removal
		@prefixes_removal = removed_prefixes.to_a.
                    sort_by { |p| p.length }.
		    reverse
	    end

            def filtered_out_label?(label)
                (!hidden_labels.empty? && hidden_labels.any? { |rx| rx.match(label) })
            end

	    def filter_prefixes(string)
		# @prefixes_removal is computed in RelationsCanvas#update
		for prefix in @prefixes_removal
		    string = string.gsub(prefix, '')
		end
		string
	    end

	    # If true, show the ownership in the task descriptions
	    attribute(:show_ownership) { true }
	    # If true, show the arguments in the task descriptions
	    attribute(:show_arguments) { false }
	end

    end
end

