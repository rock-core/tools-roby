# frozen_string_literal: true

require "roby/tasks/timeout"
module Roby
    module Coordination
        module Models
            # The metamodel for all script-based coordination models
            module Script
                extend MetaRuby::Attributes

                class DeadInstruction < Roby::LocalizedError; end

                # Script element that implements {Script#start}
                class Start < Coordination::ScriptInstruction
                    attr_reader :task
                    attr_reader :dependency_options

                    attr_predicate :explicit_start?, true

                    def initialize(task, explicit_start: false, **dependency_options)
                        @explicit_start = explicit_start
                        @task = task
                        @dependency_options = dependency_options
                    end

                    def new(script)
                        Start.new(
                            script.instance_for(task),
                            explicit_start: explicit_start?, **dependency_options
                        )
                    end

                    def execute(script)
                        script.start_task(task, explicit_start: explicit_start?)
                        true
                    end

                    def to_s
                        "start(#{task}, #{dependency_options})"
                    end
                end

                # Script element that implements {Script#wait}
                class Wait < Coordination::ScriptInstruction
                    attr_reader :event

                    # @return [Time,nil] time after which an emission is valid.
                    #   'nil' means that only emissions that have happened after
                    #   the script reached this instruction are considered
                    attr_reader :time_barrier

                    # @return [Float] number of seconds after which the wait
                    #   instruction should generate an error
                    attr_reader :timeout

                    # @return [Boolean] true if {#execute} has been called once
                    attr_predicate :initialized?

                    # @return [Boolean] true if the watched event got emitted
                    attr_predicate :done?

                    # @option options [Float] :timeout (nil) value for {#timeout}
                    # @option options [Time] :after (nil) value for
                    #   {#time_barrier}
                    def initialize(event, after: nil)
                        @event = event
                        @done = false
                        @time_barrier = after
                    end

                    def new(script)
                        Wait.new(script.instance_for(event), after: time_barrier)
                    end

                    def execute(script)
                        event     = self.event.resolve
                        plan      = script.plan
                        root_task = script.root_task

                        if time_barrier
                            last_event = event.history.last
                            if last_event && last_event.time > time_barrier
                                return true
                            end
                        end

                        if event.unreachable?
                            plan.add_error(DeadInstruction.new(script.root_task))
                            return false
                        end

                        if event.task != root_task
                            role_name = "wait_#{self.object_id}"
                            current_roles = (
                                root_task.depends_on?(event.task) &&
                                root_task.roles_of(event.task)
                            )
                            root_task.depends_on(
                                event.task, success: nil, role: role_name
                            )
                        end

                        event.if_unreachable(
                            cancel_at_emission: true
                        ) do |reason, generator|
                            unless disabled?
                                generator.plan.add_error(
                                    DeadInstruction.new(script.root_task)
                                )
                            end
                        end

                        event.on on_replace: :copy do |event|
                            if event.generator == self.event.resolve && !disabled?
                                handle_event(script, role_name, current_roles, event)
                            end
                        end

                        false
                    end

                    # @api private
                    #
                    # Helper to handle events
                    def handle_event(script, role_name, current_roles, event)
                        return if time_barrier && event.time < time_barrier

                        child = role_name &&
                                script.root_task.find_child_from_role(role_name)
                        if child
                            script.root_task.remove_roles(
                                child, role_name,
                                remove_child_when_empty: (
                                    !current_roles || !current_roles.empty?
                                )
                            )
                        end

                        cancel
                        script.step
                    end

                    def waited_task_role
                        "wait_#{object_id}"
                    end

                    def to_s
                        "wait(#{event})"
                    end
                end

                # Script element that implements {Script#emit}
                class Emit < Coordination::ScriptInstruction
                    # @return [Event] the event that should be
                    # emitted
                    attr_reader :event

                    def initialize(event)
                        @event = event
                    end

                    def new(script)
                        Emit.new(script.instance_for(event))
                    end

                    def execute(script)
                        event.resolve.emit
                        true
                    end

                    def to_s
                        "emit(#{event})"
                    end
                end

                class TimeoutStart
                    attr_reader :seconds
                    attr_reader :event

                    def initialize(seconds, options = {})
                        @seconds = seconds
                        options = Kernel.validate_options options, emit: nil
                        @event = options[:emit]
                    end

                    def new(script)
                        event = if self.event
                                    script.instance_for(self.event)
                                end

                        Coordination::TaskScript::TimeoutStart.new(self, event)
                    end
                end

                class TimeoutStop
                    attr_reader :timeout_start

                    def initialize(timeout_start)
                        @timeout_start = timeout_start
                    end

                    def new(script)
                        Coordination::TaskScript::TimeoutStop.new(script.instance_for(timeout_start))
                    end
                end

                inherited_single_value_attribute("__terminal") { false }

                # Marks this script has being terminated, i.e. that no new
                # instructions can be added to it
                #
                # Once this is called, adding new instructions will raise
                # ArgumentError
                def terminal
                    __terminal(true)
                end

                # @return [Boolean] if true, this script cannot get new
                #   instructions (a terminal instruction has been added)
                def terminal?
                    __terminal
                end

                # The list of instructions in this script
                # @return [Array]
                attribute(:instructions) { [] }

                # Starts the given task
                #
                # @param [Task] task the action-task. It must be created by
                #   calling {Base#task} on the relevant object
                # @param [Hash] options the dependency relation options. See
                #   {Roby::TaskStructure::Dependency::Extension#depends_on}
                def start(task, explicit_start: false, **options)
                    task = validate_or_create_task task
                    add Start.new(task, explicit_start: explicit_start, **options)
                    wait(task.start_event)
                end

                # Starts the given task, and waits for it to successfully finish
                #
                # @param [Task] task the action-task. It must be created by
                #   calling {Base#task} on the relevant object
                # @param [Hash] options the dependency relation options. See
                #   {Roby::TaskStructure::Dependency::Extension#depends_on}
                def execute(task, options = {})
                    task = validate_or_create_task task
                    start(task, options)
                    wait(task.success_event)
                end

                # Waits a certain amount of time before continuing
                #
                # @param [Float] time the amount of time to wait, in seconds
                def sleep(time)
                    task = self.task(ActionCoordination::TaskFromAsPlan.new(Tasks::Timeout.with_arguments(delay: time), Tasks::Timeout))
                    start task, explicit_start: true
                    wait task.stop_event
                end

                # Waits until this event gets emitted
                #
                # It will wait even if this event has already been emitted at
                # this point in the script (i.e. waits for a "new" emission)
                #
                # @param [Event] event the event to wait for
                # @param [Hash] options
                # @param [Float] timeout a timeout (for backward
                #   compatibility, use timeout(seconds) do ... end instead)
                def wait(event, timeout: nil, **wait_options)
                    validate_event event

                    wait = Wait.new(event, **wait_options)
                    if timeout
                        timeout(timeout) do
                            add wait
                        end
                    else
                        add wait
                    end
                    wait
                end

                # Emit the given event
                #
                # @param [Event] event
                def emit(event)
                    validate_event event
                    add Emit.new(event)
                end

                # Execute another script at this point in the execution
                def call(script)
                    instructions.concat(script.instructions)
                end

                def timeout_start(delay, options = {})
                    ins = TimeoutStart.new(delay, options)
                    add ins
                    ins
                end

                def timeout_stop(timeout_start)
                    ins = TimeoutStop.new(timeout_start)
                    add ins
                    ins
                end

                def add(instruction)
                    if terminal?
                        raise ArgumentError, "a terminal command has been called on this script, cannot add anything further"
                    end

                    instructions << instruction
                end
            end
        end
    end
end
