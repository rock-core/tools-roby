require 'roby/planning/task'
require 'roby/task'
require 'roby/event_loop'

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

            class MethodDefinition
                attr_accessor :name, :options, :body
                def initialize(name, options, &body)
                    @name, @options, @body = name, options, body
                end

                def id;         options[:id] end
                def recursive?; options[:recursive] end
                def call;       body.call end

                def to_s; "#{name}:#{id}" end
            end

            @@method_id = 0
            def self.new_id; (@@method_id += 1).to_s end

            class_inherited_enumerable(:method, :methods, :map => true) { Hash.new }

            def self.validate_method_query(name, options, other_options = [])
                name = name.to_s
                options[:id] = options[:id].to_s if options[:id]
                options = validate_options(options, [:id, :recursive] + other_options)

                other_options, method_options = options.partition { |n, v| other_options.include?(n) }

                [name, Hash[*method_options.flatten], Hash[*other_options.flatten]]
            end

            def self.method(name, options = Hash.new, &body)
                name, options = validate_method_query(name, options)
                id = (options[:id] ||= Planner.new_id)

                methods[name] ||= Hash.new
                debug { "overwriting #{name}:#{method_id}" } if methods[name][id]
                methods[name][id] = MethodDefinition.new(name, options, &body)
            end

            def find_methods(method_name, options = Hash.new)
                method_name, method_selection, other_options = self.class.validate_method_query(method_name, options, [:lazy])

                result = self.class.enum_for(:each_method, method_name).collect do |methods| 
                    methods.collect do |_, m| 
                        if m.name == method_name && m.options.merge(method_selection) == m.options 
                            m
                        end
                    end
                end
                result.flatten!
                result.compact!
                result
            end

            def respond_to?(name); super || has_method?(name.to_s) end
            def has_method?(name); self.class.has_method?(name.to_s) end
            def method_missing(method_name, *args)
                method_name = method_name.to_s
                if has_method?(method_name)
                    m = find_methods(method_name)
                    options = *args
                    options ||= {}
                    if options[:lazy]
                        PlanningTask.new(self.class, method_name, options)
                    else
                        plan(Hash.new, *m)
                    end
                else
                    super
                end
            
            rescue NotFound => e
                e.method_name       = method_name
                e.method_options    = options
                raise e
            end

            # Chooses one of these methods 
            def plan(errors, method, *methods)
                if @stack.include?(method.name)
                    if !method.recursive?
                        raise PlanModelError.new(self), "#{method} method called recursively, but the :recursive option was not set"
                    else
                        return PlanningTask.new(self.class, method)
                    end
                end

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

            private :plan
        end
    end
end

