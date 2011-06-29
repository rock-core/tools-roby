module Roby
    module TaskScripting
        extend Logger::Forward
        extend Logger::Hierarchy

        class Script
            attr_reader :elements

            attr_reader :logger

            def initialize
                @elements = []
                @logger = Roby::TaskScripting
            end

            def initialize_copy(original)
                super

                @elements = original.dup
            end

            def setup_logger(logger)
                @logger = logger
            end

            include Logger::Forward

            def prepare(task)
                super if defined? super

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
                    top = @elements.shift
                    info "executing #{top}"
                end
            end

            def load(&block)
                loader = DSLLoader.new(self)
                loader.load(&block)
            end

            def script_extensions(name, *args, &block)
                super if defined? super
            end

            def method_missing(m, *args, &block)
                return super if !@task

                catch(:no_match) do
                    return script_extensions(m, *args, &block)
                end
                @task.send(m, *args, &block)
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

            def setup_logger(logger)
                script.setup_logger(logger)
            end

            def poll(&block)
                script.elements << Poll.new(script, &block)
            end

            def describe(description)
                @next_description = description
            end

            def with_description(fallback_description)
                element_size = script.elements.size
                yield

            ensure
                script.elements[element_size..-1].each do |el|
                    el.description = @next_description || fallback_description
                end
                @next_description = nil
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
                    poll do
                        main(&block)
                        end_if { done }
                    end
                end
            end

            def wait(event_spec_or_time)
                if event_spec_or_time.kind_of?(Numeric)
                    with_description "Wait(#{event_spec_or_time}): : #{caller(1).first}" do
                        start_time = nil
                        execute { start_time = Time.now }
                        poll do
                            main { }
                            end_if { (Time.now - start_time) > event_spec_or_time }
                        end
                    end
                else
                    with_description "Wait(#{event_spec_or_time}): #{caller(1).first}" do
                        poll_until(event_spec_or_time) { }
                    end
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
            attr_reader :end_conditions
            
            def initialize(script, &block)
                super
                @end_conditions = Hash.new
            end

            def main(&block)
                instance_eval(&block)
            end

            def end_if(&block)
                call_site = caller(1)[5]
                cond = end_conditions[call_site]
                if !cond
                    cond = [block, PollEndCondition.new(@script, &block)]
                    end_conditions[call_site] = cond
                end

                new_condition = cond[1].execute
                result = 
                    if new_condition.respond_to?(:execute) # there is a delay
                        cond[1] = new_condition
                        false
                    elsif new_condition
                        true
                    else
                        false
                    end

                if result
                    transition!
                end
            end

            def transition!
                throw :transition_required, true
            end

            def execute
                transition = catch(:transition_required) do
                    do_execute
                    nil
                end
                return transition
            end
        end

        class PollEndCondition < Base
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

            for s in scripts
                s.execute
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
                script.execute
            else
                on(:start) do |event|
                    script.prepare(event.task)
                    script.execute
                end
            end
            poll do
                script.execute
            end
            self
        end
    end
end



