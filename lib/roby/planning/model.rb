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

	# A plan has not been found
        class NotFound < PlanModelError
            attr_reader :errors
            attr_accessor :method_name, :method_options
            def initialize(planner, errors)
                @errors = errors
                super(planner)
            end

            def to_s
                "cannot find a #{method_name}(#{method_options.inspect}) method\n" + 
                    errors.inject("") { |s, (m, e)| s << "  in #{m}: #{e} (#{e.backtrace[0]})\n" }
            end
        end

	# Some common tools for Planner and Library
	module Tools
	    def using(mod)
		if mod.respond_to?(:planning_methods)
		    include mod
		elsif mod = (mod.const_get('Planning') rescue nil)
		    include mod
		else
		    raise ArgumentError, "#{mod} is not a planning library and has no Planning module which is one"
		end
	    end
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

            module MethodInheritance
                # Checks that options in +options+ can be used to overload +self+. Updates options if needed
                def validate(options)
                    if returns 
                        if options[:returns] && !(options[:returns] == returns || options[:returns] < returns)
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

	    # A particular method
            class MethodDefinition
                include MethodInheritance

                attr_reader :name, :options, :body
                def initialize(name, options, &body)
                    @name, @options, @body = name, options, body
                end

		# The method ID
                def id;         options[:id] end
		# If this method handles recursion
                def recursive?; options[:recursive] end
		# What kind of task this method returns
                def returns;    options[:returns] end
		# If the method allows reusing tasks already in the plan
		# reuse? is always false if there is no return type defined
		def reuse?;	options[:reuse] if returns end
		# Call the method definition
                def call;       body.call end

                def to_s; "#{name}:#{id}(#{options.inspect})" end
            end

	    # A method model
            class MethodModel
                include MethodInheritance

		# If this model defines a return type
                def returns;    options[:returns] end
		# If the model allows reusing tasks already in the plan
		def reuse?;	options[:reuse] end

		# The model name
                attr_reader :name
		# The model options, as a Hash
		attr_reader :options

                def initialize(name, options = Hash.new); @name, @options = name, options end
		def ==(model)
		    name == model.name && options == model.options
		end

		# :call-seq
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

                def to_s; "#{name}(#{options.inspect})" end
            end

	    # A list of options on which the methods are selected
	    # in find_methods
	    # 
	    # When calling a planning method, only the methods for
	    # which these options match the user-provided options
	    # are called. The other options are not considered
	    METHOD_SELECTION_OPTIONS = [:id, :recursive, :returns]
	    KNOWN_OPTIONS = [:lazy, :reuse] + METHOD_SELECTION_OPTIONS

            def self.validate_method_query(name, options)
                name = name.to_s
		options = options.keys_to_sym

                validate_option(options, :returns, false, 
                                "the ':returns' option must be a subclass of Roby::Task") do |opt| 
                    options[:returns].has_ancestor?(Roby::Task)
                end

		roby_options, method_arguments = {}, {}
		roby_options	    = options.slice(*KNOWN_OPTIONS)
		method_arguments    = options.slice(*(options.keys - KNOWN_OPTIONS))
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
		if respond_to?("#{name}_methods")
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
		elsif respond_to?("#{name}_methods")
		    raise ArgumentError, "cannot change the method model for #{name} since methods are already using it"
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

		# Define the method enumerator and the method selection
		if !respond_to?("#{name}_methods")
		    class_inherited_enumerable("#{name}_method", "#{name}_methods", :map => true) { Hash.new }
		    class_eval <<-PLANNING_METHOD_END
		    def #{name}(options = Hash.new)
			plan_method("#{name}", options)
		    end
		    PLANNING_METHOD_END
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
		send("#{name}_methods")[method_id] = MethodDefinition.new(name, options, &lambda(&body) )
            end

	    # Add a selection filter on the +name+ method. When developing the +name+
	    # method, the filter is called with each MethodDefinition object, and should return
	    # +false+ if the method is to be discarded, and +true+ otherwise
	    def self.filter(name, &filter)
		if !respond_to?("#{name}_filters")
		    class_inherited_enumerable("#{name}_filter", "#{name}_filters") { Array.new }
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
		    result = enum_for(:each_method, name, method_id).find { true }
		    result = if result && result.options.merge(method_selection) == result.options
				 [result]
			     end
		else
		    result = enum_for(:each_method, name, nil).collect do |id, m|
			if m.options.merge(method_selection) == m.options 
			    m
			end
		    end.compact
		end

		return nil if !result

		filter_method = "each_#{name}_filter"
		if respond_to?(filter_method)
		    # Remove results for which at least one filter returns false
		    result.reject! { |m| enum_for(filter_method).any? { |f| !f[m] } }
		end

		if result.empty?; nil
		else; result
		end
            end

	    # If there is method definitions for +name+
	    def has_method?(name); singleton_class.has_method?(name) end
	    def self.has_method?(name); respond_to?("#{name}_methods") end

	    def self.model_of(name, options)
		base_model = method_model(name)
		if options[:id]
		    send("#{name}_methods").each { |m| return(m) if m.id == options[:id] } || base_model
		else
		    base_model
		end
	    end

            # Find a suitable development for the +name+ method.
            def plan_method(name, options = Hash.new)
                name    = name.to_s
		options = options.keys_to_sym
		# Save the user arguments in the +arguments+ attribute
		args = if options.respond_to?(:args)
			   options[:args]
		       else
			   options.slice(*(options.keys - KNOWN_OPTIONS))
		       end

		@arguments.push(args || {})

		Planning.debug { "planning #{name}[#{arguments.inspect}]" }

		# Check for recursion
                if @stack.include?(name)
                    options[:recursive] = true
                    options[:lazy] = true
                end
		
		# Get all valid methods
                methods = singleton_class.find_methods(name, options)
                if !methods
                    raise NotFound.new(self, Hash.new)
                elsif options[:lazy]
                    task = PlanningTask.new(self.plan, self.class, name, options)
		    return task
		end
		
		# Check if we can reuse a task already in #result
		all_returns = methods.map { |m| m.returns if m.reuse? }
		if (model = singleton_class.method_model(name)) && !options[:id]
		    all_returns << model.returns if model.reuse?
		end
		all_returns.compact!
				  
		all_returns.each do |return_type|
		    task = plan.enum_for(:each_task).find do |task|
			task.fullfills?(return_type, arguments)
		    end
		    if task
			Planning.debug { "selecting task #{task} instead of planning #{name}[#{arguments}]" }
			return task
		    end
		end

		# Call the methods
		call_planning_methods(Hash.new, options, *methods)

            rescue NotFound => e
                e.method_name       = name
                e.method_options    = options
                raise e
		
	    ensure
		@arguments.pop
            end

	    def arguments; @arguments.last end
	    private :arguments

            # Tries to find a successfull development in the provided method list.
            #
            # It raises NotFound if none of the methods returned successfully
            def call_planning_methods(errors, options, method, *methods)
                begin
                    @stack.push method.name
		    Planning.debug { "calling #{method.name}:#{method.id} with arguments #{arguments.inspect}" }
                    result = instance_eval(&method.body)

		    # Check that result is a task or a task collection
		    unless result && (result.respond_to?(:to_task) || result.respond_to?(:each) || !result.respond_to?(:each_task))
			raise PlanModelError.new(self), "#{method} returned #{result}, which is neither a task nor a task collection"
		    end

		    if method.returns && !result.fullfills?(method.returns, arguments)
			if !result then result = "nil"
			else result = "#{result}[#{result.arguments.inspect}]"
			end
			raise PlanModelError.new(self), "#{method} returned #{result} which does not fullfill #{method.returns}[#{arguments.inspect}]"
		    end
		    Planning.debug { "found #{result}" }

		    # Insert resulting tasks in +plan+
		    plan.discover(result)
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

	    def planning_methods; @methods ||= Array.new end
	    def method(name, options = Hash.new, &body)
		planning_methods << [name, options, body]
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
		    mod.planning_methods.each { |name, options, body| klass.method(name, options, &body) }
		end

	    rescue ArgumentError => e
		raise ArgumentError, "cannot include the #{self} library in #{klass}: #{e.message}", caller(0)
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
    def planning_library
	extend Roby::Planning::Library
    end
end

