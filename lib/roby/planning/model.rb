require 'roby/planning/task'
require 'roby/task'
require 'roby/event_loop'
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

        # A plan model
        class Planner
            def initialize
                @tasks    = Set.new
                @stack    = Array.new
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
                def call;       body.call end

                def to_s; "#{name}:#{id}(#{options.inspect})" end
            end

            class MethodModel
                include MethodInheritance

                attr_reader :name, :options
                def initialize(name, options = Hash.new); @name, @options = name, options end
                def returns;    options[:returns] end
                def merge(new_options)
                    validate_options(new_options, [:returns])
                    validate_option(new_options, :returns, false) { |rettype| 
                        if options[:returns] && options[:returns] != rettype
			    raise ArgumentError, "return type already specified for method #{name}"
                        end
                        options[:returns] = rettype
                    }
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

                options = validate_options(options, [:id, :recursive, :returns] + other_options)
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
	    rescue NoMethodError
	    end

            def self.find_methods(name, options = Hash.new)
                name, method_selection, other_options = validate_method_query(name, options, [:lazy])

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
                    PlanningTask.new(self.class, name, options)
                else
                    plan_method(Hash.new, *m)
                end

            rescue NotFound => e
                e.method_name       = name
                e.method_options    = options
                raise e
            end

            # Develops each method in turn, running the next one if 
            # the previous one was unsuccessful
            #
            # It raises NotFound if no method was suitable
            def plan_method(errors, method, *methods)
                begin
                    @stack.push method.name
                    (instance_eval(&method.body) || NullTask.new)
                ensure
                    @stack.pop
                end

            rescue PlanModelError => e
                e.planner = self unless e.planner
                errors[method] = e
                if methods.empty?
                    raise NotFound.new(self, errors)
                else
                    plan(errors, *methods)
                end
            end

            private :plan_method
        end

	module Library
	    def planning_methods; @methods ||= Array.new end
	    def method(name, options = Hash.new, &body)
		planning_methods << [name, options, body]
	    end

	    def included(klass)
		super
		return unless klass < Planner
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

