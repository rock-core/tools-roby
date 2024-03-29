# frozen_string_literal: true

module Roby
    module TaskStructure
        DEPENDENCY_RELATION_ARGUMENTS =
            %i[model success failure remove_when_done consider_in_pending roles role].freeze

        relation :Dependency, child_name: :child, parent_name: :parent_task

        class Dependency < Relations::TaskRelationGraph
            attr_reader :interesting_events, :failing_tasks

            def initialize(observer: nil)
                super(observer: observer)
                @interesting_events = []
                @failing_tasks = Set.new
            end

            # @api private
            #
            # Updates the dependency internal data to trigger errors / success when
            # relevant events are emitted
            def update_triggers_for(parent, child, info)
                events = Set.new
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

                unless events.empty?
                    parent.start_event.on(on_replace: :drop) do |ev|
                        ev.plan.task_relation_graph_for(self.class).interesting_events << ev.generator
                    end
                    events.each do |e|
                        e.if_unreachable do |reason, ev|
                            # The actualy graph of 'ev' might be different than self
                            # ... re-resolve
                            ev.plan.task_relation_graph_for(self.class).interesting_events << ev
                        end
                        e.on(on_replace: :drop) do |ev|
                            ev.plan.task_relation_graph_for(self.class).interesting_events << ev.generator
                        end
                    end
                end

                # Initial triggers
                failing_tasks << child
            end

            def self.merge_fullfilled_model(model, required_models, required_arguments)
                model, tags, arguments = *model

                tags = tags.dup
                required_models = Array(required_models)

                for m in required_models
                    if m.kind_of?(Roby::Models::TaskServiceModel)
                        tags << m
                    elsif m.has_ancestor?(model)
                        model = m
                    elsif !model.has_ancestor?(m)
                        raise Roby::ModelViolation, "inconsistency in fullfilled models: #{model} and #{m} are incompatible"
                    end
                end
                tags.uniq!

                arguments = arguments.merge(required_arguments) do |name, old, new|
                    if old != new
                        raise Roby::ModelViolation, "inconsistency in fullfilled models: #{old} and #{new}"
                    end

                    old
                end

                [model, tags, arguments]
            end

            def self.validate_options(options, defaults = {})
                defaults = Hash[model: [[Roby::Task], {}],
                                success: nil,
                                failure: nil,
                                remove_when_done: true,
                                consider_in_pending: true,
                                roles: Set.new,
                                role: nil].merge(defaults)
                Kernel.validate_options options, defaults
            end

            # Merges the dependency descriptions (i.e. the relation payload),
            # verifying that the two provided option hashes are compatible
            #
            # @return [Hash] the merged options
            # @raise [ModelViolation] if the two hashes are not compatible
            def self.merge_dependency_options(opt1, opt2)
                if opt1[:remove_when_done] != opt2[:remove_when_done]
                    raise Roby::ModelViolation, "incompatible dependency specification: trying to change the value of +remove_when_done+"
                end

                result = { remove_when_done: opt1[:remove_when_done], consider_in_pending: opt1[:consider_in_pending] }

                if opt1[:success] || opt2[:success]
                    result[:success] =
                        if !opt1[:success] then opt2[:success]
                        elsif !opt2[:success] then opt1[:success]
                        else
                            opt1[:success].and(opt2[:success])
                        end
                end

                if opt1[:failure] || opt2[:failure]
                    result[:failure] =
                        if !opt1[:failure] then opt2[:failure]
                        elsif !opt2[:failure] then opt1[:failure]
                        else
                            opt1[:failure].or(opt2[:failure])
                        end
                end

                # Check model compatibility
                models1, arguments1 = opt1[:model]
                models2, arguments2 = opt2[:model]

                task_model1 = models1.find { |m| m <= Roby::Task }
                task_model2 = models2.find { |m| m <= Roby::Task }
                result_model = []
                if task_model1 && task_model2
                    if task_model1.fullfills?(task_model2)
                        result_model << task_model1
                    elsif task_model2.fullfills?(task_model1)
                        result_model << task_model2
                    else
                        raise Roby::ModelViolation, "incompatible models #{task_model1} and #{task_model2}"
                    end
                elsif task_model1
                    result_model << task_model1
                elsif task_model2
                    result_model << task_model2
                end
                models1.each do |m|
                    next if m <= Roby::Task

                    if models2.none? { |other_m| other_m.fullfills?(m) }
                        result_model << m
                    end
                end
                models2.each do |m|
                    next if m <= Roby::Task

                    if models1.none? { |other_m| other_m.fullfills?(m) }
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
                result[:model].freeze

                # Finally, merge the roles (the easy part ;-))
                result[:roles] = opt1[:roles] | opt2[:roles]
                result.freeze

                result
            end

            # Called by the relation management when two dependency relations need
            # to be merged
            #
            # @see Dependency.merge_dependency_options
            def merge_info(parent, child, opt1, opt2)
                result = Dependency.merge_dependency_options(opt1, opt2)
                update_triggers_for(parent, child, result)
                result
            rescue Exception => e
                raise e, e.message + " while updating the dependency information for #{parent} -> #{child}", e.backtrace
            end

            # Checks the structure of +plan+ w.r.t. the constraints of the hierarchy
            # relations. It returns an array of ChildFailedError for all failed
            # hierarchy relations
            def check_structure(plan)
                # The Set in #interesting_events is also referenced
                # *separately* in EventStructure.gather_events. We therefore have to
                # keep it (and can't use #partition). Yuk
                events = []
                interesting_events.delete_if do |ev|
                    if ev.plan == plan
                        events << ev
                        true
                    else
                        !ev.plan
                    end
                end
                tasks = Set.new
                failing_tasks.delete_if do |task|
                    if task.plan == plan
                        tasks << task
                        true
                    else
                        !task.plan
                    end
                end
                return [] if events.empty? && tasks.empty?

                result = []

                # Get the set of tasks for which a possible failure has been
                # registered The tasks that are failing the hierarchy requirements
                # are registered in Hierarchy.failing_tasks.
                events.each do |event|
                    task = event.task
                    tasks << task

                    if event.symbol == :start # also add the children
                        task.each_child do |child_task, _|
                            tasks << child_task
                        end
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

                        has_success = success&.evaluate(child)
                        unless has_success
                            has_failure = failure&.evaluate(child)
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
                            error = Roby::ChildFailedError.new(parent, child, explanation, :failed_event)
                        elsif success&.static?(child)
                            explanation = success.explain_static(child)
                            error = Roby::ChildFailedError.new(parent, child, explanation, :unreachable_success)
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

                result
            end

            module Extension
                # True if +obj+ is a parent of this object in the hierarchy relation
                # (+obj+ is realized by +self+)
                def depended_upon_by?(obj)
                    parent_object?(obj, Dependency)
                end

                # True if +obj+ is a child of this object in the hierarchy relation.
                # If +recursive+ is true, take into account the whole subgraph.
                # Otherwise, only direct children are checked.
                def depends_on?(obj, recursive: false)
                    if recursive
                        relation_graph_for(Dependency)
                            .depth_first_visit(obj) { |v| return true if v == obj }
                        false
                    else
                        child_object?(obj, Dependency)
                    end
                end

                # The set of parent objects in the Dependency relation
                def parents
                    parent_objects(Dependency)
                end

                # The set of child objects in the Dependency relation
                def children
                    child_objects(Dependency)
                end

                # Returns the single parent task for this task
                #
                # If there is more than one parent or no parent at all, raise an exception
                def parent_task
                    parents = each_parent_task.to_a
                    if parents.size > 1
                        raise ArgumentError, "#{self} has #{parents.size} parents (#{parents.map(&:to_s).join(', ')}. A single parent was expected"
                    elsif parents.empty?
                        raise ArgumentError, "#{self} has no parents. A single parent was expected"
                    end

                    parents.first
                end

                # Returns the set of roles that +child+ has
                def roles_of(child)
                    info = self[child, Dependency]
                    info[:roles]
                end

                # Enumerates all the roles this task has
                def each_role(&block)
                    unless block_given?
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
                    !!find_child_from_role(role_name)
                end

                # Remove a given role this task's child
                #
                # @param [Task] child the child task
                # @param [Array<String>] roles the roles that should be removed
                # @param [Boolean] remove_child_when_empty if true (the default), the
                #   child will be removed from this task's children if the set of roles
                #   is empty
                # @raise [ArgumentError] if the child does not have the expected role
                # @return [Boolean] true if the child is still a child of this task
                #   after the call, and false otherwise
                def remove_roles(child, *roles, remove_child_when_empty: true)
                    dependency_info = self[child, Dependency].dup
                    child_roles = dependency_info[:roles].dup
                    roles.each do |r|
                        unless child_roles.include?(r)
                            raise ArgumentError, "#{r} is not a role of #{child} with respect to #{self}"
                        end

                        child_roles.delete(r)
                    end

                    if child_roles.empty? && remove_child_when_empty
                        remove_child(child)
                        false
                    else
                        dependency_info[:roles] = child_roles
                        self[child, Dependency] = dependency_info
                        true
                    end
                end

                # Returns the child whose role is +role_name+
                #
                # @return [nil,Task] the task if a dependency with the given role is
                #   found, and nil otherwise
                def find_child_from_role(role_name)
                    each_out_neighbour_merged(Dependency, intrusive: false) do |myself, child|
                        roles = myself[child, Dependency][:roles]
                        if roles.include?(role_name)
                            if plan
                                return plan[child]
                            else
                                return child
                            end
                        end
                    end
                    nil
                end

                # Returns the child whose role is +role_name+
                #
                # If +validate+ is true (the default), raises ArgumentError if there is
                # none. Otherwise, returns nil. This argument is meant only to avoid the
                # costly operation of raising an exception in cases it is expected that
                # the role may not exist.
                def child_from_role(role_name, validate = true)
                    unless validate
                        Roby.warn_deprecated "#child_from_role(name, false) has been replaced by #find_child_from_role"
                    end

                    child = find_child_from_role(role_name)
                    if !child && validate
                        known_children = {}
                        each_out_neighbour_merged(Dependency, intrusive: false) do |myself, child|
                            myself[child, Dependency][:roles].each do |role|
                                known_children[role] = child
                            end
                        end
                        raise Roby::NoSuchChild.new(self, role_name, known_children), "#{self} has no child with the role '#{role_name}'"
                    end
                    child
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
                        unless (next_task = task.find_child_from_role(role))
                            raise ArgumentError, "the child #{up_until_now.join('.')} of #{task} does not exist"
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
                    if task == self
                        raise ArgumentError, "cannot add a dependency of a task to itself"
                    end

                    options = Dependency.validate_options options,
                                                          model: [task.provided_models, task.meaningful_arguments],
                                                          success: :success.to_unbound_task_predicate,
                                                          failure: false.to_unbound_task_predicate,
                                                          remove_when_done: true,
                                                          consider_in_pending: true,
                                                          roles: nil,
                                                          role: nil

                    # We accept
                    #
                    #   model
                    #   [model1, model2]
                    #   [model1, arguments]
                    #   [[model1, model2], arguments]
                    if !options[:model].respond_to?(:to_ary)
                        options[:model] = [Array(options[:model]), {}]
                    elsif options[:model].size == 2
                        unless options[:model].first.respond_to?(:to_ary)
                            if options[:model].last.kind_of?(Hash)
                                options[:model] = [Array(options[:model].first), options[:model].last]
                            else
                                options[:model] = [options[:model], {}]
                            end
                        end
                    elsif !options[:model].first.respond_to?(:to_ary)
                        options[:model] = [Array(options[:model]), {}]
                    end

                    roles = options[:roles] || Set.new
                    if role = options.delete(:role)
                        roles << role.to_str
                    end
                    roles = roles.map(&:to_str)
                    options[:roles] = roles.to_set

                    if options[:success].nil?
                        options[:success] = []
                    end
                    options[:success] = Array[*options[:success]]
                        .map(&:to_unbound_task_predicate)
                        .inject(&:or)

                    if options[:failure].nil?
                        options[:failure] = []
                    end
                    options[:failure] = Array[*options[:failure]]
                        .map(&:to_unbound_task_predicate)
                        .inject(&:or)

                    # options[:success] ||= false.to_unbound_task_predicate
                    # options[:failure] ||= false.to_unbound_task_predicate

                    # Validate failure and success event names
                    if options[:success]
                        not_there = options[:success].required_events
                            .find_all { |name| !task.has_event?(name) }
                        unless not_there.empty?
                            raise ArgumentError, "#{task} does not have the following events: #{not_there.join(', ')}"
                        end
                    end

                    if options[:failure]
                        not_there = options[:failure].required_events
                            .find_all { |name| !task.has_event?(name) }
                        unless not_there.empty?
                            raise ArgumentError, "#{task} does not have the following events: #{not_there.join(', ')}"
                        end
                    end

                    # There is no positive events in success. Behind the scenes, it
                    # actually means that the task does not have to start (since nothing
                    # in :success would become unreachable)
                    #
                    # Add !:start in failure
                    unless options[:success]
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
                    options.freeze
                    options.each_value(&:freeze)
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
                def added_child(child, info) # :nodoc:
                    super
                    relation_graphs[Dependency].update_triggers_for(self, child, info)
                end

                # Return the set of this task children for which the :start event has
                # no parent in CausalLinks
                def first_children
                    result = Set.new

                    causal_link_graph = plan.event_relation_graph_for(EventStructure::CausalLink)
                    relation_graph_for(Dependency).depth_first_visit(self) do |task|
                        next if task == self

                        if task != self && causal_link_graph.root?(task.start_event)
                            result << task
                        end
                    end
                    result
                end

                # Sets a base model specification that must be met by this task
                #
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
                def fullfilled_model=(model)
                    unless model[0].kind_of?(Class)
                        raise ArgumentError, "expected a task model as first element, got #{model[0]}"
                    end
                    if !model[1].respond_to?(:to_ary)
                        raise ArgumentError, "expected an array as second element, got #{model[1]}"
                    elsif !model[1].all? { |t| t.kind_of?(Roby::Models::TaskServiceModel) }
                        raise ArgumentError, "expected an array of model tags as second element, got #{model[1]}"
                    end

                    unless model[2].respond_to?(:to_hash)
                        raise ArgumentError, "expected a hash as third element, got #{model[2]}"
                    end

                    @fullfilled_model = model
                end

                # The list of models and arguments that this task fullfilles
                #
                # If there is a task model in the list of models, it is always the first
                # element of the model set
                #
                # @return [(Array<Model<Task>,Model<TaskService>>,{String=>Object}]
                #
                # Beware that, for historical reasons, this is not the same format than
                # {#fullfilled_model=}
                def fullfilled_model
                    if current_model = explicit_fullfilled_model
                        has_value = true
                    else
                        current_model = [Roby::Task, [], {}]
                    end

                    each_in_neighbour_merged(Dependency, intrusive: false) do |myself, parent|
                        has_value = true

                        required_models, required_arguments = parent[myself, Dependency][:model]
                        current_model = Dependency.merge_fullfilled_model(current_model,
                                                                          required_models, required_arguments)
                    end

                    if !has_value
                        model = self.model.fullfilled_model.find_all { |m| m <= Roby::Task }.min
                        [[model], self.meaningful_arguments]
                    else
                        model, tags, arguments = *current_model
                        tags = tags.dup
                        tags.unshift model
                        [tags, arguments]
                    end
                end

                # True if #fullfilled_model has been set on this task or on this task's
                # model
                #
                # @return [Boolean]
                def explicit_fullfilled_model?
                    !!explicit_fullfilled_model
                end

                # Returns an explicitly set {#fullfilled_model}
                #
                # @return [nil,Object] either nil if no explicit model has been set, or
                #   the model in the same format as expected by {#fullfilled_model=}
                #   (which is different than the value returned by {#fullfilled_model})
                def explicit_fullfilled_model
                    if explicit = @fullfilled_model
                        explicit
                    elsif explicit = self.model.explicit_fullfilled_model
                        tasks, tags = explicit.partition { |m| m <= Roby::Task }
                        [tasks.first || Roby::Task, tags, {}]
                    end
                end

                # Returns the set of models this task is providing by itself
                #
                # It differs from #fullfilled_model because it is not considering the
                # models that are required because of the dependency relation
                #
                # @return [Array<Models::Task,TaskService>]
                # @see #fullfilled_model
                def provided_models
                    if model = explicit_fullfilled_model
                        [model[0]] + model[1]
                    else
                        models = self.model.fullfilled_model
                        if (task_class = models.find { |m| m.kind_of?(Class) })
                            [task_class] + models.find_all { |m| !task_class.has_ancestor?(m) }
                        else
                            models
                        end
                    end
                end

                # Enumerates the models that are fullfilled by this task
                #
                # @return [Array<Model<Task>,TaskService>]
                # @see #provided_models
                def each_fullfilled_model(&block)
                    fullfilled_model[0].each(&block)
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

                def has_through_method_missing?(m)
                    MetaRuby::DSLs.has_through_method_missing?(
                        self, m, "_child" => :has_role?)
                end

                def find_through_method_missing(m, args)
                    MetaRuby::DSLs.find_through_method_missing(
                        self, m, args, "_child" => :find_child_from_role)
                end
            end

            module ModelExtension
                # True if a fullfilled model has been explicitly set on self
                # @return [Boolean]
                def explicit_fullfilled_model?
                    !!@fullfilled_model
                end

                # Returns an explicitly set {#fullfilled_model}
                #
                # @return [nil,Array<Models::Task,TaskService>] either nil if no
                #   explicit model has been set, or the list of models it must fullfill
                def explicit_fullfilled_model
                    @fullfilled_model
                end

                # Specifies the models that all instances of this task must fullfill
                #
                # This is usually used to under-constraint the model instances
                #
                # @param [Array<Models::Task,TaskService>] models the list of models
                def fullfilled_model=(models)
                    if !models.respond_to?(:to_ary)
                        raise ArgumentError, "expected an array, got #{models}"
                    elsif !models.all? { |t| t.kind_of?(Roby::Models::TaskServiceModel) || (t.respond_to?(:<=) && (t <= Roby::Task)) }
                        raise ArgumentError, "expected a submodel of TaskService, got #{models}"
                    end

                    @fullfilled_model = models
                end

                # @api private
                #
                # @return [Array<Models::Task,TaskService>] the list of models
                #   fullfilled by this task
                def implicit_fullfilled_model
                    unless @implicit_fullfilled_model
                        @implicit_fullfilled_model = []
                        ancestors.each do |m|
                            next if m.singleton_class?

                            if m.kind_of?(Class) || (m.kind_of?(Roby::Models::TaskServiceModel) && m != Roby::TaskService)
                                @implicit_fullfilled_model << m
                            end

                            if m == Roby::Task
                                break
                            end
                        end
                    end
                    @implicit_fullfilled_model
                end

                # Returns the model that all instances of this taks model fullfill
                #
                # (see Dependency::Extension#fullfilled_model)
                def fullfilled_model
                    explicit_fullfilled_model || implicit_fullfilled_model
                end

                # Enumerates the models that all instances of this task model fullfill
                #
                # @yieldparam [Model<Task>,Model<TaskService>] model
                # @return [void]
                def each_fullfilled_model(&block)
                    fullfilled_model.each(&block)
                end
            end
        end
    end

    # This exception is raised when a {hierarchy relation}[classes/Roby/TaskStructure/Hierarchy.html] fails
    class ChildFailedError < RelationFailedError
        # The child in the relation
        def child
            failed_task
        end
        # The relation parameters (i.e. the hash given to #depends_on)
        attr_reader :relation
        # The Explanation object that describes why the relation failed
        attr_reader :explanation
        # @return [Symbol] the fault mode. It can either be :failed_event or
        #   :unreachable_success
        attr_reader :mode

        def initialize(parent, child, explanation, mode)
            @explanation = explanation
            @mode = mode

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
                        if reason.respond_to?(:task) && reason.task == child
                            reason
                        else
                            base_event
                        end
                    elsif base_event.respond_to?(:root_task_sources)
                        sources = base_event.root_task_sources
                        if sources.size == 1
                            sources.first
                        else
                            base_event
                        end
                    else
                        base_event
                    end
                end

            super(failure_point)

            report_exceptions_from(explanation)
            @parent   = parent
            @relation = parent[child, TaskStructure::Dependency]
            if @relation
                @relation = @relation.dup
            end
        end

        def pretty_print(pp) # :nodoc:
            child.pretty_print(pp)
            pp.breakable
            pp.text "child '#{relation[:roles].to_a.join(', ')}' of "
            parent.pretty_print(pp)
            pp.breakable
            pp.breakable
            case mode
            when :failed_event
                pp.text "Child triggered the failure predicate '#{relation[:failure]}': "
            when :unreachable_success
                pp.text "success condition can no longer be reached '#{relation[:success]}': "
            end
            explanation.pretty_print(pp, context_task: child)
        end

        def backtrace
            []
        end

        # True if +obj+ is involved in this exception
        def involved_plan_object?(obj)
            super || obj == parent
        end
    end
end
