require 'roby/planning/task'
require 'roby/task'
require 'roby/control'
require 'roby/plan'
require 'utilrb/module/ancestor_p'
require 'set'

module Roby
    # The Planning module provides basic tools to create plans (graph of tasks
    # and events)
    module Planning
        # Violation of plan models, for instance if a method returns a Task object
	# which is of a wrong model
        class PlanModelError < RuntimeError
            attr_accessor :planner
            def initialize(planner = nil)
                @planner = planner 
		super()
            end
        end

	# Raised a method has found no valid development
        class NotFound < PlanModelError
	    # The name of the method which has failed
            attr_accessor :method_name
	    # The planning options
	    attr_accessor :method_options
	    # A method => error hash of all the method that have
	    # been tried. +error+ can either be a NotFound exception
	    # or another exception
            attr_reader :errors

            def initialize(planner, errors)
                @errors = errors
                super(planner)
            end

	    def message
		if errors.empty?
		    "no candidate for #{method_name}(#{method_options})"
		else
		    msg = "cannot develop a #{method_name}(#{method_options}) method"
		    first, *rem = *Roby.filter_backtrace(backtrace)

		    full = "#{first}: #{msg}\n   from #{rem.join("\n  from ")}"
		    errors.each do |m, error|
			first, *rem = *Roby.filter_backtrace(error.backtrace)
			full << "\n#{first}: #{m} failed with #{error.message}\n  from #{rem.join("\n  from ")}"
		    end
		    full
		end
	    end

	    def full_message
		msg = message
		first, *rem = *Roby.filter_backtrace(backtrace)

		full = "#{first}: #{msg}\n   from #{rem.join("\n    from ")}"
		errors.each do |m, error|
		    first     = error.backtrace.first
		    full << "\n#{first} #{m} failed because of #{error.full_message}"
		end
		full
	    end
        end

	# Some common tools for Planner and Library
	module Tools
	    def using(*modules)
		modules.each do |mod|
		    if mod.respond_to?(:planning_methods)
			include mod
		    elsif planning_mod = (mod.const_get('Planning') rescue nil)
			include planning_mod
		    else
			raise ArgumentError, "#{mod} is not a planning library and has no Planning module which is one"
		    end
		end
	    end
	end

        # This mixin defines the method inheritance validation method. This is
        # then used by MethodDefinition and MethodModel
        module MethodInheritance
            # Checks that options in +options+ can be used to overload +self+.
            # Updates options if needed
            def validate(options)
                if returns 
                    if options[:returns] && !(options[:returns] <= returns)
                        raise ArgumentError, "return task type #{options[:returns]} forbidden since it overloads #{returns}"
                    else
                        options[:returns] ||= returns
                    end
                end

                if self.options.has_key?(:reuse)
                    if options.has_key?(:reuse) && options[:reuse] != self.options[:reuse]
                        raise ArgumentError, "the :reuse option is already set on the #{name} model"
                    end
                    options[:reuse] = self.options[:reuse]
                else
                    options[:reuse] = true unless options.has_key?(:reuse)
                end

                options
            end
        end

        # An implementation of a planning method.
        class MethodDefinition
            include MethodInheritance

            attr_reader :name, :options, :body
            def initialize(name, options, body)
                @name, @options, @body = name, options, body
            end

            # The method ID
            def id;         options[:id] end
            # If this method handles recursion
            def recursive?; options[:recursive] end
            # What kind of task this method returns
            #
            # If this is nil, the method may return a task array or a task
            # aggregation
            def returns;    options[:returns] end
            # If the method allows reusing tasks already in the plan
            # reuse? is always false if there is no return type defined
            def reuse?; (!options.has_key?(:reuse) || options[:reuse]) if returns end
            # Call the method definition
            def call(planner); body.call(planner) end

            def to_s; "#{name}:#{id}(#{options})" end
        end

        # The model of a planning method. This does not define an actual
        # implementation of the method, only the model methods should abide to.
        class MethodModel
            include MethodInheritance

            # The return type the method model defines
            #
            # If this is nil, methods of this model may return a task array
            # or a task aggregation
            def returns;    options[:returns] end
            # If the model allows reusing tasks already in the plan
            def reuse?; !options.has_key?(:reuse) || options[:reuse] end

            # The model name
            attr_reader :name
            # The model options, as a Hash
            attr_reader :options

            def initialize(name, options = Hash.new); @name, @options = name, options end
            def ==(model)
                name == model.name && options == model.options
            end

            # call-seq:
            #   merge(new_options)	    => self
            #
            # Add new options in this model. Raises ArgumentError if the
            # new options cannot be merged because they are incompatible
            # with the current model definition
            def merge(new_options)
                validate_options(new_options, [:returns, :reuse])
                validate_option(new_options, :returns, false) do |rettype| 
                    if options[:returns] && options[:returns] != rettype
                        raise ArgumentError, "return type already specified for method #{name}"
                    end
                    options[:returns] = rettype
                end
                validate_option(new_options, :reuse, false) do |flag|
                    if options.has_key?(:reuse) && options[:reuse] != flag
                        raise ArgumentError, "the reuse flag is already set to #{options[:reuse]} on #{name}"
                    end
                    options[:reuse] = flag
                    true
                end

                self
            end

            def overload(old_model)
                if old_returns = old_model.returns
                    if returns && !(returns < old_returns)
                        raise ArgumentError, "new return type #{returns} is not a subclass of the old one #{old_returns}"
                    elsif !returns
                        options[:returns] = old_returns
                    end
                end
                if options.has_key?(:reuse) && old_model.options.has_key?(:reuse) && options[:reuse] != old_model.reuse
                    raise ArgumentError, "the reuse flag for #{name}h as already been set to #{options[:reuse]} on our parent model"
                elsif !options.has_key?(:reuse) && old_model.options.has_key?(:reuse)
                    options[:reuse] = old_model.reuse
                end
            end
                    
            # Do not allow changing this model anymore
            def freeze
                options.freeze
                super
            end

            def initialize_copy(from) # :nodoc:
                @name    = from.name.dup
                @options = from.options.dup
            end

            def to_s; "#{name}(#{options})" end
        end

	# A planner searches a suitable development for a set of methods. 
	# Methods are defined using Planner::method. You can then ask
	# for a plan by sending your method name to the Planner object
	#
	# For instance
	#   
	#   class MyPlanner < Planner
	#	method(:do_it) {  }
	#	method(:do_sth_else) { ... }
	#   end
	#
	#   planner = MyPlanner.new
	#   planner.do_it		=> result of the do_it block
	# 
	# See Planner::method for a detailed description of the development
	# search
	#
        class Planner
	    extend Tools

	    # The resulting plan
	    attr_reader :plan

	    # Creates a Planner object which acts on +plan+
            def initialize(plan)
		@plan	   = plan
                @stack     = Array.new
		@arguments = Array.new
            end

	    # A list of options on which the methods are selected
	    # in find_methods
	    # 
	    # When calling a planning method, only the methods for
	    # which these options match the user-provided options
	    # are called. The other options are not considered
	    METHOD_SELECTION_OPTIONS = [:id, :recursive, :returns]
	    KNOWN_OPTIONS = [:lazy, :reuse, :args] + METHOD_SELECTION_OPTIONS

            def self.validate_method_query(name, options)
                name = name.to_s
		roby_options, method_arguments = 
		    filter_options options, KNOWN_OPTIONS

                validate_option(options, :returns, false, 
                                "the ':returns' option must be a task model") do |opt| 
                    opt.is_a?(Roby::TaskModelTag) ||
			opt.has_ancestor?(Roby::Task)
                end

		[name, roby_options, method_arguments]
            end

	    # Return the method model for +name+, or nil
            def self.method_model(name)
		model = send("#{name}_model")
	    rescue NoMethodError
	    end

            class << self
		def last_id; @@last_id ||= 0 end
		def last_id=(new_value); @@last_id = new_value end
                def next_id; self.last_id += 1 end
            end

	    # Some validation on the method IDs
	    # * an integer represented as a string is converted to integer form
	    # * a symbol is converted to string
	    def self.validate_method_id(method_id)
		method_id = method_id.to_s if Symbol === method_id

		if method_id.respond_to?(:to_str) && method_id.to_str =~ /^\d+$/
		    Integer(method_id)
		else
		    method_id
		end
	    end

	    # Creates, overloads or updates a method model
	    # Returns the MethodModel object
	    def self.update_method_model(name, options)
		name = name.to_s
		unless send("enum_#{name}_methods", nil).empty?
		    raise ArgumentError, "cannot change the method model for #{name} since methods are already using it"
		end

		old_model = method_model(name)
		new_model = MethodModel.new(name)
		new_model.merge(options)

		if old_model == new_model
		    if !instance_variable_get("@#{name}_model")
			instance_variable_set("@#{name}_model", new_model)
		    end
		    return new_model
		elsif instance_variable_get("@#{name}_model")
		    # old_model is defined at this level
		    return old_model.merge(options)
		else
		    unless respond_to?("#{name}_model")
			singleton_class.class_eval <<-EOD
			    def #{name}_model
				@#{name}_model || superclass.#{name}_model
			    end
			EOD
		    end
		    new_model.overload(old_model) if old_model
		    instance_variable_set("@#{name}_model", new_model)
		end
	    end

	    # call-seq:
	    #	method(name, option1 => value1, option2 => value2) { }	    => method definition
	    #	method(name, option1 => value1, option2 => value2)	    => method model
	    #
	    # In the first form, define a new method +name+. The given block
	    # is used as method definition. It shall either return a Task
	    # object or an object whose #each method yields task objects, or
	    # raise a PlanModelError exception, or of one of its subclasses.
	    #
	    # The second form defines a method model, which defines
	    # constraints on the method defined with this name
	    #
	    # == Overloading: using the +id+ option
	    # The +id+ option defines the method ID. The ID can be used 
	    # to override a method definition in submodels. For instance, 
	    # if you do
	    # 
	    #	class A < Planner
	    #	    method(:do_it, :id => 'first') { ... }
	    #	    method(:do_it, :id => 'second') { ... }
	    #	end
	    #	class B < A
	    #	    method(:do_it, :id => 'first') { ... }
	    #	end
	    #
	    # Then calling B.new.do_it will call the +first+ method defined
	    # in B and the +second+ defined in A
	    #
	    # If no method ID is given, an unique number is allocated. Try not
	    # using numbers as method IDs yourself, since you could overload
	    # an automatic ID.
	    #
	    # == Constraining the returned object
	    # The +returns+ option defines what kind of Task object this method
	    # shall return. 
	    #
	    # For instance, in
	    # 
       	    #	class A < Planner
	    #	    method(:do_it, :id => 'first', :returns => MyTask) { ... }
	    #	    method(:do_it, :id => 'second') { ... }
	    #	end
	    #	class B < A
	    #	    method(:do_it, :id => 'first') { ... }
	    #	end
	    #
	    # The +do_it+ method defined in B will have to return a MyTask-derived
	    # Task object. Method models can be used to put a constraint on all
	    # methods of a given name. For instance, in the following example, all
	    # +do_it+ methods would have to return MyTask-based objects
	    # 
	    #	class A < Planner
	    #	    method(:do_it, :returns => MyTask)
	    #	    method(:do_it, :id => 'first') { ... }
	    #	    method(:do_it, :id => 'second') { ... }
	    #	end
	    #
	    # == Recursive call to methods
	    # If the +recursive+ option is true, then the method can be called back even if it
	    # currently being developed. The default is false
	    #
	    # For instance, the following example will raise a NoMethodError:
	    #
	    #	class A < Planner
	    #	    method(:do_it) { do_it }
	    #	end
	    #	A.new.do_it
	    #
	    # while this one will behave properly
	    #
	    #	class A < Planner
	    #	    method(:do_it) { do_it }
	    #	    method(:do_it, :recursive => true) { ... }
	    #	end
	    #
	    # == Reusing already existing tasks in plan
	    # If the +reuse+ flag is set (the default), instead of calling a method
	    # definition, the planner will try to find a suitable task in the current 
	    # plan if the developed method defines a :returns attribute. Compatibility
	    # is checked using Task#fullfills?
	    #
	    # == Defined attributes
	    # For each method +name+, the planner class gets a few attributes and methods:
	    # * each_name_method iterates on all MethodDefinition objects for +name+
	    # * name_model returns the method model. It is not defined if no method model exists
	    # * each_name_filter iterates on all filters for +name+
	    def self.method(name, options = Hash.new, &body)
                name, options = validate_method_query(name, options)
		
		# Define the method enumerator and the method selection
		if !respond_to?("#{name}_methods")
		    inherited_enumerable("#{name}_method", "#{name}_methods", :map => true) { Hash.new }
		    class_eval <<-PLANNING_METHOD_END
		    def #{name}(options = Hash.new)
			plan_method("#{name}", options)
		    end
		    class << self
		      cached_enum("#{name}_method", "#{name}_methods", true)
		    end
		    PLANNING_METHOD_END
		end

		# We are updating the method model
                if !body
                    return update_method_model(name, options)
                end
                
		# Handle the method ID
		if method_id = options[:id]
		    method_id = validate_method_id(method_id)
		    if method_id.respond_to?(:to_int)
			self.last_id = method_id if self.last_id < method_id
		    end
		else
		    method_id = next_id
		end
		options[:id] = method_id
		
		# Get the method model (if any)
                if model = method_model(name)
                    options = model.validate(options)
		    model.freeze
                end

		# Check if we are overloading an old method
		if send("#{name}_methods")[method_id]
		    raise ArgumentError, "method #{name}:#{method_id} is already defined on this planning model"
                elsif old_method = find_methods(name, :id => method_id)
                    old_method = *old_method
                    options = old_method.validate(options)
                    Planning.debug { "overloading #{name}:#{method_id}" } 
                end

		# Register the method definition
		#
		# First, define an "anonymous" method on this planner model to
		# avoid calling instance_eval during planning
		if body.arity > 0
		    raise ArgumentError, "method body must accept zero arguments calls"
		end
		temp_method_name = "m#{@@temp_method_id += 1}"
		define_method(temp_method_name, &body)
		send("#{name}_methods")[method_id] = MethodDefinition.new(name, options, instance_method(temp_method_name))
            end
	    @@temp_method_id = 0

	    # Returns an array of the names of all planning methods
	    def self.planning_methods_names
		names = Set.new
		methods.each do |method_name|
		    if method_name =~ /^each_(\w+)_method$/
			names << $1
		    end
		end

		names
	    end

	    def self.clear_model
		planning_methods_names.each do |name|
		    remove_planning_method(name)
		end
	    end

	    # Undefines all the definitions for the planning method +name+ on
	    # this model. Definitions available on the parent are not removed
	    def self.remove_planning_method(name)
		remove_method(name)
		remove_inherited_enumerable("#{name}_method", "#{name}_methods")
		if method_defined?("#{name}_filter")
		    remove_inherited_enumerable("#{name}_filter", "#{name}_filters")
		end
	    end

	    def self.remove_inherited_enumerable(enum, attr = enum)
		if instance_variable_defined?("@#{attr}")
		    remove_instance_variable("@#{attr}")
		end
		singleton_class.class_eval do
		    remove_method("each_#{enum}")
		    remove_method(attr)
		end
	    end

	    # Add a selection filter on the +name+ method. When developing the
	    # +name+ method, the filter is called with the method options and
	    # the MethodDefinition object, and should return +false+ if the
	    # method is to be discarded, and +true+ otherwise
	    #
	    # Example
	    #    class MyPlanner < Planning::Planner
	    #	    method(:m, :id => 1) do
	    #	      raise
	    #	    end
	    #
	    #	    method(:m, :id => 2) do
	    #	      Roby::Task.new
	    #	    end
	    #
	    #	    # the id == 1 version of m fails, remove it of the set
	    #	    # of valid methods
	    #	    filter(:m) do |opts, m|
	    #	      m.id == 2
	    #	    end
	    #    end
	    #
	    # This is mainly useful for external selection of methods (for
	    # instance to implement some kind of dependency injection), or for
	    # testing
	    def self.filter(name, &filter)
                check_arity(filter, 2)

		if !respond_to?("#{name}_filters")
		    inherited_enumerable("#{name}_filter", "#{name}_filters") { Array.new }
		    class_eval <<-EOD
			class << self
			    cached_enum("#{name}_filter", "#{name}_filters", false)
			end
		    EOD
		end
		send("#{name}_filters") << filter
	    end

	    def self.each_method(name, id, &iterator)
		send("each_#{name}_method", id, &iterator)
	    end

	    # Find all methods that can be used to plan +[name, options]+. The selection is
	    # done in two steps:
	    # * we search all definition of +name+ that are compatible with +options. In this
	    #   stage, only the options listed in METHOD_SELECTION_OPTIONS are compared
	    # * we call the method filters (if any) to remove unsuitable methods
            def self.find_methods(name, options = Hash.new)
		# validate the options hash, and split it into the options that are used for
		# method selection and the ones that are ignored here
                name, options = validate_method_query(name, options)
		method_selection = options.slice(*METHOD_SELECTION_OPTIONS)

		if method_id = method_selection[:id]
		    method_selection[:id] = method_id = validate_method_id(method_id)
		    result = send("enum_#{name}_methods", method_id).find { true }
		    result = if result && result.options.merge(method_selection) == result.options
				 [result]
			     end
		else
		    result = send("enum_#{name}_methods", nil).collect do |id, m|
			if m.options.merge(method_selection) == m.options 
			    m
			end
		    end.compact
		end

		return nil if !result

		filter_method = "enum_#{name}_filters"
		if respond_to?(filter_method)
		    # Remove results for which at least one filter returns false
		    result.reject! { |m| send(filter_method).any? { |f| !f[options, m] } }
		end

		if result.empty?; nil
		else; result
		end
            end

	    # If there is method definitions for +name+
	    def has_method?(name); singleton_class.has_method?(name) end
	    def self.has_method?(name); respond_to?("#{name}_methods") end

	    # Returns the method model that should be considered when using
	    # the result of the method +name+ with options +options+
	    #
	    # This model should be used for instance when adding a new
	    # hierarchy relation between a parent and the result of 
	    # <tt>plan.#{name}(options)</tt>
	    def self.model_of(name, options = {})
		model = if options[:id]
			    enum_for("each_method", name, options[:id]).find { true }
			end
		model ||= method_model(name)
		model || default_method_model(name)
	    end

	    def self.default_method_model(name)
		MethodModel.new(name, :returns => Task)
	    end

	    # Creates a planning task which will call the same planning method
	    # than the one currently being generated.
	    #
	    # +options+ is an option hash. These options are used to override
	    # the current method options. Only one option is recognized by
	    # +replan_task+:
	    #
	    # strict:: if true, we use the current method name and id for 
	    #          the planning task. If false, use only the method name.
	    #	       defaults to true.
	    def replan_task(options = nil)
		method_options = arguments.dup
		if !options.has_key?(:strict) || options.delete(:strict)
		    method_options.merge!(:id => @stack.last[1])
		end

		if options
		    method_options.merge!(options)
		end

		Roby::PlanningTask.new :planner_model => self.class,
		    :method_name => @stack.last[0], 
		    :method_options => method_options
	    end

            def stop; @stop_required = true end
            def interruption_point; raise Interrupt, "interrupted planner" if @stop_required end

            # Find a suitable development for the +name+ method.
            def plan_method(name, options = Hash.new)
                if @stack.empty?
                    @stop_required = false
                end
                interruption_point

                name    = name.to_s

		planning_options, method_options = 
		    filter_options options, KNOWN_OPTIONS

		if method_options.empty?
		    method_options = planning_options.delete(:args) || {}
		elsif planning_options[:args] && !planning_options[:args].empty?
		    raise ArgumentError, "provided method-specific options through both :args and the option hash"
		end
		@arguments.push(method_options)

		Planning.debug { "planning #{name}[#{arguments}]" }

		# Check for recursion
                if (options[:id] && @stack.include?([name, options[:id]])) || (!options[:id] && @stack.find { |n, _| n == name })
                    options[:recursive] = true
                end

		# Get all valid methods. If no candidate are found, still try 
		# to get a task to re-use
                methods = singleton_class.find_methods(name, options)
		
		# Check if we can reuse a task already in the plan
		if !options.has_key?(:reuse) || options[:reuse]
		    all_returns = if methods
				      methods.map { |m| m.returns if m.reuse? }
				  else []
				  end
		    if (model = singleton_class.method_model(name)) && !options[:id]
			all_returns << model.returns if model.reuse?
		    end
		    all_returns.compact!
				      
		    for return_type in all_returns
			if task = find_reusable_task(return_type)
			    return task
			end
		    end
		end

                if !methods || methods.empty?
                    raise NotFound.new(self, Hash.new)
		end

		# Call the methods
		call_planning_methods(Hash.new, options, *methods)

            rescue Interrupt
                raise

            rescue NotFound => e
                e.method_name       = name
                e.method_options    = options
                raise e
		
	    ensure
		@arguments.pop
            end
	    
	    def find_reusable_task(return_type)
		query = plan.find_tasks.
		    which_fullfills(return_type, arguments).
		    self_owned.
		    not_abstract.
		    not_finished.
		    roots(TaskStructure::Hierarchy)

		for candidate in query
		    Planning.debug { "selecting task #{candidate} instead of planning #{return_type}[#{arguments}]" }
		    return candidate
		end
		nil
	    end

	    def arguments; @arguments.last end
	    private :arguments

            # Tries to find a successfull development in the provided method list.
            #
            # It raises NotFound if none of the methods returned successfully
            def call_planning_methods(errors, options, method, *methods)
                begin
                    @stack.push [method.name, method.id]
		    Planning.debug { "calling #{method.name}:#{method.id} with arguments #{arguments}" }
		    begin
			result = method.call(self)
		    rescue PlanModelError, Interrupt
			raise
		    rescue Exception => e
			raise PlanModelError.new(self), e.message, e.backtrace
		    end

		    # Check that result is a task or a task collection
		    unless result && (result.respond_to?(:to_task) || result.respond_to?(:each) || !result.respond_to?(:each_task))
			raise PlanModelError.new(self), "#{method} returned #{result}, which is neither a task nor a task collection"
		    end
		    
		    # Insert resulting tasks in +plan+
		    plan.discover(result)

		    expected_return = method.returns
		    if expected_return 
			if !result.respond_to?(:to_task) || 
			    !result.fullfills?(expected_return, arguments.slice(*expected_return.arguments))

			    if !result then result = "nil"
			    elsif result.respond_to?(:each)
				result = result.map { |t| "#{t}(#{t.arguments})" }.join(", ")
			    else result = "#{result}(#{result.arguments})"
			    end
			    raise PlanModelError.new(self), "#{method} returned #{result} which does not fullfill #{method.returns}(#{arguments})"
			end
		    end
		    Planning.debug { "found #{result}" }

		    result

                ensure
                    @stack.pop
                end

            rescue PlanModelError => e
                e.planner = self unless e.planner
                errors[method] = e
                if methods.empty?
                    raise NotFound.new(self, errors)
                else
                    call_planning_methods(errors, options, *methods)
                end
            end

            private :call_planning_methods

	    # Builds a loop in a plan (i.e. a method which is generated in
	    # loop)
	    def make_loop(options = {}, &block)
		raise ArgumentError, "no block given" unless block

		options.merge! :planner_model => self.class, :method_name => 'loops'
		_, planning_options = PlanningLoop.filter_options(options)

                loop_id = Planner.next_id
                if !@stack.empty?
                    loop_id = "#{@stack.last[1]}_#{loop_id}"
                end
                planning_options[:id] = loop_id
                planning_options[:reuse] = false
                m = self.class.method('loops', planning_options, &block)

		options[:method_options] ||= {}
		options[:method_options].merge!(arguments || {})
		options[:method_options][:id] = m.id
		PlanningLoop.new(options)
	    end
        end

	# A planning Library is only a way to gather a set of planning
	# methods. It is created by
	#   module MyLibrary
	#      planning_library
	#      method(:bla) do
	#      end
	#   end
	# or 
	#   my_library = Roby::Planning::Library.new do
	#       method(:bla) do end
	#   end
	#
	# It is then used by simply including the library in another library
	# or in a Planner class 
	# 
	#	module AnotherLibrary
	#	    include MyLibrary
	#	end
	#
	#	class MyPlanner < Planner
	#	    include AnotherLibrary
	#	end
	#
	# Alternatively, you can use Planner::use and Library::use, which search
	# for a Planning module in the given module. For instance
	#
	#	module Namespace
	#	    module Planning
	#	    planning_library
	#	    [...]
	# 	    end
	# 	end
	#
	# can be used with
	#	    
	#	class MyPlanner < Planner
	#	    using Namespace
	#	end
	#
	module Library
	    include Tools

	    attr_reader :default_options

	    def planning_methods; @methods ||= Array.new end
	    def method(name, options = Hash.new, &body)
		if body && default_options
		    options = default_options.merge(options)
		end
		planning_methods << [name, options, body]
	    end

	    def self.clear_model
		planning_methods.clear
	    end

	    # Cannot use included here because included() is called *after* the module
	    # has been included
	    def append_features(klass)
		new_libraries = ancestors.enum_for.
		    reject { |mod| klass < mod }.
		    find_all { |mod| mod.respond_to?(:planning_methods) }

		super

		unless klass < Planner
		    if Class === klass
			Roby.debug "including a planning library in a class which is not a Planner, which is useless"
		    else
			klass.extend Library
		    end
		    return
		end

		new_libraries.reverse_each do |mod|
		    mod.planning_methods.each do |name, options, body| 
			begin
			    klass.method(name, options, &body)
			rescue ArgumentError => e
			    raise ArgumentError, "cannot include the #{self} library in #{klass}: when inserting #{name}#{options}, #{e.message}", caller(0)
			end
		    end
		end
	    end

	    def self.new(&block)
		Module.new do
		    extend Library
		    class_eval(&block)
		end
	    end
	end

    end
end


class Module
    def planning_library(default_options = Hash.new)
	extend Roby::Planning::Library
	instance_variable_set(:@default_options, default_options)
    end
end

