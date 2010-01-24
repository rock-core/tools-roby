module Roby::TaskStructure
    relation :Dependency, :child_name => :child, :parent_name => :parent_task do
        ##
        # :method: add_child(v, info)
        # Adds a new child to +v+. You should use #realized_by instead.

        def realizes?(obj)
            Roby.warn_deprecated "#realizes? is deprecated. Use #depended_upon_by? instead"
            depended_upon_by?(obj)
        end
	def realized_by?(obj)
            Roby.warn_deprecated "#realized_by? is deprecated. Use #depends_on?(obj, false) instead"
            depends_on?(obj, false)
        end

	# True if +obj+ is a parent of this object in the hierarchy relation
	# (+obj+ is realized by +self+)
	def depended_upon_by?(obj);	parent_object?(obj, Dependency) end

	# True if +obj+ is a child of this object in the hierarchy relation.
        # If +recursive+ is true, take into account the whole subgraph.
        # Otherwise, only direct children are checked.
        def depends_on?(obj, recursive = true)
            if recursive
                generated_subgraph(Dependency).include?(obj)
            else
                child_object?(obj, Dependency)
            end
	end
	# The set of parent objects in the Dependency relation
	def parents; parent_objects(Dependency) end
	# The set of child objects in the Dependency relation
	def children; child_objects(Dependency) end

        def roles_of(child)
            info = self[child, Dependency]
            info[:roles]
        end

        def realized_by(task, options = {})
            Roby.warn_deprecated "#realized_by is deprecated. Use #depends_on instead"
            depends_on(task, options)
        end

	# Adds +task+ as a child of +self+ in the Dependency relation. The
	# following options are allowed:
	#
	# success:: the list of success events. The default is [:success]
	# failure:: the list of failing events. The default is [:failed]
	# model:: 
        #   a <tt>[task_model, arguments]</tt> pair which defines the task
        #   model the parent is expecting.  The default value is to get these
        #   parameters from +task+
        #
        # The +success+ set describes the events of the child task that are
        # _required_ by the parent task. More specifically, the child task
        # remains useful for the parent task as long as none of these events are
        # emitted. By default, it is the +success+ event. Of course, an error
        # condition is encountered when all events of +success+ become
        # unreachable. In addition, the relation is removed if the
        # +remove_when_done+ flag is set to true (false by default).
        #
        # The +failure+ set describes the events of the child task which are an
        # error condition from the parent task point of view.
        #
        # In both error cases, a +ChildFailedError+ exception is raised.
        def depends_on(task, options = {})
            options = validate_options options, 
		:model => [task.model, task.meaningful_arguments], 
		:success => [:success], 
		:failure => [],
		:remove_when_done => true,
                :roles => nil,
                :role => nil

            roles = options[:roles] || ValueSet.new
            if role = options.delete(:role)
                roles << role.to_str
            end
            roles = roles.map { |r| r.to_str }
            options[:roles] = roles.to_set

	    options[:success] = Array[*options[:success]]
	    options[:failure] = Array[*options[:failure]]
            options[:success] -= options[:failure]

	    # Validate failure and success event names
	    options[:success].each { |ev| task.event(ev) }
	    options[:failure].each { |ev| task.event(ev) }

	    options[:model] = [options[:model], {}] unless Array === options[:model]
	    required_model, required_args = *options[:model]
            if !required_args.respond_to?(:to_hash)
                raise ArgumentError, "argument specification must be a hash, got #{required_args} (#{required_args.class})"
	    elsif !task.fullfills?(required_model, required_args)
		raise ArgumentError, "task #{task} does not fullfill the provided model #{options[:model]}"
	    end

            # Check if there is already a dependency link. If it is the case,
            # merge the options. Otherwise, just add.
            add_child(task, options)
            self
        end

	# Set up the event gathering needed by Dependency.check_structure
	def added_child_object(child, relations, info) # :nodoc:
	    super if defined? super
	    if relations.include?(Dependency) && !respond_to?(:__getobj__) && !child.respond_to?(:__getobj__)
		events = info[:success].map do |ev|
                    ev = child.event(ev)
                    ev.if_unreachable { Dependency.interesting_events << ev }
                    ev
                end
		events.concat info[:failure].map { |ev| child.event(ev) }
		Roby::EventGenerator.gather_events(Dependency.interesting_events, events)
	    end
	end

	# Return the set of this task children for which the :start event has
	# no parent in CausalLinks
        def first_children
	    result = ValueSet.new

	    generated_subgraph(Dependency).each do |task|
		next if task == self
		if task.event(:start).root?(Roby::EventStructure::CausalLink)
		    result << task
		end
	    end
	    result
        end

	# The set of events that are needed by the parent tasks
	def fullfilled_events
	    needed = ValueSet.new
	    merged_relations(:each_parent_task, false) do |myself, parent|
		needed.merge(parent[myself, Dependency][:success])
	    end
	    needed
	end

	# Return [tags, arguments] where +tags+ is a list of task models which
	# are required by the parent tasks of this task, and arguments the
	# required arguments
	#
	# If there is a task class in the required models, it is always the
	# first element of +tags+
	def fullfilled_model
	    model, tags, arguments = Roby::Task, [], {}

            has_parent = false
	    merged_relations(:each_parent_task, false) do |myself, parent|
                has_parent = true

		required_models, required_arguments = parent[myself, Dependency][:model]
                required_models = [required_models] if !required_models.respond_to?(:to_ary)

                for m in required_models
                    if m.kind_of?(Roby::TaskModelTag)
                        tags << m
                    elsif m.has_ancestor?(model)
                        model = m
                    elsif !model.has_ancestor?(m)
                        raise Roby::ModelViolation, "inconsistency in fullfilled models: #{model} and #{m} are incompatible"
                    end
                end

		arguments.merge!(required_arguments) do |name, old, new| 
		    if old != new
			raise Roby::ModelViolation, "inconsistency in fullfilled models: #{old} and #{new}"
		    end
                    old
		end
	    end

            if !has_parent
                [[self.model], self.arguments]
            else
                tags.unshift(model)
                [tags, arguments]
            end
	end

	# Remove all children that have successfully finished
	def remove_finished_children
	    # We call #to_a to get a copy of children, since we will remove
	    # children in the block. Note that we can't use #delete_if here
	    # since #children is a relation enumerator (not the relation list
	    # itself)
	    children.to_a.each do |child|
		success_events = self[child, Dependency][:success]
		if success_events.any? { |ev| child.event(ev).happened? }
		    remove_child(child)
		end
	    end
	end
    end
    Hierarchy = Dependency

    def Dependency.merge_info(parent, child, opt1, opt2)
        if opt1[:remove_when_done] != opt2[:remove_when_done]
            raise Roby::ModelViolation, "incompatible dependency specification: trying to change the value of +remove_when_done+"
        end

        result = { :remove_when_done => opt1[:remove_when_done] }

        # Remove from :success the events listed in :failure. We can't remove
        # the events in opt1[:success] that would lead to having opt2[:success]
        # unreachable though ...
        result[:success] = (opt1[:success] - opt2[:failure]) | (opt2[:success] - opt1[:failure])
        result[:failure] = opt1[:failure] | opt2[:failure]
        if result[:success].empty? && (!opt1[:success].empty? || !opt2[:success].empty?)
            raise Roby::ModelViolation, "incompatibility between the :success and :failure sets of #{opt1} and #{opt2}"
        end

        # Check model compatibility
        model1, arguments1 = opt1[:model]
        model2, arguments2 = opt2[:model]
        if model1 <= model2
            result[:model] = [model1, {}]
        elsif model2 < model1
            result[:model] = [model2, {}]
        else
            # Find the most generic model that +task+ fullfills and that
            # includes both +model1+ and +model2+
            klass = child.model
            while klass != Roby::Task && (klass <= model1 && klass <= model2)
                candidate = klass
                klass = klass.superclass
            end
            # We should always have a solution, as +task+ fullfills both model1 and model2
            result[:model] = [candidate, []]
        end

        # Merge arguments
        result[:model][1] = arguments1.merge(arguments2) do |key, old_value, new_value|
            if old_value != new_value
                raise Roby::ModelViolation, "incompatible argument constraint #{old_value} and #{new_value} for #{key}"
            end
            old_value
        end

        # Finally, merge the roles (the easy part ;-))
        result[:roles] = opt1[:roles] | opt2[:roles]

        result
    end

    # Checks the structure of +plan+ w.r.t. the constraints of the hierarchy
    # relations. It returns an array of ChildFailedError for all failed
    # hierarchy relations
    def Dependency.check_structure(plan)
	result = []

	events = Hierarchy.interesting_events
	return result if events.empty? && failing_tasks.empty?

	# Get the set of tasks for which a possible failure has been
	# registered The tasks that are failing the hierarchy requirements
	# are registered in Hierarchy.failing_tasks. The interesting_events
	# set is cleared at cycle end (see below)
	tasks = events.inject(failing_tasks) do |set, event|
            if event.respond_to?(:generator)
                set << event.generator.task
            else
                set << event.task
            end
            set
        end

	@failing_tasks = ValueSet.new
	tasks.each do |child|
	    # Check if the task has been removed from the plan
	    next unless child.plan

	    child.each_parent_task do |parent|
		next unless parent.self_owned?
		next if parent.finished? || parent.finishing?

		options = parent[child, Hierarchy]
		success = options[:success]
		failure = options[:failure]

		if success.any? { |e| child.event(e).happened? }
		    if options[:remove_when_done]
			parent.remove_child child
		    end
		elsif failing_event = failure.find { |e| child.event(e).happened? }
		    result << Roby::ChildFailedError.new(parent, child.event(failing_event).last)
		    failing_tasks << child
		elsif success.all? { |e| child.event(e).unreachable? }
                    failing_event = success.find { |e| child.event(e).unreachability_reason }
                    failing_event = child.event(failing_event || success.first)

                    reason = failing_event.unreachability_reason
                    if reason.kind_of?(Roby::Event)
                        failing_event, reason = reason, nil
                    end
		    result << Roby::ChildFailedError.new(parent, failing_event, reason)
		    failing_tasks << child
		end
	    end
	end

	events.clear
	result
    end

    class << Dependency
	# The set of events that have been fired in this cycle and are involved in a Hierarchy relation
	attribute(:interesting_events) { Array.new }

	# The set of tasks that are currently failing 
	attribute(:failing_tasks) { ValueSet.new }
    end
