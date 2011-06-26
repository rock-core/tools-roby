module Roby::TaskStructure
    module ModelLevelDependency
        # Specify the base model that will be used as the model for which
        # this task is used.
        #
        # See #fullfilled_model= and #fullfilled_model on the task instances
        attr_accessor :fullfilled_model
    end

    relation :Dependency, :child_name => :child, :parent_name => :parent_task do
        # When Dependency support is included in a model (for instance
        # Roby::Task), add the model-level classes  
        def self.included(klass) # :nodoc:
	    klass.extend Roby::TaskStructure::ModelLevelDependency
            super
        end

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

        # Returns the set of roles that +child+ has
        def roles_of(child)
            info = self[child, Dependency]
            info[:roles]
        end

        # Enumerates all the roles this task has
        def each_role(&block)
            if !block_given?
                return enum_for(:each_role, &block)
            end
            each_parent_object(Dependency) do |parent|
                yield(parent, parent.roles_of(self))
            end
        end

        def roles
            each_role.map { |_, roles| roles.to_a }.flatten.to_set
        end

        def has_role?(role_name)
            !!child_from_role(role_name, false)
        end

        # Returns the child whose role is +role_name+
        #
        # If +validate+ is true (the default), raises ArgumentError if there is
        # none. Otherwise, returns nil. This argument is meant only to avoid the
        # costly operation of raising an exception in cases it is expected that
        # the role may not exist.
        def child_from_role(role_name, validate = true)
            each_child do |child_task, info|
                if info[:roles].include?(role_name)
                    return child_task
                end
            end
            if validate
                raise ArgumentError, "#{self} has no child with the role '#{role_name}'"
            end
        end

        # DEPRECATED. Use #depends_on instead 
        def realized_by(task, options = {}) # :nodoc:
            Roby.warn_deprecated "#realized_by is deprecated. Use #depends_on instead"
            depends_on(task, options)
        end

        # Returns a task in the dependency hierarchy of this task by following
        # the roles. +path+ is an array of role names, and the method will
        # follow the trail until the desired task
        #
        # Raises ArgumentError if the child does not exist
        #
        # See #role_path to get a role path for a specific task
        def resolve_role_path(*path)
            if path.size == 1 && path[0].respond_to?(:to_ary)
                path = path[0]
            end
            # Special case for ease of use in algorithms
            if path.empty?
                return self
            end

            up_until_now = []
            path.inject(self) do |task, role|
                up_until_now << role
                if !(next_task = task.child_from_role(role, false))
                    raise ArgumentError, "the child #{up_until_now.join(".")} of #{task} does not exist"
                end
                next_task
            end
        end

        # Returns a set role paths that lead to +task+ when starting from +self+
        #
        # A role path is an array of roles that lead to +task+ when starting by
        # +self+.
        #
        # I.e. if ['role1', 'role2', 'role3'] is a role path from +self+ to
        # +task, it means that 
        #
        #    task1 = self.child_from_role('role1')
        #    task2 = task1.child_from_role('role2')
        #    task  = task2.child_from_role('role3')
        #
        # The method returns a set of role paths, as there may be multiple paths
        # leading from +self+ to +task+
        #
        # See #resolve_role_path to get a task from its role path
        def role_paths(task, validate = true)
            if task == self
                return []
            end

            result = []
            task.each_role do |parent, roles|
                if parent == self
                    new_paths = roles.map { |r| [r] }
                elsif heads = role_paths(parent, false)
                    heads.each do |h|
                        roles.each do |t|
                            result << (h.dup << t)
                        end
                    end
                end
                if new_paths
                    result.concat(new_paths)
                end
            end

            if result.empty?
                if validate
                    raise ArgumentError, "#{task} can not be reached from #{self}"
                end
                return
            end
            result
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
            if task.respond_to?(:as_plan)
                task = task.as_plan
            end

            options = validate_options options, 
		:model => [task.provided_services, task.meaningful_arguments], 
		:success => :success.to_unbound_task_predicate, 
		:failure => false.to_unbound_task_predicate,
		:remove_when_done => true,
                :consider_in_pending => true,
                :roles => nil,
                :role => nil

            # We accept
            #
            #   model
            #   [model1, model2]
            #   [model1, arguments]
            #   [[model1, model2], arguments]
            if !options[:model].respond_to?(:to_ary)
                options[:model] = [[options[:model]], Hash.new]
            elsif options[:model].size == 2
                if !options[:model].first.respond_to?(:to_ary)
                    if options[:model].last.kind_of?(Hash)
                        options[:model] = [[options[:model].first], options[:model].last]
                    else
                        options[:model] = [options[:model], Hash.new]
                    end
                end
            elsif !options[:model].first.respond_to?(:to_ary)
                options[:model] = [options[:model], Hash.new]
            end

            roles = options[:roles] || ValueSet.new
            if role = options.delete(:role)
                roles << role.to_str
            end
            roles = roles.map { |r| r.to_str }
            options[:roles] = roles.to_set

            if options[:success].nil?
                options[:success] = []
            end
	    options[:success] = Array[*options[:success]].
                map { |predicate| predicate.to_unbound_task_predicate }.
                inject(&:or)

            if options[:failure].nil?
                options[:failure] = []
            end
	    options[:failure] = Array[*options[:failure]].
                map { |predicate| predicate.to_unbound_task_predicate }.
                inject(&:or)

            #options[:success] ||= false.to_unbound_task_predicate
            #options[:failure] ||= false.to_unbound_task_predicate

            # Validate failure and success event names
            if options[:success]
                not_there = options[:success].required_events.
                    find_all { |name| !task.has_event?(name) }
                if !not_there.empty?
                    raise ArgumentError, "#{task} does not have the following events: #{not_there.join(", ")}"
                end
            end

            if options[:failure]
                not_there = options[:failure].required_events.
                    find_all { |name| !task.has_event?(name) }
                if !not_there.empty?
                    raise ArgumentError, "#{task} does not have the following events: #{not_there.join(", ")}"
                end
            end

            # There is no positive events in success. Behind the scenes, it
            # actually means that the task does not have to start (since nothing
            # in :success would become unreachable)
            #
            # Add !:start in failure
            if !options[:success]
                not_started = :start.to_unbound_task_predicate.never
                if options[:failure]
                    options[:failure] = not_started.or(options[:failure])
                else
                    options[:failure] = not_started
                end
            end

	    required_model, required_args = *options[:model]
            if !required_args.respond_to?(:to_hash)
                raise ArgumentError, "argument specification must be a hash, got #{required_args} (#{required_args.class})"
	    elsif !task.fullfills?(required_model, required_args)
		raise ArgumentError, "task #{task} does not fullfill the provided model #{options[:model]}"
	    end

            # Check if there is already a dependency link. If it is the case,
            # merge the options. Otherwise, just add.
            add_child(task, options)
            task
        end

        def remove_dependency(task_or_role)
            if task_or_role.respond_to?(:to_str)
                remove_child(child_from_role(task_or_role))
            else
                remove_child(task_or_role)
            end
        end

	# Set up the event gathering needed by Dependency.check_structure
	def added_child_object(child, relations, info) # :nodoc:
	    super if defined? super
	    if relations.include?(Dependency) && !respond_to?(:__getobj__) && !child.respond_to?(:__getobj__)
                events = ValueSet.new
                if info[:success]
                    for event_name in info[:success].required_events
                        events << child.event(event_name)
                    end
                end

                if info[:failure]
                    for event_name in info[:failure].required_events
                        events << child.event(event_name)
                    end
                end

                if !events.empty?
                    for ev in events
                        ev.if_unreachable { Dependency.interesting_events << ev }
                    end
                    Roby::EventGenerator.gather_events(Dependency.interesting_events, events)
                end

                # Initial triggers
                Dependency.failing_tasks << child
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

        # In normal operations, the fullfilled model returned by
        # #fullfilled_model is computed from the dependency relations in which
        # +self+ is a child.
        #
        # However, this fails in case +self+ is a root task in the dependency
        # relation. Moreover, it might be handy to over-constrain the model
        # computed through the dependency relation.
        # 
        # In both cases, a model can be specified explicitely by setting the
        # fullfilled_model attribute. The value has to be
        #
        #   [task_model, [tag1, tag2, ...], task_arguments]
        #
        # For instance, a completely non-constrained model would be
        #
        #   [Roby::Task, [], {}]
        #
        # This parameter can be set model-wide by using #fullfilled_model= on
        # the class object
        attr_writer :fullfilled_model

	# Return [tags, arguments] where +tags+ is a list of task models which
	# are required by the parent tasks of this task, and arguments the
	# required arguments
	#
	# If there is a task class in the required models, it is always the
	# first element of +tags+
	def fullfilled_model
	    model, tags, arguments =
                if explicit = (@fullfilled_model || self.model.fullfilled_model)
                    has_value = true
                    explicit
                else
                    has_value = false
                    [Roby::Task, [], {}]
                end

	    merged_relations(:each_parent_task, false) do |myself, parent|
                has_value = true

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

            if !has_value
                [[self.model], self.meaningful_arguments]
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
            children = each_child.to_a
            for child in children
                child, info = child
                if info[:success].evaluate(child)
                    remove_child(child)
                end
            end
	end
    end

    def Dependency.validate_options(options)
        Kernel.validate_options options, [:model, :success, :failure, :remove_when_done, :consider_in_pending, :roles, :role]
    end

    Hierarchy = Dependency

    def Dependency.merge_info(parent, child, opt1, opt2)
        if opt1[:remove_when_done] != opt2[:remove_when_done]
            raise Roby::ModelViolation, "incompatible dependency specification: trying to change the value of +remove_when_done+"
        end

        result = { :remove_when_done => opt1[:remove_when_done], :consider_in_pending => opt1[:consider_in_pending] }

        result[:success] =
            if !opt1[:success] then opt2[:success]
            elsif !opt2[:success] then opt1[:success]
            else
                opt1[:success].and(opt2[:success])
            end

        result[:failure] =
            if !opt1[:failure] then opt2[:failure]
            elsif !opt2[:failure] then opt1[:failure]
            else
                opt1[:failure].or(opt2[:failure])
            end

        # Check model compatibility
        models1, arguments1 = opt1[:model]
        models2, arguments2 = opt2[:model]

        task_model1 = models1.find { |m| m <= Roby::Task }
        task_model2 = models2.find { |m| m <= Roby::Task }

        result_model = []
        if task_model1 && task_model2
            if task_model1 <= task_model2
                result_model << task_model1
            elsif task_model2 < task_model1
                result_model << task_model2
            else
                raise ModelViolation, "incompatible models #{task_model1} and #{task_model2}"
            end
        elsif task_model1
            result_model << task_model1
        elsif task_model2
            result_model << task_model2
        end
        models1.each do |m|
            next if m <= Roby::Task
            if !models2.any? { |other_m| other_m.fullfills?(m) }
                result_model << m
            end
        end
        models2.each do |m|
            next if m <= Roby::Task
            if !models1.any? { |other_m| other_m.fullfills?(m) }
                result_model << m
            end
        end

        result[:model] = [result_model]
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
        tasks, @failing_tasks = failing_tasks, ValueSet.new
	events.each do |event|
            if event.respond_to?(:generator)
                tasks << event.generator.task
            else
                tasks << event.task
            end
        end

	for child in tasks
	    # Check if the task has been removed from the plan
	    next unless child.plan

            removed_parents = []
	    child.each_parent_task do |parent|
	        next if parent.finished?
		next unless parent.self_owned?

		options = parent[child, Dependency]
		success = options[:success]
		failure = options[:failure]

                has_success = success && success.evaluate(child)
                if !has_success
                    has_failure = failure && failure.evaluate(child)
                end

                error = nil
		if has_success
		    if options[:remove_when_done]
                        # Must not delete it here as we are iterating over the
                        # parents
			removed_parents << parent
		    end
                elsif has_failure
                    explanation = failure.explain_true(child)
		    error = Roby::ChildFailedError.new(parent, child, explanation)
		elsif success && success.static?(child)
                    explanation = success.explain_static(child)
		    error = Roby::ChildFailedError.new(parent, child, explanation)
		end

                if error
                    if parent.running?
                        result << error
                        failing_tasks << child
                    elsif options[:consider_in_pending] && plan.control.pending_dependency_failed(parent, child, error)
                        result << error
                        failing_tasks << child
                    end
                end
	    end
            for parent in removed_parents
                parent.remove_child child
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
    class ChildFailedError < RelationFailedError
	# The child in the relation
	def child; failed_task end
	# The relation parameters (i.e. the hash given to #depends_on)
	attr_reader :relation
        # The Explanation object that describes why the relation failed
        attr_reader :explanation

	# The event which is the cause of this error. This is either the task
	# source of a failure event, or the reason why a positive event has
	# become unreachable (if there is one)
	def initialize(parent, child, explanation)
            @explanation = explanation

            events, generators, others = [], [], []
            explanation.elements.each do |e|
                case e
                when Event then events << e
                when EventGenerator then generators << e
                else others << e
                end
            end

            failure_point =
                if events.size > 2 || !others.empty?
                    child
                else
                    base_event = events.first || generators.first
                    if explanation.value.nil? # unreachability
                        reason = base_event.unreachability_reason
                        if reason.kind_of?(Event)
                            reason
                        else
                            base_event
                        end
                    else
                        base_event
                    end
                end

            super(failure_point)

	    @parent   = parent
	    @relation = parent[child, TaskStructure::Dependency]
	end

	def pretty_print(pp) # :nodoc:
            pp.text "#{self.class.name}: "
            explanation.pretty_print(pp)

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
	end
	def backtrace; [] end

        # True if +obj+ is involved in this exception
        def involved_plan_object?(obj)
            super || obj == parent
        end
    end
end

