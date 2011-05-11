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
                # Check if we need to override the model, or only the bound
                # event
                if !self.model.event_model(symbol).controlable? && marshalled_event.controlable
                    terminal = event(symbol).terminal?
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

	    def initialize(main_manager = true)
                @plan = Roby::Plan.new
                @plan.extend ReplayPlan
                @plans = [@plan]
                @manager = create_remote_object_manager
                if main_manager
                    Distributed.setup_log_replay(manager)
                end
                @history = Array.new
                @changes = Hash.new
                @event_filters = Array.new
	    end

            def analyze_stream(event_stream)
                event_stream.rewind
                while !event_stream.eof?
                    data = event_stream.read
                    if process(data)
                        history << snapshot
                    end
                    clear_integrated
                end
                event_stream.rewind
            end

            # The starting time of the last processed cycle
            def time
                Time.at(*stats[:start])
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
                if has_interesting_events?
                    history << snapshot
                    result = true
                end

                clear_integrated
                result
            end

            PlanRebuilderSnapshot = Struct.new :stats, :state, :plan, :manager

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
                return PlanRebuilderSnapshot.new(stats, state, plan, manager)
            end

            def apply_snapshot(snapshot)
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
                history.clear
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
		data.each_slice(4) do |m, sec, usec, args|
		    time = Time.at(sec, usec)
		    reason = catch :ignored do
			begin
			    if respond_to?(m)
				send(m, time, *args)
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
                has_event_propagation_updates? || has_structure_updates?
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
                plans.each(&:clear_integrated)
                @changes.clear
	    end

	    def inserted_tasks(time, plan, task)
		plan = local_object(plan)
		plan.add_mission( local_object(task) )
                announce_structure_update
	    end
	    def discarded_tasks(time, plan, task)
		plan = local_object(plan)
		plan.remove_mission(local_object(task))
                announce_structure_update
	    end
	    def replaced_tasks(time, plan, from, to)
                announce_structure_update
	    end
	    def added_events(time, plan, events)
		plan = local_object(plan)
		events.each do |ev| 
		    plan.add(local_object(ev))
		end
                announce_structure_update
	    end
	    def added_tasks(time, plan, tasks)
		plan = local_object(plan)
		tasks.each do |t| 
		    plan.add(local_object(t))
		end
                announce_structure_update
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
                announce_structure_update
	    end
	    def finalized_task(time, plan, task)
		task = local_object(task)
		plan = local_object(plan)
                plan.finalized_tasks << task
		plan.remove_object(task)
                announce_structure_update
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
                announce_structure_update
                return parent, rel, child
	    end

	    def removed_task_child(time, parent, rel, child)
		parent = local_object(parent)
		child  = local_object(child)
		rel    = rel.first if rel.kind_of?(Array)
		rel    = local_object(rel)
		parent.remove_child_object(child, rel)
                announce_structure_update
                return parent, rel, child
	    end
	    def added_event_child(time, parent, rel, child, info)
		parent = local_object(parent)
		child  = local_object(child)
                rel    = local_object(rel)
		parent.add_child_object(child, rel.first, info)
                announce_structure_update
	    end
	    def removed_event_child(time, parent, rel, child)
		parent = local_object(parent)
		child  = local_object(child)
                rel    = local_object(rel)
		parent.remove_child_object(child, rel.first)
                announce_structure_update
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
                announce_state_update
            end

            def self.update_type(type)
                define_method("announce_#{type}_update") do
                    @changes[type] = true
                end
                define_method("has_#{type}_updates?") do
                    !!@changes[type]
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


            def announce_structure_update
                @changes[:structure] = true
            end
            def announce_state_update
                @changes[:state] = true
            end
            def announce_event_propagation_update
                @changes[:event_propagation] = true
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
		    source_generators = source_generators.map { |source_generator| local_object(source_generator) }.
                        delete_if { |gen| gen == generator }
                    if !source_generators.empty?
                        generator.plan.propagated_events << [flag, source_generators, generator]
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
                if !filtered_out_event?(generator) && !source_generators.any? { |ev| filtered_out_event?(ev) }
                    announce_event_propagation_update
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
                if !filtered_out_event?(generator) && !source_generators.any? { |ev| filtered_out_event?(ev) }
                    announce_event_propagation_update
                end
	    end
	    def generator_signalling(time, flag, from, to, event_id, event_time, event_context)
                from = local_object(from)
                to   = local_object(to)
		from.plan.propagated_events << [PROPAG_SIGNAL, [from], to]
                if !filtered_out_event?(from) && !filtered_out_event?(to)
                    announce_event_propagation_update
                end
	    end
	    def generator_forwarding(time, flag, from, to, event_id, event_time, event_context)
                from = local_object(from)
                to   = local_object(to)
		from.plan.propagated_events << [PROPAG_FORWARD, [from], to]
                if !filtered_out_event?(from) && !filtered_out_event?(to)
                    announce_event_propagation_update
                end
	    end

	    def generator_called(time, generator, context)
                generator = local_object(generator)
		generator.plan.emitted_events << [EVENT_CALLED, generator]
                if !filtered_out_event?(generator)
                    announce_event_propagation_update
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
                if generator.respond_to?(:task)
                    generator.task.update_task_status(event)
                end
		generator.plan.emitted_events << [(found_pending ? EVENT_CALLED_AND_EMITTED : EVENT_EMITTED), generator]
	    end
	    def generator_postponed(time, generator, context, until_generator, reason)
                generator = local_object(generator)
		generator.plan.postponed_events << [generator, local_object(until_generator)]
                if !filtered_out_event?(generator)
                    announce_event_propagation_update
                end
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
                        throw :ignore
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

            # True if this generator is filtered out by one of the custom
            # filters
            def filtered_out_event?(generator)
                event_filters.each do |filter|
                    result = catch(:ignore) do
                        filter.match(generator)
                        true
                    end
                    if !result
                        Log.info "generator #{generator.to_s} rejected by filter #{filter}"
                        return true
                    end
                end
                false
            end


            def load_options(options)
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

            def dump_options
                result = Hash.new

                filters = Array.new
                event_filters.each do |filter|
                    filters << filter.dump_options
                end
                result['filters'] = filters
                result
            end

            def options(options = Hash.new)
                if !options.empty?
                    load_options(options)
                end
                dump_options
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

            def add_missing_cycles(count)
                item = Qt::ListWidgetItem.new(list)
                item.setBackground(Qt::Brush.new(Qt::Color::fromHsv(33, 111, 255)))
                item.flags = Qt::NoItemFlags
                item.text = "[#{count} cycles missing]"
            end

            def append_to_history(snapshot)
                cycle = snapshot.stats[:cycle_index]
                time = Time.at(*snapshot.stats[:start]) + snapshot.stats[:real_start]

                item = Qt::ListWidgetItem.new(list)
                item.text = "@#{cycle} - #{time.strftime('%H:%M:%S')}.#{'%.03i' % [time.tv_usec / 1000]}"
                item.setData(Qt::UserRole, Qt::Variant.new(cycle))
                history[cycle] = [time, snapshot, item]
            end

            slots 'currentItemChanged(QListWidgetItem*,QListWidgetItem*)'
            def currentItemChanged(new_item, previous_item)
                data = new_item.data(Qt::UserRole).toInt
                plan_rebuilder.apply_snapshot(history[data][1])
                displays.each(&:update)
            end

            attr_reader :last_cycle

            def push_data(data)
                needs_snapshot = plan_rebuilder.push_data(data)
                cycle = plan_rebuilder.stats[:cycle_index]
                if last_cycle && (cycle != last_cycle + 1)
                    add_missing_cycles(cycle - last_cycle - 1)
                end
                if needs_snapshot
                    append_to_history(plan_rebuilder.history.last)
                end
                @last_cycle = cycle
            end

            def analyze(stream, display_progress = true)
                stream.rewind
                start_time, end_time = stream.range

                dialog = Qt::ProgressDialog.new("Analyzing log file", "Quit", 0, (end_time - start_time))
                dialog.setWindowModality(Qt::WindowModal)
                dialog.show

                @last_cycle = nil
                while !stream.eof?
                    data = stream.read
                    push_data(data)
                    dialog.setValue(plan_rebuilder.time - start_time)
                    if dialog.wasCanceled
                        Kernel.raise Interrupt
                    end
                end
                dialog.dispose
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
                (!hidden_labels.empty? && hidden_labels.any? { |match| label.include?(match) })
            end

	    def filter_prefixes(string)
		# @prefixes_removal is computed in RelationsCanvas#update
		for prefix in @prefixes_removal
		    string = string.gsub(prefix, '')
		end
                if string =~ /^::/
                    string = string[2..-1]
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

