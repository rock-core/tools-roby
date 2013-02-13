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

        # Structure that stores the information about planning method arguments
        #
        # See MethodDescription
        MethodArgDescription = Struct.new :name, :doc, :required

        # Description of a single planning method
        #
        # This is usually not created manually, but created in a planner model
        # using #description:
        #
        #   class MyPlanner < Roby::Planning::Planner
        #     description('the following method does this and that').
        #       required_arg('arg1', 'this argument is required').
        #       optional_arg('arg2', 'but this one can be omitted')
        #     method('the_planning_method') do
        #       Roby::Task.new
        #     end
        #   end
        #
        class MethodDescription
            # The method name
            attr_accessor :name
            # The method description
            attr_accessor :doc
            # The description of the method arguments, as an array of
            # MethodArgDescription instances
            attr_reader :arguments
            ##
            # :method:advanced?
            #
            # If true, the method is flagged as advanced. I.e., it won't be
            # listed by default in the shell when the 'actions' command is
            # called
            attr_predicate :advanced?

            def initialize(doc = nil)
                @doc = doc
                @arguments = []
            end

            # Documents a new required argument to the method
            def required_arg(name, doc)
                arguments << MethodArgDescription.new(name, doc, true)
                self
            end
            # Documents a new optional argument to the method
            def optional_arg(name, doc)
                arguments << MethodArgDescription.new(name, doc, false)
                self
            end
            # Sets the advanced flag to true. See #advanced?
            def advanced
                @advanced = true 
                self
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

            def pretty_print(pp)
		if errors.empty?
		    pp.text "no candidate for #{method_name}(#{method_options})"
		else
                    first, *rem = Roby.filter_backtrace(backtrace)
                    pp.text "cannot develop a #{method_name}(#{method_options.to_s[1..-2]}) method"
                    pp.breakable
                    pp.group(4, "    ") do
                        rem.each do |line|
                            pp.text "from #{line}"
                            pp.breakable
                        end
                    end

                    pp.breakable
		    errors.each do |m, error|
                        if error.kind_of?(NotFound)
                            first, *rem = *Roby.filter_backtrace(error.backtrace)
                            pp.text "in method #{m}"
                            pp.breakable
                            error.pretty_print(pp)
                        else
                            first, *rem = *Roby.filter_backtrace(error.backtrace)
                            pp.text "planning method #{m} failed"
                            pp.breakable
                            pp.text "#{first}: #{error.message}"
                            pp.breakable
                            pp.group(4, "    ") do
                                rem.each do |line|
                                    pp.text "from #{line}"
                                    pp.breakable
                                end
                            end
                        end
		    end
		end
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
        #
        # This is usually not created manually, but by calling Planner.method
        #
        #  class MyPlanner < Roby::Planning::Planner
        #    method(:my_planning_method) do
        #    end
        #  end
        #
        class MethodDefinition
            include MethodInheritance

            attr_reader :planner_model, :name, :options, :body
            def initialize(planner_model, name, options, body)
                @planner_model, @name, @options, @body = planner_model, name, options, body
            end

            # The method ID
            def id;         options[:id] end
            # If this method handles recursion
            def recursive?; options[:recursive] end
            # What kind of task this method returns
            #
            # If this is nil, the method may return a task array or a task
            # aggregation
            def returns;    options[:returns] || Roby::Task end
            def returned_type; returns end
            # If the method allows reusing tasks already in the plan
            # reuse? is always false if there is no return type defined
            def reuse?; options[:reuse] end
            # Call the method definition
            def call(planner); body.call(planner) end

            def to_s
                opts = options.dup
                opts.delete :id
                "#{name}:#{id}(#{opts.to_s[1..-2]})"
            end

            def plan_pattern(arguments = Hash.new)
                if returned_type.kind_of?(Roby::TaskModelTag)
                    planned_model = Class.new(Roby::Task)
                    planned_model.include returned_type
                else
                    # Create an abstract task which will be planned
                    planned_model = returned_type
                end

                planner = Roby::PlanningTask.new(
                    :planner_model => planner_model,
                    :planned_model => planned_model,
                    :planning_method => self,
                    :method_options => arguments)
                planner.planned_task
            end

            # Intermediate representation used during marshalling
            class DRoby
                attr_reader :planner_model, :name, :options
                def initialize(planner_model, name, options)
                    @planner_model, @name, @options = name, options
                end

                def _dump(lvl) # :nodoc:
                    Marshal.dump([planner_model, name, options])
                end

                def self._load(str) # :nodoc:
                    DRoby.new(*Marshal.load(str))
                end

                def proxy(peer)
                    MethodDefinition.new(peer.local_object(planner_model), name, options, nil)
                end
            end

            # Returns an intermediate representation of the method definition
            # suitable for marshalling (distributed Roby and/or logging)
            def droby_dump(dest)
                DRoby.new(planner_model.droby_dump(dest), name, options)
            end
        end

        class FreeMethod < MethodDefinition
            def initialize(planner_model, name, options, body)
                check_arity(body, 1)
                super
            end

            def call(planner); planner.instance_eval(&body) end
        end

        # The model of a planning method. This does not define an actual
        # implementation of the method, only the model methods should abide to.
        class MethodModel
            include MethodInheritance

            attr_reader :planner_model

            # The return type the method model defines
            #
            # If this is nil, methods of this model may return a task array
            # or a task aggregation
            def returns;    options[:returns] || Roby::Task end
            # Backward compatibilty to support transition to the action
            # interface
            def returned_type; returns end
            # If the model allows reusing tasks already in the plan
            def reuse?; options[:reuse] end

            # The model name
            attr_reader :name
            # The model options, as a Hash
            attr_reader :options

            def initialize(planner_model, name, options = Hash.new)
                @planner_model, @name, @options = planner_model, name, options
            end
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
                super
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
            extend Distributed::DRobyModel::Dump

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
		new_model = MethodModel.new(self, name)
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
			singleton_class.class_eval <<-EOD, __FILE__, __LINE__+1
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
            #   describe(first_line, second_line, ...).
            #       required_arg(arg_name, arg_doc).
            #       optional_arg(arg_name, arg_doc)
            #
            # Describes the next method or method model. It adds a description
            # text for the method, which can be shown for instance by the
            # shell's "action" command. It is also possible to describe the
            # expected method arguments.
            def self.describe(*text)
                if text.empty?
                    text = ["(no description set)"]
                else
                    text.map! { |s| s.to_str }
                end

                @next_method_description = MethodDescription.new(text)
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
		
		# Define the method enumerator and the method public interface
		if !respond_to?("#{name}_methods")
                    if method_defined?(name)
                        raise ArgumentError, "#{name} is already a normal method name on #{self}, cannot add a planning method with that name"
                    end
		    class_eval <<-PLANNING_METHOD_END, __FILE__, __LINE__+1
		    def #{name}(options = Hash.new)
			plan_method("#{name}", options)
		    end
		    class << self
		      define_inherited_enumerable("#{name}_method", "#{name}_methods", :map => true) do
                          Hash.new
                      end
		      cached_enum("#{name}_method", "#{name}_methods", true)
	              def #{name}_description
	                if @#{name}_description
	                  return @#{name}_description
	                elsif defined? superclass and superclass.respond_to?("#{name}_description")
	                  return superclass.#{name}_description
	                end
                        nil
	              end
		    end
		    PLANNING_METHOD_END
		end
                if @next_method_description
                    if old_description = instance_variable_get("@#{name}_description")
                        raise "#{name} already has a description (#{old_description.doc.first})"
                    end
                    @next_method_description.name = name
                    instance_variable_set("@#{name}_description", @next_method_description)
                    @next_method_description = nil
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
                    old_method = old_method.first
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
                mdef = MethodDefinition.new(self, name, options, instance_method(temp_method_name))
		send("#{name}_methods")[method_id] = mdef
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

            def self.planning_methods
                names = methods.map do |method_name|
                    if method_name =~ /^each_(\w+)_method$/
                        $1
                    end
                end.compact.sort

                names.map do |name|
                    planning_method_description(name)
                end
            end
            
            def self.planning_method_description(name)
                description = instance_variable_get("@#{name}_description") 
                if description
                    return description
                elsif defined? superclass and superclass.respond_to?(:planning_method_description)
                    return superclass.planning_method_description(name)
                else
                    desc = MethodDescription.new(name)
                    desc.name = name
                    return desc
                end
            end
            def planning_method_description(name)
                model.planning_method_description(name)
            end

	    def self.clear_model
		planning_methods_names.each do |name|
		    remove_planning_method(name)
		end
	    end

	    # Undefines all the definitions for the planning method +name+ on
	    # this model. Definitions available on the parent are not removed
	    def self.remove_planning_method(name)
                instance_variable_set("@#{name}_description", nil)
                @next_method_description = nil

		remove_method(name)
		clear_inherited_enumerable("#{name}_method", "#{name}_methods")
		if method_defined?("#{name}_filter")
		    clear_inherited_enumerable("#{name}_filter", "#{name}_filters")
		end
	    end

	    def self.clear_inherited_enumerable(enum, attr = enum)
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
		    class_eval <<-EOD, __FILE__, __LINE__+1
			class << self
		            define_inherited_enumerable("#{name}_filter", "#{name}_filters") { Array.new }
			    cached_enum("#{name}_filter", "#{name}_filters", false)
			end
		    EOD
		end
		send("#{name}_filters") << filter
	    end

	    def self.each_method(name, id = nil, &iterator)
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
                    candidates = send("enum_#{name}_methods", method_id)
                else 
                    candidates = send("enum_#{name}_methods", nil).map { |a, b| b }
                end

                expected_model = method_selection.delete(:returns)
                candidates = candidates.find_all do |m|
                    if m.options.merge(method_selection) == m.options 
                        if !expected_model || (m.returns && m.returns.fullfills?(expected_model))
                            m
                        end
                    end
                end

		return nil if candidates.empty?

		filter_method = "enum_#{name}_filters"
		if respond_to?(filter_method)
		    # Remove results for which at least one filter returns false
		    candidates.reject! { |m| send(filter_method).any? { |f| !f[options, m] } }
		end

		if candidates.empty?; nil
		else; candidates
		end
            end

            # The model object for this instance. Usually self.class.
            def model; self.class end

	    # If there is method definitions for +name+
	    def has_method?(name); model.has_method?(name) end
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
                if !model
                    # If there is only one method with that name, use it
                    methods = enum_for("each_method", name).to_a
                    if methods.size == 1
                        model = methods[0][1]
                    end
                end

		model || default_method_model(name)
	    end

	    def self.default_method_model(name)
		MethodModel.new(self, name, :returns => Roby::Task)
	    end

            # Creates a TaskSequence with the given tasks
            def sequence(*tasks)
                seq = Sequence.new
                tasks.each { |t| seq << t }
                seq
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

		Roby::PlanningTask.new :planner_model => model,
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

		Planning.debug { "planning #{name}[#{method_options}]" }

		# Check for recursion
                if (options[:id] && @stack.include?([name, options[:id]])) || (!options[:id] && @stack.find { |n, _| n == name })
                    options[:recursive] = true
                end

		# Get all valid methods. If no candidate are found, still try 
		# to get a task to re-use
                methods = model.find_methods(name, options)
		
		# Check if we can reuse a task already in the plan
		if !options.has_key?(:reuse) || options[:reuse]
		    all_returns =
                        if methods
                            methods.map { |m| m.returns if (m.reuse? || options[:reuse]) }
                        else []
                        end

		    if (model = self.model.method_model(name)) && !options[:id]
			all_returns << model.returns if (model.reuse? || options[:reuse])
		    end
		    all_returns.compact!

		    for return_type in all_returns
			if task = find_reusable_task(return_type, method_options)
			    return task
			end
		    end
		end

                if !methods || methods.empty?
                    raise NotFound.new(self, Hash.new)
		end

		# Call the methods
		call_planning_methods(Hash.new, method_options, *methods)

            rescue Interrupt
                raise

            rescue NotFound => e
                e.method_name       = name
                e.method_options    = options
                raise e.dup, e.message, caller(1)
            end
	    
	    def find_reusable_task(return_type, method_options)
		query = plan.find_tasks.
		    which_fullfills(return_type, method_options).
		    self_owned.
		    not_abstract.
		    not_finished.
		    roots(TaskStructure::Hierarchy)

		for candidate in query
		    Planning.debug { "selecting task #{candidate} instead of planning #{return_type}[#{method_options}]" }
		    return candidate
		end
		nil
	    end

	    def arguments; @arguments.last end
	    private :arguments

            # Tries to find a successfull development in the provided method list.
            #
            # It raises NotFound if none of the methods returned successfully
            def call_planning_methods(errors, method_options, method, *methods)
                begin
                    @stack.push [method.name, method.id]
                    @arguments.push(method_options)
		    Planning.debug { "calling #{method.name}:#{method.id} with arguments #{arguments}" }
		    begin
			result = method.call(self)
		    rescue PlanModelError, Interrupt
			raise
		    rescue Exception => e
			raise PlanModelError.new(self), e.message, e.backtrace
		    end

                    if result && result.respond_to?(:as_plan)
                        result = result.as_plan
                    end

		    # Check that result is a task or a task collection
		    unless result && (result.respond_to?(:to_task) || result.respond_to?(:each) || !result.respond_to?(:each_task))
			raise PlanModelError.new(self), "#{method} returned #{result}, which is neither a task nor a task collection"
		    end
		    
		    # Insert resulting tasks in +plan+
		    plan.add(result)

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
                    @arguments.pop
                    @stack.pop
                end

            rescue PlanModelError => e
                e.planner = self unless e.planner
                errors[method] = e
                if methods.empty?
                    raise NotFound.new(self, errors)
                else
                    call_planning_methods(errors, method_options, *methods)
                end
            end

            private :call_planning_methods

	    # Builds a loop in a plan (i.e. a method which is generated in
	    # loop)
	    def make_loop(options = {}, &block)
		raise ArgumentError, "no block given" unless block

                loop_id = Planner.next_id
                if !@stack.empty?
                    loop_id = "#{@stack.last[1]}_#{loop_id}"
                end
                loop_method = FreeMethod.new 'loops', {}, lambda(&block)

                options[:planner_model] = model
                options[:planning_method] = loop_method
		_, planning_options = PlanningLoop.filter_options(options)
                planning_options[:id] = loop_id
                planning_options[:reuse] = false
                loop_method.options.merge!(planning_options)

		options[:method_options] ||= {}
		options[:method_options].merge!(arguments || {})
		options[:method_options][:id] = loop_method.id
		PlanningLoop.new(options)
	    end

            def self.find_all_actions_by_type(model)
                all = []
                planning_methods_names.each do |method_name|
                    if result = find_methods(method_name, :returns => model)
                        all.concat(result)
                    end
                end
                all
            end

            def self.find_action_by_name(name)
                if has_method?(name)
                    model_of(name, Hash.new)
                end
            end

            # Added to honor a common API with Actions::Interface
            def self.each_action
                planning_methods
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

