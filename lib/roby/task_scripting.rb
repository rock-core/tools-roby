module Roby
    module TaskScripting
        class Script
            attr_reader :elements
            attr_reader :queue

            def initialize
                @elements = []
            end

            def initialize_copy(original)
                @elements = original.dup
            end

            def prepare(task)
                @task = task
                @elements.map do |el|
                    el.prepare(task)
                end
            end

            def resolve_event_request(event_spec)
                event =
                    if event_spec.kind_of?(Event)
                        event_spec.resolve(@task)
                    else
                        @task.event(event_spec)
                    end
            end

            def execute
                while !@elements.empty?
                    top = @elements.first
                    return if !top.execute
                    @elements.shift
                end
            end

            def load(&block)
                loader = DSLLoader.new(self)
                loader.load(&block)
            end

            def method_missing(*args, &block)
                @task.send(*args, &block)
            end
        end

        class Event
            def initialize(chain, event_name)
                @chain, @event_name = chain, event_name
            end

            def resolve(task)
                task = task.resolve_role_path(@chain)
                task.event(@event_name)
            end

            def to_s
                @chain.map { |name| "#{name}_child" }.join(".") + ".#{@event_name}_event"
            end
        end

        class Child
            def initialize(chain)
                @chain = chain
            end

            def method_missing(m, *args, &block)
                if args.empty? && !block
                    case m.to_s
                    when /^(\w+)_child$/
                        return Child.new(@chain.dup << $1)
                    when /^(\w+)_event$/
                        return Event.new(@chain, $1)
                    end
                end
                super
            end

            def resolve(task)
                task.resolve_role_path(@chain)
            end

            def to_s
                @chain.map { |name| "#{name}_child" }.join(".")
            end
        end


        class DSLLoader
            attr_reader :script

            def initialize(script)
                @script = script
            end

            def load(&block)
                instance_eval(&block)
            end

            def poll(&block)
                script.elements << Poll.new(script, &block)
            end

            def poll_end_if(options = Hash.new, &block)
                el = script.elements.last
                if !el || !el.kind_of?(Poll)
                    raise ArgumentError, "a poll_end_if statement must follow a poll statement"
                end

                el.end_condition = PollEndCondition.new(script, options, &block)
            end

            def with_description(description)
                element_size = script.elements.size
                yield
            ensure
                script.elements[element_size..-1].each do |el|
                    el.description = description
                end
            end

            def execute(&block)
                script.elements << Execute.new(script, &block)
            end

            def poll_until(event_spec, &block)
                with_description "PollUntil(#{event_spec}): #{caller(1).first}" do
                    done = false
                    execute do
                        event = resolve_event_request(event_spec)
                        event.on { |_| done = true }
                    end
                    poll(&block)
                    poll_end_if { done }
                end
            end

            def wait(event_spec)
                with_description "Wait(#{event_spec}): #{caller(1).first}" do
                    poll_until(event_spec) { }
                end
            end

            def emit(event_spec)
                with_description "Emit(#{event_spec}): #{caller(1).first}" do
                    execute do
                        event = resolve_event_request(event_spec)
                        event.emit
                    end
                end
            end

            def method_missing(m, *args, &block)
                if args.empty? && !block
                    case m.to_s
                    when /^(\w+)_child$/
                        child_name = $1
                        return Child.new([child_name])
                    when /^(\w+)_event$/
                        return $1
                    end
                end
                super
            end
        end
        
        class Base
            attr_accessor :description

            def initialize(script, &block)
                @script = script
                if block
                    @defined_at = caller(3).first
                    singleton_class.class_eval do
                        define_method(:do_execute, &block)
                    end
                    @description = "#{self.class.name}: #{@defined_at}"
                end
            end

            def initialize_copy(original)
                singleton_class.class_eval do
                    define_method(:do_execute, &original.method(:do_execute))
                end
            end

            def method_missing(m, *args, &block)
                if m == :execute || !@script
                    super
                end
                @script.send(m, *args, &block)
            end

            def prepare(task)
            end

            def to_s
                description
            end
        end

        class Execute < Base
            def execute
                do_execute
                true
            end
        end

        class Poll < Base
            attr_accessor :end_condition
            
            def check_end_condition(called_before)
                return false if !end_condition
                return false if end_condition.execute_before? ^ called_before

                new_condition = end_condition.execute
                if new_condition.respond_to?(:execute) # there is a delay
                    end_condition = new_condition
                    false
                elsif new_condition
                    true
                else
                    false
                end
            end

            def execute
                if check_end_condition(true)
                    return true
                end

                transition = catch(:transition_required) do
                    do_execute
                    nil
                end
                if transition
                    return true
                end
                check_end_condition(false)
            end
        end

        class PollEndCondition < Base
            attr_predicate :execute_before?

            def initialize(script, options, &block)
                super(script, &block)
                options = Kernel.validate_options options, :before => false
                @execute_before = options[:before]
            end

            def wait(timeout)
                @wait_start = Time.now
                @timeout = timeout
                throw :new_end_condition, self
            end

            def execute
                if @wait_start
                    return (Time.now - @wait_start) > @timeout
                else
                    catch(:new_end_condition) { do_execute }
                end
            end
        end
    end

    class Task
        inherited_enumerable(:script, :scripts) { Array.new }

        def self.script(&block)
            script = TaskScripting::Script.new
            script.load(&block)
            scripts << script
        end

        on :start do |event|
            scripts = model.each_script.map do |s|
                s = s.dup
                s.prepare(self)
                s
            end

            poll do
                for s in scripts
                    s.execute
                end
            end
        end

        def script(&block)
            script = TaskScripting::Script.new
            script.load(&block)
            if running?
                script.prepare(self)
            else
                on(:start) do |event|
                    script.prepare(event.task)
                end
            end
            poll do
                script.execute
            end
        end
    end
end



