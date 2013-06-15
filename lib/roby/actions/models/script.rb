require 'roby/tasks/timeout'
module Roby
    module Actions
        module Models
            # The metamodel for Actions::Script
            module Script
                class DeadInstruction < Roby::LocalizedError; end

                # Script element that implements {Script#start}
                class Start
                    attr_reader :task
                    attr_reader :dependency_options

                    def initialize(task, dependency_options)
                        @task = task
                        @dependency_options = dependency_options
                    end

                    def new(script)
                        Start.new(script.instance_for(task), dependency_options)
                    end

                    def execute(script)
                        script.start_task(task)
                        true
                    end

                    def to_s; "start(#{task}, #{dependency_options})" end
                end

                # Script element that implements {Script#wait}
                class Wait
                    attr_reader :event

                    # @return [Time,nil] time after which an emission is valid.
                    #   'nil' means that only emissions that have happened after
                    #   the script reached this instruction are considered
                    attr_reader :time_barrier

                    # @return [Float] number of seconds after which the wait
                    #   instruction should generate an error
                    attr_reader :timeout

                    # @option options [Float] :timeout (nil) value for {#timeout}
                    # @option options [Time] :after (nil) value for
                    #   {#time_barrier}
                    def initialize(event, options = Hash.new)
                        options = Kernel.validate_options options, :timeout => nil, :after => nil
                        @event = event
                        @time_barrier = options[:after]
                        @timeout = options[:timeout]
                    end

                    def new(script)
                        Wait.new(script.instance_for(event), :timeout => timeout, :after => time_barrier)
                    end

                    def execute(script)
                        event = self.event.resolve

                        if time_barrier
                            if event.history.find { |ev| ev.time > time_barrier }
                                return true
                            end
                        end

                        if event.unreachable?
                            raise DeadInstruction.new(script.root_task), "#{self} is locked: #{event.unreachability_reason}"
                        end
                        event.when_unreachable(true) do |reason, generator|
                            raise DeadInstruction.new(script.root_task), "#{self} is locked: #{reason}"
                        end
                        event.on do |context|
                            script.step
                        end
                        if timeout
                            event.delay(timeout).on do
                                raise DeadInstruction.new(script.root_task), "#{self} timed out"
                            end
                        end

                        false
                    end

                    def to_s; "wait(#{event}, :timeout => #{timeout})" end
                end

                # Script element that implements {Script#emit}
                class Emit
                    # @return [ExecutionContext::Event] the event that should be
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

                    def to_s; "emit(#{event})" end
                end

                # The list of instructions in this script
                # @return [Array]
                attribute(:instructions) { Array.new }

                # Starts the given task
                #
                # @param [ExecutionContext::Task] task the action-task. It must be created by
                #   calling {ExecutionContext#task} on the relevant object
                # @param [Hash] options the dependency relation options. See
                #   {Roby::TaskStructure::DependencyGraphClass::Extension#depends_on}
                def start(task, options = Hash.new)
                    validate_task task
                    instructions << Start.new(task, options)
                    wait(task.start_event)
                end

                # Starts the given task, and waits for it to successfully finish
                #
                # @param [ExecutionContext::Task] task the action-task. It must be created by
                #   calling {ExecutionContext#task} on the relevant object
                # @param [Hash] options the dependency relation options. See
                #   {Roby::TaskStructure::DependencyGraphClass::Extension#depends_on}
                def execute(task, options = Hash.new)
                    validate_task task
                    start(task, options)
                    wait(task.success_event)
                end

                # Waits a certain amount of time before continuing
                #
                # @param [Float] time the amount of time to wait, in seconds
                def sleep(time)
                    task = self.task(ActionCoordination::TaskFromAsPlan.new(Tasks::Timeout.with_arguments(:delay => time), Tasks::Timeout))
                    start task
                    wait task.stop_event
                end

                # Waits until this event gets emitted
                #
                # It will wait even if this event has already been emitted at
                # this point in the script (i.e. waits for a "new" emission)
                #
                # @param [ExecutionContext::Event] event the event to wait for
                # @param [Hash] options
                # @option options [Float] timeout a timeout
                def wait(event, options = Hash.new)
                    validate_event event

                    wait = Wait.new(event, options)
                    instructions << wait
                    wait
                end

                # Emit the given event
                #
                # @param [ExecutionContext::Event]
                def emit(event)
                    validate_event event
                    instructions << Emit.new(event)
                end

                # Execute another script at this point in the execution
                def call(script)
                    instructions.concat(script.instructions)
                end
            end
        end
    end
end
