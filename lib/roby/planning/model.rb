require 'roby/planning/task'
require 'roby/task'
require 'roby/event_loop'
require 'roby/plan'
require 'set'

module Roby
    module Planning
        # Violation of the plan model
        class PlanModelError < RuntimeError
            attr_accessor :planner
            def initialize(planner = nil)
                @planner = planner 
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
	# See Planner::method for more information on how methods are handled
	#
        class Planner
	    attr_reader :result
            def initialize(result = Plan.new)
		@result	  = result
                @stack    = Array.new
            end

	    def clear
		@result = Plan.new
		self
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

            class MethodDefinition
                include MethodInheritance

                attr_reader :name, :options, :body
                def initialize(name, options, &body)
                    @name, @options, @body = name, options, body
                end

                def id;         options[:id] end
                def recursive?; options[:recursive] end
                def returns;    options[:returns] end
		def reuse;	options[:reuse] end
                def call;       body.call end

                def to_s; "#{name}:#{id}(#{options.inspect})" end
            end

            class MethodModel
                include MethodInheritance

                attr_reader :name, :options
                def initialize(name, options = Hash.new); @name, @options = name, options end
                def returns;    options[:returns] end
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
                end
                        
                def freeze
                    options.freeze
                    super
                end
                def initialize_copy(from)
                    @name    = from.name.dup
                    @options = from.options.dup
                end

                def to_s; "#{name}(#{options.inspect})" end
            end

            def self.validate_method_query(name, options, other_options = [])
                name = name.to_s

                validate_option(options, :returns, false, 
                                "the ':returns' option must be a subclass of Roby::Task") do |opt| 
                    options[:returns] < Roby::Task
                end

                options = validate_options(options, [:id, :recursive, :returns, :reuse] + other_options)
                other_options, method_options = options.partition { |n, v| other_options.include?(n) }

                [name, Hash[*method_options.flatten], Hash[*other_options.flatten]]
            end

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
	    #   an integer represented as a string is converted to integer form
	    #   a symbol is converted to string
	    def self.validate_method_id(method_id)
		method_id = method_id.to_s if Symbol === method_id

		if method_id.respond_to?(:to_str) && method_id.to_str =~ /^\d+$/
		    Integer(method_id)
		else
		    method_id
		end
	    end

	    # Creates, overloads or updates a method model
	    def self.update_method_model(name, options)
		name = name.to_s
		if respond_to?("#{name}_methods")
		    raise ArgumentError, "cannot change the method model for #{name} since methods are already using it"
		elsif respond_to?("#{name}_model")
		    send("#{name}_model").merge options
		else
		    singleton_class.class_eval <<-EOD
			def #{name}_model
			    @#{name}_model || superclass.#{name}_model
			end
		    EOD
		    new_model = MethodModel.new(name)
		    new_model.merge(options)
		    instance_variable_set("@#{name}_model", new_model)
		end
	    end

	    # call-seq:
	    #	method(name, option1 => value1, option2 => value2) { }	    => self
	    #	method(name, option1 => value1, option2 => value2)
	    #
	    # In the first form, define a new method +name+. The given block
	    # is used as method definition. It shall either return a Task
	    # object or an object whose #each method yields task objects, or
	    # raise a NotFound exception, or one of its subclasses.
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
	    # == Constraining the return model
	    # The +returns+ option can be used to constrain the kind of returned
	    # task a given method can return. When a constraint is given, it is
	    # defined for all task overloading the one defining constraints
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
	    # If the +reuse+ flag is set (the default), call to methods that define a 
	    # +returns+ can lead to reusing an already planned task
	    #
	    def self.method(name, options = Hash.new, &body)
                name, options = validate_method_query(name, options)

		# We are updating the method model
                if !body
                    update_method_model(name, options)
                    return
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
			plan("#{name}", options)
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

	    def self.each_method(name, id, &iterator)
		send("each_#{name}_method", id, &iterator)
	    end

            def self.find_methods(name, options = Hash.new)
                name, method_selection, other_options = validate_method_query(name, options, [:lazy, :reuse])

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

		if result.nil? || result.empty?
		    nil
		else
		    result
		end
            end

            def has_method?(name); singleton_class.respond_to?("#{name}_methods") end

            # Find a suitable development for the +name+ method.
            # +options+ is used for method selection, see find_methods
            def plan(name, options = Hash.new)
                name    = name.to_s

                if @stack.include?(name)
                    options[:recursive] = true
                    options[:lazy] = true
                end

                m = singleton_class.find_methods(name, options)
                if !m
                    raise NotFound.new(self, Hash.new)
                elsif options[:lazy]
                    task = PlanningTask.new(self.class, name, options)
		    self.result << task
		    return task
		end
		
		# Check if we can reuse a task in #result
		m.each do |method|
		    if method.returns && method.reuse
			task = self.result.enum_for(:each_task).find do |task|
			    task.fullfills?(method.returns, options[:arguments])
			end
			if task
			    self.result << task
			    return task
			end
		    end
		end

		if result = plan_method(Hash.new, options, *m)
		    if result.respond_to?(:each_task)
			result.each_task { |t| self.result << t }
		    elsif result.respond_to?(:to_task)
			self.result << result.to_task
		    elsif result.respond_to?(:each)
			result.each { |t| self.result << t }
		    else
			raise PlanModelError, "#{name}(#{options}) did not return a Task object"
		    end
		    result
		end

            rescue NotFound => e
                e.method_name       = name
                e.method_options    = options
                raise e
            end

            # Develops each method in turn, running the next one if 
            # the previous one was unsuccessful
            #
            # It raises NotFound if no successful development has been found
            def plan_method(errors, options, method, *methods)
                begin
                    @stack.push method.name
                    result = (instance_eval(&method.body) || NullTask.new)

		    if method.returns && !result.fullfills?(method.returns, options[:arguments])
			raise PlanModelError, "#{method} returned #{result}, but a #{method.returns} object was expected"
		    end
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
                    plan_method(errors, options, *methods)
                end
            end

            private :plan_method
        end

	# A planning Library is only a way to gather a set of planning
	# methods. It is created by
	#   module MyLibrary
	#      extend Roby::Planning::Library
	#      method(:bla) do
	#      end
	#   end
	# or 
	#   my_library = Roby::Planning::Library.new do
	#       method(:bla) do end
	#   end
	#
	# It is then used by simply including the library in another library
	# or in a Planner class (you don't have to use "extend Roby::Planning::Library"
	# since you already include a library)
	# 
	#	module AnotherLibrary
	#	    include MyLibrary
	#	end
	#
	#	class MyPlanner < Planner
	#	    include AnotherLibrary
	#	end
	#
	module Library
	    def planning_methods; @methods ||= Array.new end
	    def method(name, options = Hash.new, &body)
		planning_methods << [name, options, body]
	    end

	    def included(klass)
		super
		return unless klass < Planner

		# Define all library methods, beggining with the first included module (last
		# in the ancestors array)
		ancestors.enum_for(:reverse_each).
		    find_all { |mod| mod.respond_to?(:planning_methods) }.
		    each { |mod| mod.planning_methods.each { |name, options, body| klass.method(name, options, &body) } }
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

