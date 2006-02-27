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

        class NotFound < PlanModelError
            attr_reader :errors
            attr_accessor :method_name, :method_options
            def initialize(planner, errors)
                @errors = errors
                super(planner)
            end

            def to_s
                "cannot find a #{method_name}(#{method_options}) method\n" + 
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
                        if options[:returns]
                            # Check that overloading is possible
                            if !(rettype < options[:returns])
                                raise ArgumentError, "cannot overload a method model with a return type not subclass of the parent model: #{rettype} is not a subclass of #{options[:returns]}"
                            end
                        end
                        options[:returns] = rettype
                    }
                end
                        
                def freeze!
                    options.freeze! 
                    super
                end
                def initialize_copy(from)
                    @name    = from.name.dup
                    @options = from.options.dup
                end

                def to_s; "#{name}(#{options.inspect})" end
            end

            class_inherited_enumerable(:method, :methods, :map => true) { Hash.new }

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

            class_inherited_enumerable(:method_model, :method_models, :map => true) { Hash.new }

            def self.method_model(name, readonly = true)
                name = name.to_s
                
                model = enum_for(:each_method_model, name, readonly).find { true }
                if !readonly
                    if model # the model is defined at this inheritance level
                        if model.frozen?
                            raise ArgumentError, "cannot change a method model if it already overloaded or used by a method definition"
                        else
                            return model
                        end
                    elsif model = enum_for(:each_method_model, name).find { true } # try to get a model from our ancestors
                        method_models[name] = model.freeze.dup if model
                    end
                end

                method_models[name] ||= MethodModel.new(name)
                if readonly
                    method_models[name].freeze
                else
                    method_models[name]
                end
            end

            class << self
                attribute(:last_id => 0)
                def next_id; self.last_id += 1 end
            end

            def self.method(name, options = Hash.new, &body)
                name, options = validate_method_query(name, options)

                if !body # update the method model
                    method_model(name, false).merge options
                    return
                end
                
                # Update the last_id attribute if options[id] is an integer
                if options[:id].respond_to?(:to_int)
                    method_id = options[:id].to_int
                    self.last_id = method_id if self.last_id < method_id
                else
                    method_id = (options[:id] ||= next_id)
                end

                if model = method_model(name, true)
                    unless options = model.validate(options)
                        raise ArgumentError, "#{name}:#{method_id}(#{options.inspect}) does not match the model #{model}"
                    end
                end

                if old_method = find_methods(name, :id => options[:id])
                    old_method = *old_method
                    unless old_method.validate(options)
                        raise ArgumentError, "#{name}:#{method_id}(#{options.inspect}) cannot overload #{old_method.inspect}"
                    end
                    Planning.debug { "overloading #{name}:#{method_id}" } 
                end
                methods[name] ||= Hash.new
                methods[name][method_id] = MethodDefinition.new(name, options, &body)
            end

            def self.find_methods(method_name, options = Hash.new)
                method_name, method_selection, other_options = validate_method_query(method_name, options, [:lazy])

                seen = Set.new
                result = enum_for(:each_method, method_name).collect do |methods| 
                    methods.collect do |id, m| 
                        next if seen.include?(id)
                        seen << m.id
                        if m.name == method_name && m.options.merge(method_selection) == m.options 
                            m
                        end
                    end
                end
                result.flatten!
                result.compact!

                if result.empty?
                    nil
                else
                    result
                end
            end

            def respond_to?(name); super || has_method?(name.to_s) end
            def has_method?(name); self.class.has_method?(name.to_s) end

            def method_missing(method_name, *args)
                method_name = method_name.to_s
                if has_method?(method_name)
                    options = *args

                    plan(method_name, options || Hash.new)
                else
                    super
                end
            
            end

            # Find a suitable development for the +name+ method.
            # +options+ is used for method selection, see find_methods
            def plan(name, options = Hash.new)
                name    = name.to_s

                if @stack.include?(name)
                    options[:recursive] = true
                    options[:lazy] = true
                end

                m = self.class.find_methods(name, options)
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
    end
end