end

module Roby
    # This exception is raised when a {hierarchy relation}[classes/Roby/TaskStructure/Hierarchy.html] fails
    class ChildFailedError < LocalizedError
	# The parent in the relation
	attr_reader :parent
	# The child in the relation
	def child; failed_task end
        # If the reason of this failure is that the positive events have become
        # unreachable, +unreachability_reason+ stores the corresponding
        # unreachability reason.
        attr_reader :unreachability_reason
	# The relation parameters (i.e. the hash given to #depends_on)
	attr_reader :relation

	# The event which is the cause of this error. This is either the task
	# source of a failure event, or the reason why a positive event has
	# become unreachable (if there is one)
	def initialize(parent, failure_point, unreachability_reason = nil)
            super(failure_point)
            @unreachability_reason = failed_generator.unreachability_reason
	    @parent   = parent
	    @relation = parent[child, TaskStructure::Dependency]
	end

	def pretty_print(pp) # :nodoc:
            pp.text "#{self.class.name}: "
            if unreachability_reason
                pp.text "#{failed_generator} is unreachable"
            else
                pp.text "#{failed_generator} emitted the following event"
                pp.breakable
                failure_event.pretty_print(pp)
            end

            pp.breakable
            pp.text "The failed relation is"
            pp.breakable
            pp.nest(2) do
                pp.text "  "
                parent.pretty_print pp
                pp.breakable
                pp.text "depends_on "
                child.pretty_print pp
            end
            pp.breakable

            if unreachability_reason
                pp.breakable
                pp.text "it is unreachable for the following reason:"
                pp.breakable
                unreachability_reason.pretty_print(pp)
            end
	end
	def backtrace; [] end

        # True if +obj+ is involved in this exception
        def involved_plan_object?(obj)
            super || obj == parent
        end
    end
end

