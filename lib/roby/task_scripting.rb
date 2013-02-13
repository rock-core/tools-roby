module Roby
    # Implementation module for the task scripting capabilities. See
    # TaskScripting::Script for details
    module TaskScripting
        extend Logger::Forward
        extend Logger::Hierarchy

        # Implementation of the logic that executes scripts. Scripts are defined
        # using the Script class.
        class ScriptEngine
            # The scripting execution blocks
            attr_reader :elements
            # The logger that should be used. It is Roby::TaskScripting by
            # default
            attr_reader :logger
            # Set of Script objects bound to this engine
            attr_reader :scripts

            # The task that holds this scripting engine 
            def __task__
                @task
            end

            def initialize
                @elements = []
                @logger = Roby::TaskScripting
                @scripts = []
            end

            def initialize_copy(original)
                super

                @scripts = []
                @elements = []
                original.scripts.each do |s|
                    self.load(&s.definition_block)
                end
            end

            # Changes the logger
            def setup_logger(logger)
                @logger = logger
            end

            include Logger::Forward

            # Called at the very beginning of the task execution. It can be used
            # by execution blocks to resolve some of the necessary information
            # (children, ...)
            def prepare(task)
                @task = task
                super if defined? super

                @elements.map do |el|
                    el.prepare(task)
                end
            end

            attr_accessor :time_barrier

            def validate_event_request(event_spec)
                if event_spec.respond_to?(:resolve)
                    event_spec.bind(@task)
                else
                    @task.event(event_spec)
                end
            end

            def resolve_event_request(event_spec)
                if event_spec.respond_to?(:resolve)
                    event_spec.resolve(@task)
                else
                    @task.event(event_spec)
                end
            end

            def execute
                while !@elements.empty?
                    top = @elements.first

                    block_finished = catch(:retry_block) do
                        top.execute
                    end
                    if !block_finished
                        if @last_description != top.description
                            info "executing #{top}"
                        end
                        @last_description = top.description
                        return
                    end

                    top = @elements.shift
                    info "executed #{top}"
                end
                return true
            end

            def load(&block)
                loader = Script.new(self)
                @scripts << loader
                loader.load(&block)
            end

            def script_extensions(name, *args, &block)
                if defined? super
                    super
                else
                    throw :no_match
                end
            end

            def method_missing(m, *args, &block)
                if !@task
                    return super 
                end

                catch(:no_match) do
                    return script_extensions(m, *args, &block)
                end
                @task.send(m, *args, &block)
            end
        end

        # Proxy object returned by the *_event methods to allow access to child
        # events
        class Event
            def initialize(child, event_name)
                @child, @event_name = child, event_name
            end

            def bind(task)
                @child.bind(task)
            end

            # Returns the specified event when applied on +task+
            def resolve(task)
                child_task = @child.resolve(task)
                child_task.event(@event_name)
            end

            def to_s
                @child.to_s + ".#{@event_name}_event"
            end
        end

        # Proxy object returned by the *_child methods to allow access to task
        # children
        class Child
            def initialize(chain)
                @chain = chain
            end

            def bind(task)
                @task = task
            end

            def method_missing(m, *args, &block)
                if args.empty? && !block
                    case m.to_s
                    when /^(\w+)_child$/
                        return Child.new(@chain.dup << $1)
                    when /^(\w+)_event$/
                        return Event.new(self, $1)
                    end
                end

                if @task
                    catch(:retry_block) do
                        return resolve(@task).send(m, *args, &block)
                    end
                    raise NoMethodError, "child #{@chain.join(".")} does not yet exist on #{@task}"
                else
                    raise NoMethodError, "you cannot use this object outside scripting, you probably forgot to put code in an execute { } or poll { } block."
                end
            end

            # Returns the specified child when applied on +task+
            def resolve(task)
                @chain.inject(task) do |child, role|
                    if !(next_child = child.find_child_from_role(role))
                        if child.abstract? && child.planning_task && !child.planning_task.finished?
                            throw :retry_block
                        end
                    end
                    next_child
                end
            end

            def to_s
                @chain.map { |name| "#{name}_child" }.join(".")
            end
        end

        # Exception thrown by Script#timeout when the timeout is reached
        class Timeout < RuntimeError; end

        # The main interface to scripting
        #
        # The commands that are available to task scripts are instance methods
        # on this object. Each command can "block" the script until a specified
        # condition (e.g. #wait can wait for a certain number of seconds). Once
        # that command's end condition is reached, the next one is activated and
        # so on.
        #
        # Nothing special happens if the script reaches its end. If you want
        # that, for instance, the :success event is emitted, simply do
        #
        #   emit :sucess
        #
        # Commands that require events can have this event specified in the
        # following manner:
        #
        # * as a symbol (the event name), in which case it refers to an event of
        #   the task that will hold the script
        # * as an object accessed with the <eventname>_event pattern (i.e.
        #   success_event is equivalent to success)
        # * as an event of one of the task's children. The child is accessed
        #   with the <childname>_child methods and the event with
        #   <eventname>_event. For instance:
        #   
        #     wait(localization_child.start_event)
        #
        #   will wait for the start event of the localization child to be
        #   emitted. The child must be added with the 'localization' role when
        #   building the plan
        #
        #     root_task.depends_on(localization_task, :role => 'localization')
        #
        class Script
            # The ScriptEngine instance that is going to execute this script
            attr_reader :script_engine

            # The block that has been used to define this script
            attr_reader :definition_block

            def initialize(script_engine)
                @script_engine = script_engine
            end

            def rebind(script_engine)
                @script_engine = script_engine
            end

            def load(&block)
                @definition_block = block
                instance_eval(&block)
            end

            # Use +logger+ as the script logger object. It can be any object
            # that responds to the normal debug methods #debug, #info, #warn and #fatal
            def setup_logger(logger)
                script_engine.setup_logger(logger)
            end

            # Execute the given block until it calls transition!
            def poll(&block)
                script_engine.elements << Poll.new(script_engine, &block)
            end

            # Describe the next operation. It is mainly used in script debugging
            # to track what is happening. For instance:
            #
            #   describe "wait for the position to reach a threshold"
            #   poll do
            #     if State.position.x > 10
            #       transition!
            #     end
            #   end
            #
            def describe(description)
                @next_description = description
            end

            # Call the provided block and process the definitions there, using
            # +fallback_description+ as the blocks' descriptions if they don't
            # provide one themselves.
            def with_description(fallback_description)
                element_size = script_engine.elements.size
                yield

            ensure
                script_engine.elements[element_size..-1].each do |el|
                    el.description = @next_description || fallback_description
                end
                @next_description = nil
            end

            # Execute the block once at this point in the script
            def execute(&block)
                script_engine.elements << Execute.new(script_engine, &block)
            end
            
            # Execute the block once at this point in the script
            def prepare(&block)
                script_engine.elements << Prepare.new(script_engine, &block)
            end
            
            # call-seq:
            #   timeout 0.5
            #   timeout 0.5, :emit => :failed
            #
            # Execute the given block, but raise a Timeout exception if its
            # execution takes more than +duration+ seconds (as a numerical
            # value)
            #
            # Alternatively, if the :emit option is given, the specified event
            # will be emitted instead of having an exception raised. The event
            # should be terminal
            def timeout(duration, options = Hash.new, &block)
                options = Kernel.validate_options options, :emit => nil

                subscript = ScriptEngine.new
                subscript.load(&block)

                start_time = nil
                script_engine = self.script_engine
                execute do
                    start_time = Time.now
                    subscript.prepare(script_engine.__task__)
                end
                poll do
                    if subscript.execute
                        transition!
                    elsif Time.now - start_time > duration
                        if options[:emit]
                            emit options[:emit]
                        else
                            raise Timeout, "timed out at #{block}"
                        end
                    end
                end
            end

            # call-seq:
            #   poll_until localization_child.ready_event
            #
            # Execute the given block at each execution cycle until +event_spec+
            # happens.
            #
            def poll_until(event_spec, options = Hash.new, &block)
                options = Kernel.validate_options options, :after => nil

                with_description "PollUntil(#{event_spec}): #{caller(1).first}" do
                    done = false
                    prepare do
                        validate_event_request(event_spec)
                    end
                    execute do
                        event = resolve_event_request(event_spec)
                        if !options.has_key?(:after)
                            options[:after] = self.time_barrier
                        end

                        if options[:after]
                            if event.happened? && event.last.time > options[:after]
                                done = true
                                self.time_barrier = event.last.time
                            end
                        end
                        event.on { |_| done = true }
                    end

                    poll do
                        main(&block)
                        end_if { done }
                    end
                end
            end

            # Wait for the specified event to be emitted. It will return
            # immediately if the event already got emitted in the past.
            #
            # Use #wait to wait for a new emission
            def wait_any(event_spec)
                with_description "WaitAny(#{event_spec}): #{caller(1).first}" do
                    prepare do
                        validate_event_request(event_spec)
                    end
                    poll do
                        event = resolve_event_request(event_spec)
                        if event.happened?
                            self.time_barrier = event.last.time
                            transition!
                        end
                    end
                end
            end

            # Given an event, will wait for the specified event to be emitted.
            # It will return only for new emissions of the event
            #
            # Use #wait_any if you want to make sure that the event got emitted
            # at least once
            def wait(event_spec_or_time, options = Hash.new)
                options = Kernel.validate_options options, :after => nil

                if event_spec_or_time.kind_of?(Numeric)
                    Roby.warn_deprecated "wait(time_in_seconds) is deprecated in task scripting. Use sleep(time_in_seconds) instead"
                    sleep(event_spec_or_time)
                else
                    with_description "Wait(#{event_spec_or_time}): #{caller(1).first}" do
                        poll_until(event_spec_or_time, options) { }
                    end
                end
            end

            # Wait that many seconds before continuing to the next 
            def sleep(time)
                time = Float(time)
                with_description "Sleep(#{time}): : #{caller(1).first}" do
                    start_time = nil
                    execute { start_time = Time.now }
                    poll do
                        main { }
                        end_if { (Time.now - start_time) > time }
                    end
                end
            end

            # Emit the specified event
            def emit(event_spec)
                with_description "Emit(#{event_spec}): #{caller(1).first}" do
                    prepare do
                        validate_event_request(event_spec)
                    end
                    execute do
                        event = resolve_event_request(event_spec)
                        event.emit
                    end
                end
            end

            @@child_count = 0

            # Adds the specified task or action as a child of this task, and
            # start it at this point in the script. The script will continue its
            # execution only when the task is actually started
            #
            # The option hash is passed to #depends_on. See the documentation
            # for the dependency relation for more information. Note that if a
            # role is not explicitely given to this child, it will get an
            # automatically generated one
            #
            # The child can be specified in the following manner(s):
            #
            # * as a string or symbol terminating with an exclamation mark. The
            #   argument is interpreted as a planning method that will be called
            #   right away to generate the child
            # * as a task model. In this case, the #as_plan method gets called
            #   on it to generate a child. The default Task#as_plan method
            #   looks for a planning method that returns a task of that type and
            #   returns it.
            # * as a task instance, which is simply used.
            def start(child, options = Hash.new)
                options, planning_args = Kernel.filter_options options, Roby::TaskStructure::DEPENDENCY_RELATION_ARGUMENTS
                if options[:roles]
                    role_id = options[:roles].to_a.first
                elsif options[:role]
                    role_id = options[:role]
                else
                    role_id = options[:role] = "child#{@@child_count += 1}"
                end

                trigger_event = nil
                prepare do
                    if child.respond_to?(:to_sym) || child.respond_to?(:to_str)
                        child, _ = Robot.prepare_action(nil, child, planning_args)
                    end

                    child = depends_on(child, options)

                    trigger_event = Roby::EventGenerator.new(true)
                    child.should_start_after trigger_event
                end

                child_proxy = Child.new([role_id])
                execute { trigger_event.emit }
                wait(Event.new(child_proxy, :start))
                child_proxy
            end

            # Implementation of the *_child and *_event handlers
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
        
        # Base class for all execution blocks
        #
        # Subclasses must define an #execute method. This method should return
        # false if the block needs to be called again at the next execution cycle,
        # and false otherwise
        class Base
            # Backtrace of the block's creation location
            attr_reader :defined_at
            # Description of this block's purpose
            attr_accessor :description
            # The underlying task
            def task; @script_engine.__task__ end

            def initialize(script_engine, &block)
                @script_engine = script_engine
                if block
                    @defined_at = caller
                    @definition = Module.new do
                        define_method(:do_execute, &block)
                    end
                    extend @definition
                    @description = "#{self.class.name}: #{@defined_at.first}"
                end
            end

            def initialize_copy(original)
                super

                extend @definition
            end

            def method_missing(m, *args, &block)
                if m == :execute || !@script_engine
                    super
                end
                @script_engine.send(m, *args, &block)
            end

            def prepare(task)
            end

            def to_s
                description
            end
        end

        # Implementation of Script#execute
        class Prepare < Base
            def prepare(task)
                do_execute
            end

            def execute
                true
            end
        end

        # Implementation of Script#execute
        class Execute < Base
            def execute
                do_execute
                true
            end
        end

        # Implementation of polling capabilities
        #
        # It is used to implement most of the waiting and polling blocks
        class Poll < Base
            attr_reader :end_conditions
            
            def initialize(script_engine, &block)
                super
                @end_conditions = Hash.new
            end

            def main(&block)
                instance_eval(&block)
            end

            # Sets a termination condition. #execute will return as soon as
            # +any+ of the termination conditions reutrn true
            def end_if(&block)
                call_site = caller(1)[5]
                cond = end_conditions[call_site]
                if !cond
                    cond = [block, PollEndCondition.new(@script_engine, &block)]
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

            # Requires the poll block to finish
            def transition!
                throw :transition_required, true
            end

            # Called when this poll block is active. See the documentation of
            # the Base class
            def execute
                transition = catch(:transition_required) do
                    do_execute
                    nil
                end
                return transition
            end
        end

        # Holder for end conditions in Poll
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
        class << self
            define_inherited_enumerable(:script, :scripts) { Array.new }
        end

        # Adds a script that is going to be executed for every instance of this
        # task model
        def self.script(&block)
            script = TaskScripting::ScriptEngine.new
            script.load(&block)
            scripts << script
        end

        on :start do |event|
            scripts = model.each_script.map do |s|
                s = s.dup
                s.prepare(self)
                s
            end

            if !scripts.empty?
                for s in scripts
                    s.execute
                end

                poll do |task|
                    for s in scripts
                        s.execute
                    end
                end
            end
        end

        # Adds a task script that is going to be executed while this task
        # instance runs.
        def script(options = Hash.new, &block)
            script = TaskScripting::ScriptEngine.new
            script.load(&block)
            execute(options) do |task|
                script.prepare(task)
            end
            poll(options) do |task|
                script.execute
            end
            script
        end
    end
end



